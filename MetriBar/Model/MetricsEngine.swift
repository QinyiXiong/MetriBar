//
//  MetricsEngine.swift
//  MetriBar
//
//  采集调度 + 主线程状态容器。
//
//  设计要点：
//   · DispatchSourceTimer 挂在独立的串行队列（qos: .utility），
//     所有采集都在工作线程执行，主线程只做渲染 —— 界面不会卡顿。
//   · 每个 tick 先同步采完廉价的项（网卡 / 内存 / 磁盘 / CPU ticks），
//     再异步等 SMC（SMCKit 是 actor），最后一次性把快照抛回主线程。
//   · isSampling 闸门：SMC 偶发变慢时跳过本次 tick，绝不让任务堆积。
//

import AppKit
import Combine
import QuartzCore

/// 采集调度器。只在自有串行队列上访问可变状态。
final class MetricsEngine {

    private let queue = DispatchQueue(
        label: "com.qyx.MetriBar.collector",
        qos: .utility,
        target: .global(qos: .utility)
    )

    private var timer: DispatchSourceTimer?
    private var network = NetworkCollector()
    private var memory = MemoryCollector()
    private var disk = DiskCollector()
    private var cpu = CPULoadCollector()
    private let sensors = SMCSensorReader()

    private weak var store: MetricsStore?
    private var isSampling = false
    private var interval: TimeInterval = 2
    private var wakeObserver: NSObjectProtocol?

    init() {}

    /// 二阶段绑定观察者。
    ///
    /// `MetricsStore` 必须在自己的 init 结束、全部存储属性就绪之后再调用，
    /// 否则会在 init 表达式里把 `self` 逃逸出去（编译器直接报错）。
    func bind(store: MetricsStore) {
        self.store = store
    }

    deinit {
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
        timer?.cancel()
    }

    // MARK: - 生命周期

    func start(interval seconds: TimeInterval) {
        interval = clamped(seconds)
        Diag.notice(Diag.lifecycle, "采集启动：每 \(interval) 秒")
        queue.async { [weak self] in
            guard let self else { return }
            self.scheduleTimer()
        }
    }

    func restart(interval seconds: TimeInterval) {
        interval = clamped(seconds)
        Diag.notice(Diag.lifecycle, "采集重建：每 \(interval) 秒，已重置速率基线")
        queue.async { [weak self] in
            guard let self else { return }
            self.network.resetBaseline()
            self.cpu.reset()
            self.scheduleTimer()
        }
    }

    func stop() {
        Diag.notice(Diag.lifecycle, "采集停止")
        queue.async { [weak self] in
            self?.timer?.cancel()
            self?.timer = nil
        }
    }

    private func clamped(_ seconds: TimeInterval) -> TimeInterval {
        min(max(seconds, 1), 10)
    }

    /// 必须在自有队列上调用。
    private func scheduleTimer() {
        timer?.cancel()

        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(
            deadline: .now() + 0.2,
            repeating: interval,
            leeway: .milliseconds(120)
        )
        source.setEventHandler { [weak self] in
            self?.collectTick()
        }
        source.resume()
        timer = source

        observeWake()
    }

    /// 睡眠唤醒后网卡计数器与 CPU ticks 会出现巨大跳变，重置基线。
    private func observeWake() {
        guard wakeObserver == nil else { return }
        let center = NSWorkspace.shared.notificationCenter
        // 通知回调投递到主队列，只负责转发；真正的基线复位仍回到采集串行队列执行。
        wakeObserver = center.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.queue.async {
                self.network.resetBaseline()
                self.cpu.reset()
            }
        }
    }

    // MARK: - 单个采集周期

    private func collectTick() {
        guard !isSampling else {
            Diag.debug(Diag.metrics, "上一次采样未结束，跳过本次 tick")
            return
        }
        isSampling = true
        Diag.debug(Diag.metrics, "tick 开始")

        let now = CACurrentMediaTime()
        let networkSnapshot = network.sample(now: now)
        let memorySnapshot = memory.sample()
        let diskSnapshot = disk.sample()
        let cpuSnapshot = cpu.sample()

        let store = self.store
        let sensors = self.sensors

        Task.detached(priority: .utility) { [weak store] in
            let hardware = await sensors.sample()
            let snapshot = MetricsSnapshot(
                network: networkSnapshot,
                hardware: hardware,
                memory: memorySnapshot,
                disk: diskSnapshot,
                cpu: cpuSnapshot,
                timestamp: Date()
            )
            await store?.publish(snapshot)



            // 采样结束把闸门放回自有队列，保证与 collectTick 互斥。
            self.setSamplingFinished()
        }
    }

    /// 一行式采样摘要（仅排查用，写入 os_log）。
    static func describe(_ snapshot: MetricsSnapshot) -> String {
        let fans = snapshot.hardware.fans.isEmpty
            ? "-"
            : snapshot.hardware.fans.map { "\($0.displayName) \(Fmt.rpm($0.rpm))" }.joined(separator: ", ")
        return "↓\(Fmt.compactSpeed(snapshot.network.downBps))"
             + " ↑\(Fmt.compactSpeed(snapshot.network.upBps))"
             + " CPU \(Fmt.percent(snapshot.cpu.total))"
             + " 温度 \(Fmt.temperature(snapshot.hardware.cpuTemperature))[\(snapshot.hardware.sensorKey ?? "-")]"
             + " 风扇 \(fans)"
             + " 内存 \(Fmt.percent(snapshot.memory.usedFraction))"
             + " 磁盘剩余 \(Fmt.volume(snapshot.disk.freeBytes))"
             + " 基线就绪=\(snapshot.network.ready)"
    }

    private func setSamplingFinished() {
        queue.async { [weak self] in
            self?.isSampling = false
        }
    }
}

// MARK: - 主线程状态容器

/// 唯一被 SwiftUI 观察的对象；只在工作线程投递完整快照后整体替换，
/// 因此主线程每次只处理一次赋值，不做任何系统调用。
@MainActor
final class MetricsStore: ObservableObject {

    @Published private(set) var snapshot: MetricsSnapshot = .empty

    /// 网速需要两次采样才有值；UI 在此之前显示 "…"。
    @Published private(set) var isNetworkReady = false

    /// 首帧快照打一条 notice，方便用户不提日志也能被排查到。
    private var didLogFirstSnapshot = false

    private let engine: MetricsEngine

    /// 网速条形的滚动峰值（最近 60 个采样），只用于画比例条。
    private var peakWindow: [Double] = []

    init(interval: TimeInterval) {
        engine = MetricsEngine()
        // 全部存储属性就绪后才能安全把 self 交给引擎（避免 init 内 self 逃逸）。
        observeSettings()
        engine.bind(store: self)
        engine.start(interval: interval)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func publish(_ snapshot: MetricsSnapshot) {
        self.snapshot = snapshot

        if Diag.verbose || !didLogFirstSnapshot {
            didLogFirstSnapshot = true
            Diag.notice(Diag.metrics, MetricsEngine.describe(snapshot))
        }
        if snapshot.network.ready, !isNetworkReady { isNetworkReady = true }

        peakWindow.append(max(snapshot.network.downBps, snapshot.network.upBps))
        if peakWindow.count > 60 { peakWindow.removeFirst(peakWindow.count - 60) }
    }

    /// 相对滚动峰值的占比，让网络条形条在静默时归零、突发时拉满（下限 64 KB/s 防噪声放大）。
    func fraction(of bytesPerSecond: Double) -> Double {
        let peak = max(peakWindow.max() ?? 0, 64 * 1_024)
        return min(max(bytesPerSecond / peak, 0), 1)
    }

    /// 设置页修改刷新间隔后调用（会重建 Timer 并重置速率基线）。
    func applyRefreshInterval(_ seconds: TimeInterval) {
        engine.restart(interval: seconds)
    }

    /// 设置项由 @AppStorage 直接写入，不触发 didSet；
    /// 因此由 AppSettings 主动广播通知，这里订阅后重建 Timer。
    private func observeSettings() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleIntervalChange(_:)),
            name: .metriBarRefreshIntervalChanged,
            object: nil
        )
    }

    @objc private func handleIntervalChange(_ note: Notification) {
        let seconds = (note.object as? TimeInterval) ?? UserDefaults.standard.double(forKey: AppSettings.Keys.refreshInterval)
        engine.restart(interval: seconds)
    }
}

extension Notification.Name {
    /// 刷新间隔发生变化（object 为新的 TimeInterval）。
    static let metriBarRefreshIntervalChanged = Notification.Name("com.qyx.MetriBar.refreshIntervalChanged")
}
