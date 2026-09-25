//
//  GPUCollector.swift
//  MetriBar
//
//  GPU 占用采集：读 IORegistry 里 GPU accelerator 节点的 `PerformanceStatistics`。
//
//  - Apple Silicon：服务类 `AGXAccelerator<G17X…>`（M 系列每代后缀不同，故按基类匹配）
//  - Intel / 独显：服务类 `IOAccelerator`
//  两者都提供这些键（单位是百分数，不是 0…1）：
//      "Device Utilization %"   设备总占用
//      "Renderer Utilization %" 渲染核心占用
//      "Tiler Utilization %"    光栅化占用
//  虚拟机 / 无 Metal 设备时读不到，快照 available=false，界面显示 --。
//
//  注意：系统给的是「瞬时」读数，两次采样之间会大幅跳变，
//  这里做指数平滑（EMA），避免菜单栏数字闪成频闪。
//

import Foundation
import IOKit

/// GPU 占用采集器。非线程安全：只允许被 MetricsEngine 的串行队列访问。
final class GPUCollector {

    /// 匹配顺序：Apple Silicon 优先，其次通用加速器。
    static let serviceClasses: [String] = ["AGXAccelerator", "IOAccelerator"]

    /// EMA 系数：越大越跟手，越小越平滑。
    private static let alpha = 0.35

    private var smoothed: Double?
    private var previousActivityMs: Double?
    private var previousTime: CFTimeInterval = 0

    func reset() {
        smoothed = nil
        previousActivityMs = nil
        previousTime = 0
    }

    func sample(now: CFTimeInterval) -> GPUSnapshot {
        guard let service = matchAccelerator() else {
            reset()
            return .empty
        }
        defer { IOObjectRelease(service) }

        var nameBuffer = [UInt8](repeating: 0, count: 128)
        IORegistryEntryGetName(service, &nameBuffer)
        let deviceName = String(cString: nameBuffer)

        let stats = statistics(of: service)

        var raw = Self.number(stats?["Device Utilization %"])
        let renderer = Self.number(stats?["Renderer Utilization %"]).map { $0 / 100 }
        let tiler = Self.number(stats?["Tiler Utilization %"]).map { $0 / 100 }

        // 少数驱动不给百分比，只给累计活跃毫秒：用增量折算成占用率。
        if raw == nil, let activityMs = Self.number(stats?["GPU Activity (ms)"]) {
            if let previous = previousActivityMs, now - previousTime > 0.05 {
                raw = (activityMs - previous) / ((now - previousTime) * 1000) * 100
            }
            previousActivityMs = activityMs
            previousTime = now
        }

        // 系统给的是百分数，统一夹到 0...1。
        guard let percent = raw else { return .empty }
        let utilization = min(max(percent / 100, 0), 1)

        let value = smoothed.map { Self.alpha * utilization + (1 - Self.alpha) * $0 } ?? utilization
        smoothed = value

        return GPUSnapshot(
            available: true,
            utilization: value,
            renderer: renderer,
            tiler: tiler,
            deviceName: deviceName.isEmpty ? nil : deviceName
        )
    }

    // MARK: - IOKit 工具

    private func matchAccelerator() -> io_registry_entry_t? {
        for className in Self.serviceClasses {
            guard let matching = IOServiceMatching(className) else { continue }
            var iterator: io_iterator_t = 0
            guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { continue }
            defer { IOObjectRelease(iterator) }

            let service = IOIteratorNext(iterator)
            if service != IO_OBJECT_NULL { return service }
        }
        return nil
    }

    private func statistics(of service: io_registry_entry_t) -> [String: Any]? {
        guard let cfValue = IORegistryEntryCreateCFProperty(
            service,
            "PerformanceStatistics" as CFString,
            kCFAllocatorDefault,
            0
        ) else { return nil }
        return cfValue.takeRetainedValue() as? [String: Any]
    }

    private static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let text = value as? String { return Double(text) }
        return nil
    }
}
