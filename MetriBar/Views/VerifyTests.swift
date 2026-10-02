//
//  VerifyTests.swift
//  MetriBar
//
//  验机交互测试：全部本地运行——全屏坏点、扬声器声道扫频、麦克风录放、
//  摄像头预览、键盘实时检测、触控板画布。不联网；首次使用按系统提示授权
//  麦克风/摄像头（见 Info.plist 用途说明）。
//

import SwiftUI
import AppKit
import AVFoundation
import Combine

@MainActor
enum VerifyTests {

    static func launch(_ id: String) {
        switch id {
        case "dead-pixel": DeadPixelController.shared.show()
        case "speakers":   TonePlayer.shared.sweepStereo()
        case "mic":        MicTestController.shared.toggle()
        case "camera":     CameraPreviewController.shared.toggle()
        default: break // keyboard / trackpad 在清单内联展开
        }
    }
}

// MARK: - 通用测试提示浮层（非激活面板，不抢焦点）

@MainActor
final class TestHUD {
    static let shared = TestHUD()

    private var panel: NSPanel?
    private var titleLabel: NSTextField?
    private var subLabel: NSTextField?
    private var highLevel = false

    /// high=true 时置于全屏检测窗之上
    func show(_ title: String, _ subtitle: String = "", high: Bool = false) {
        if panel == nil || high != highLevel { build(high: high) }
        titleLabel?.stringValue = L10n.t(title)
        subLabel?.stringValue = L10n.t(subtitle)
        layout()
        panel?.orderFrontRegardless()
    }

    func update(_ title: String, _ subtitle: String = "") {
        titleLabel?.stringValue = L10n.t(title)
        subLabel?.stringValue = L10n.t(subtitle)
        layout()
    }

    func hide() { panel?.orderOut(nil) }

    /// 测试用：浮层当前是否可见
    var isVisibleForTest: Bool { panel?.isVisible ?? false }

    private func build(high: Bool) {
        highLevel = high
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 84),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = high ? .screenSaver : .floating
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 84))
        box.wantsLayer = true
        box.layer?.backgroundColor = NSColor(calibratedWhite: 0.08, alpha: 0.9).cgColor
        box.layer?.cornerRadius = 16
        box.layer?.borderWidth = 1
        box.layer?.borderColor = NSColor(calibratedWhite: 1, alpha: 0.14).cgColor
        let t = NSTextField(labelWithString: "")
        t.font = .systemFont(ofSize: 16, weight: .semibold)
        t.textColor = .white; t.alignment = .center
        let sub = NSTextField(labelWithString: "")
        sub.font = .systemFont(ofSize: 12)
        sub.textColor = NSColor(calibratedWhite: 0.72, alpha: 1); sub.alignment = .center
        box.addSubview(t); box.addSubview(sub)
        p.contentView = box
        panel = p; titleLabel = t; subLabel = sub
    }

    private func layout() {
        guard let p = panel, let box = p.contentView, let t = titleLabel, let sub = subLabel else { return }
        let w: CGFloat = 560
        let th: CGFloat = t.stringValue.isEmpty ? 0 : 22
        let sh: CGFloat = sub.stringValue.isEmpty ? 0 : 18
        let h = max(56, th + sh + 26)
        t.frame = NSRect(x: 16, y: h - th - 12, width: w - 32, height: th)
        sub.frame = NSRect(x: 16, y: 12, width: w - 32, height: sh)
        box.frame = NSRect(x: 0, y: 0, width: w, height: h)
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        p.setFrame(NSRect(x: screen.midX - w / 2, y: screen.minY + 72, width: w, height: h), display: true)
    }
}

@MainActor
enum Guide {
    /// 一次性提示（4 秒后自动消失）：权限、设备缺失等前置说明
    static func hud(_ title: String, _ subtitle: String = "") {
        Diag.notice(Diag.lifecycle, "验机提示：\(title) \(subtitle)")
        TestHUD.shared.show(L10n.t(title), L10n.t(subtitle))
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { TestHUD.shared.hide() }
    }
}

// MARK: - 全屏坏点检测

@MainActor
final class DeadPixelController {
    static let shared = DeadPixelController()

    private let colors: [(NSColor, String)] = [(.black, "黑"), (.white, "白"), (.red, "红"), (.green, "绿"), (.blue, "蓝")]
    private var index = 0
    private var window: NSWindow?
    private var monitor: Any?
    private var clickMonitor: Any?
    private var hudTitleLabel: NSTextField?
    private var hudHintLabel: NSTextField?

    var isShowing: Bool { window != nil }

    /// 测试用：前进一张（等价于空格/→/单击）
    func advanceForTest() { next() }

    /// 测试用：当前全屏检测窗（NSApp.windows 会残留已关闭窗口，必须精确取）
    var windowForTest: NSWindow? { window }

    func show() {
        guard window == nil else { return }
        guard let screen = NSScreen.main else { return }
        index = 0
        let w = NSWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        w.level = .screenSaver
        w.isOpaque = true
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // 提示做进内容视图：浮层窗口在切换纯色/点击后可能被压到后面，内嵌才能保证每张都有提示
        let box = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        box.wantsLayer = true
        box.layer?.backgroundColor = colors[index].0.cgColor
        let pill = NSView(frame: NSRect(x: (screen.frame.width - 620) / 2, y: 90, width: 620, height: 84))
        pill.wantsLayer = true
        pill.layer?.backgroundColor = NSColor(calibratedWhite: 0.07, alpha: 0.92).cgColor
        pill.layer?.cornerRadius = 18
        pill.layer?.borderWidth = 1
        pill.layer?.borderColor = NSColor(calibratedWhite: 1, alpha: 0.16).cgColor
        let t = NSTextField(labelWithString: hudTitle)
        t.font = .systemFont(ofSize: 17, weight: .semibold); t.textColor = .white; t.alignment = .center
        t.frame = NSRect(x: 16, y: 46, width: 588, height: 24)
        let sub = NSTextField(labelWithString: hudHint)
        sub.font = .systemFont(ofSize: 12.5); sub.textColor = NSColor(calibratedWhite: 0.72, alpha: 1)
        sub.alignment = .center
        sub.frame = NSRect(x: 16, y: 14, width: 588, height: 20)
        pill.addSubview(t); pill.addSubview(sub)
        box.addSubview(pill)
        w.contentView = box
        hudTitleLabel = t; hudHintLabel = sub
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = w

        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            switch event.keyCode {
            case 53: self.close()                        // Esc
            case 49, 124, 125: self.next()               // 空格 / → / ↓
            case 123, 126: self.prev()                   // ← / ↑
            default: break
            }
            return nil
        }
        // 单击画面也能换色（不需要键盘也能测）
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            self?.next()
            return event
        }
    }

    private var hudTitle: String {
        L10n.t("坏点检测 · 第 %ld/%ld 张：%@色", index + 1, colors.count, L10n.t(colors[index].1))
    }
    private var hudHint: String {
        L10n.t("空格 / → / 单击 = 下一张　← = 上一张　Esc = 退出（共 %ld 张纯色图）", colors.count)
    }

    private func next() { index = (index + 1) % colors.count; apply() }
    private func prev() { index = (index - 1 + colors.count) % colors.count; apply() }

    private func apply() {
        window?.contentView?.layer?.backgroundColor = colors[index].0.cgColor
        hudTitleLabel?.stringValue = hudTitle
        hudHintLabel?.stringValue = hudHint
    }

    func close() {
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        if let m = clickMonitor { NSEvent.removeMonitor(m); clickMonitor = nil }
        window?.orderOut(nil)
        window = nil
        hudTitleLabel = nil; hudHintLabel = nil
    }
}

// MARK: - 扬声器声道扫频（左→中→右）

final class TonePlayer {
    static let shared = TonePlayer()

    private var players: [AVAudioPlayer] = []
    private let queue = DispatchQueue(label: "metribar.tone")

    /// 播放左/中/右三次提示音（用系统音 + pan 定位声道）。
    func sweepStereo() {
        players.removeAll()
        let pans: [(Float, String)] = [(-1, "左"), (0, "中"), (1, "右")]
        for url in ["/System/Library/Sounds/Glass.aiff", "/System/Library/Sounds/Ping.aiff", "/System/Library/Sounds/Zzzz.aiff"] {
            if let p = try? AVAudioPlayer(contentsOf: URL(fileURLWithPath: url)) {
                p.prepareToPlay(); players.append(p)
            }
        }
        for (i, item) in pans.enumerated() {
            let when = DispatchTime.now() + Double(i) * 1.1
            queue.asyncAfter(deadline: when) { [weak self] in
                guard let self, i < self.players.count else { return }
                let p = self.players[i]
                p.pan = item.0
                p.play()
            }
        }
    }
}

// MARK: - 麦克风录放

@MainActor
final class MicTestController: NSObject, AVAudioRecorderDelegate {
    static let shared = MicTestController()

    private var recorder: AVAudioRecorder?
    private var player: AVAudioPlayer?
    private var workTimer: Timer?

    private var tick: Timer?
    private var deadline = Date()
    private static let recordSeconds = 5.0

    func toggle() {
        if recorder?.isRecording == true { stopAndPlayback(); return }
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        if status == .denied || status == .restricted {
            Guide.hud("麦克风权限未开启", "系统设置 › 隐私与安全性 › 麦克风：勾选 MetriBar 后重试")
            return
        }
        if status == .notDetermined {
            Guide.hud("正在请求麦克风权限…", "系统弹窗中选择「允许」，随后自动开始录音")
        }
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            Task { @MainActor in
                guard granted else {
                    self?.notify("请在 系统设置 › 隐私与安全性 › 麦克风 中允许 MetriBar")
                    return
                }
                self?.begin()
            }
        }
    }

    private func begin() {
        guard AVCaptureDevice.default(for: .audio) != nil else {
            Guide.hud("未检测到可用麦克风", "该机型或系统未提供输入设备")
            return
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("metribar-mic-test.caf")
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM,
                                        AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 1,
                                        AVLinearPCMBitDepthKey: 16]
        recorder = try? AVAudioRecorder(url: url, settings: settings)
        recorder?.delegate = self
        guard recorder?.prepareToRecord() == true else { notify("录音器不可用"); return }
        recorder?.record()          // 不设时长：由定时器统一停止，避免"到点自停后 isRecording=false 导致回放被跳过"
        deadline = Date().addingTimeInterval(Self.recordSeconds)
        notify("开始录音：请对着麦克风说一句话")
        armWatchdog()
        TestHUD.shared.show(L10n.t("🎙 正在录音… %ld 秒后自动回放", Int(Self.recordSeconds)),
                            L10n.t("请正常说话，录音结束会自动播放给你听"))
        tick = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let rec = self.recorder, rec.isRecording else { return }
                let left = max(0, self.deadline.timeIntervalSinceNow)
                let level = max(0, min(1, Double(rec.currentTime) / Self.recordSeconds))
                let bars = String(repeating: "▮", count: Int(level * 20))
                TestHUD.shared.update(L10n.t("🎙 正在录音… 剩余 %.1f 秒", left),
                                      L10n.t("电平进度 %@", bars))
            }
        }
        workTimer = Timer.scheduledTimer(withTimeInterval: Self.recordSeconds + 0.25, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.stopAndPlayback() }
        }
    }

    private func stopAndPlayback() {
        workTimer?.invalidate(); tick?.invalidate(); tick = nil
        guard let rec = recorder else { return }
        if rec.isRecording { rec.stop() }
        usleep(150_000)
        if let p = try? AVAudioPlayer(contentsOf: rec.url) {
            player = p; p.play()
            notify("录音结束，正在回放…")
            let dur = p.duration
            TestHUD.shared.show(L10n.t("🔊 正在回放录音（%.1f 秒）", dur),
                                L10n.t("能清楚听到自己的声音 = 麦克风正常；无声/断续 = 异常"))
            DispatchQueue.main.asyncAfter(deadline: .now() + dur + 0.4) {
                TestHUD.shared.show("✓ 麦克风检测完成", "可再点一次「开始」复测", high: false)
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { TestHUD.shared.hide() }
            }
        } else {
            notify("录音文件不可用")
            Guide.hud("录音文件不可用", "可能是麦克风被其他 App 占用，关闭后重试")
        }
    }

    /// 兜底：任何异常路径都不允许提示浮层永久停留
    private func armWatchdog() {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.recordSeconds + 15) {
            if self.recorder?.isRecording == true {
                self.stopAndPlayback()
            } else {
                TestHUD.shared.hide()
            }
        }
    }

    func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        if flag, recorder.isRecording == false {}
    }

    private func notify(_ text: String) {
        Diag.notice(Diag.lifecycle, "验机·麦克风：\(text)")
        NSSound.beep()
    }

    // MARK: 测试用访问器（UI 测试台用；不影响正常流程）

    var isRecordingForTest: Bool { recorder?.isRecording ?? false }

    /// 最近一次录音文件大小（字节）：为 0 说明没真正录到声音
    var lastRecordingBytesForTest: Int64 {
        guard let url = recorder?.url,
              let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int64 else { return 0 }
        return size
    }

    func stopForTest() {
        workTimer?.invalidate(); tick?.invalidate()
        if recorder?.isRecording == true { recorder?.stop() }
        TestHUD.shared.hide()
    }
}

// MARK: - 摄像头预览（独立小窗）

@MainActor
final class CameraPreviewController {
    static let shared = CameraPreviewController()

    private var window: NSWindow?
    private var session: AVCaptureSession?

    func toggle() {
        if let w = window { w.close(); window = nil; stop(); return }
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        if status == .denied || status == .restricted {
            Guide.hud("摄像头权限未开启", "系统设置 › 隐私与安全性 › 摄像头：勾选 MetriBar 后重试")
            return
        }
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            Task { @MainActor in
                guard granted else {
                    Guide.hud("未获得摄像头权限", "系统设置 › 隐私与安全性 › 摄像头：勾选 MetriBar 后重试")
                    return
                }
                self?.openWindow()
            }
        }
    }

    private func stop() {
        let s = session
        session = nil
        DispatchQueue.global(qos: .userInitiated).async { s?.stopRunning() }
    }

    private func openWindow() {
        guard let device = AVCaptureDevice.default(for: .video) else {
            Guide.hud("未检测到摄像头", "该机型或系统未提供可用摄像头设备")
            return
        }
        let session = AVCaptureSession()
        session.sessionPreset = .high
        guard let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else {
            Guide.hud("摄像头无法启动", "设备被其他 App 占用或输入不可用")
            return
        }
        session.addInput(input)
        self.session = session

        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 560),
                         styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        w.title = L10n.t("摄像头预览 · %@", device.localizedName)
        w.isReleasedWhenClosed = false
        let root = CameraPanelView(session: session, device: device)
        w.contentView = NSHostingView(rootView: root)
        w.center()
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        // startRunning 是阻塞调用：放到后台，避免开窗卡顿（画面之前一直空白的根因之一）
        DispatchQueue.global(qos: .userInitiated).async { session.startRunning() }
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.stop(); self?.window = nil }
        }
        window = w
    }
}

/// 摄像头面板：预览 + 顶部状态/提示（预览层用 backing layer，尺寸随窗口自适应）
private struct CameraPanelView: View {
    let session: AVCaptureSession
    let device: AVCaptureDevice

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "video.fill").foregroundColor(.green)
                Text("实时预览中").font(.system(size: 11, weight: .semibold))
                Text("· 检查画面是否清晰、无横纹/黑块/彩点；用手遮挡再移开看曝光响应")
                    .font(.system(size: 10)).foregroundColor(.secondary)
                Spacer()
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            Divider()
            CameraPreviewLayerView(session: session)
                .frame(minWidth: 480, minHeight: 360)
            Divider()
            HStack {
                Text(L10n.t("设备：%@", device.localizedName)).font(.system(size: 10)).foregroundColor(.secondary)
                Spacer()
                Text("关闭窗口即停止摄像头（不占用时不耗电）").font(.system(size: 10)).foregroundColor(.secondary)
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
        }
    }
}

/// AVCaptureVideoPreviewLayer 作为 backing layer，layout 时同步尺寸 —— 保证一定有画面
private struct CameraPreviewLayerView: NSViewRepresentable {
    let session: AVCaptureSession
    func makeNSView(context: Context) -> PreviewBackingView { PreviewBackingView(session: session) }
    func updateNSView(_ nsView: PreviewBackingView, context: Context) {}
}

final class PreviewBackingView: NSView {
    private let previewLayer: AVCaptureVideoPreviewLayer

    init(session: AVCaptureSession) {
        previewLayer = AVCaptureVideoPreviewLayer(session: session)
        super.init(frame: .zero)
        wantsLayer = true
        previewLayer.videoGravity = .resizeAspect
        previewLayer.backgroundColor = NSColor.black.cgColor
    }
    required init?(coder: NSCoder) { fatalError() }
    override func makeBackingLayer() -> CALayer { previewLayer }
    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        previewLayer.frame = bounds
        CATransaction.commit()
    }
}

// MARK: - 键盘实时检测（内联小面板）

struct KeyboardTestView: NSViewRepresentable {
    var resetToken: Int = 0

    final class Coordinator { var lastToken: Int; init(_ t: Int) { lastToken = t } }
    func makeCoordinator() -> Coordinator { Coordinator(resetToken) }

    func makeNSView(context: Context) -> KeyboardLayoutView { KeyboardLayoutView() }
    func updateNSView(_ nsView: KeyboardLayoutView, context: Context) {
        if context.coordinator.lastToken != resetToken {
            context.coordinator.lastToken = resetToken
            nsView.reset()      // 「重置」按钮：清空已测记录重新开始
        }
    }
}

/// 全尺寸键盘画布。keyCode 全部取自 Apple 官方 <Carbon/Carbon.h> kVK_* 权威表：
/// A0 S1 D2 F3 H4 G5 Z6 X7 C8 V9 B11 Q12 W13 E14 R15 Y16 T17 1_18 2_19 3_20 4_21 5_23 6_22
/// 7_26 8_28 9_25 0_29 -=27 ==24 [=33 ]=30 \42 ;41 '39 ,43 .47 /44 `50 Return36 Tab48 Sp49
/// Del51 Esc53 cmdR54 cmdL55 shL56 caps57 optL58 ctlL59 shR60 optR61 ctlR62 fn(Globe)63
/// F1_122 F2_120 F3_99 F4_118 F5_96 F6_97 F7_98 F8_100 F9_101 F10_109 F11_103 F12_111
/// Ins(help)114 Home115 PgUp116 FwdDel117 End119 PgDn121 ←123 →124 ↓125 ↑126
/// PadClear71 /75 *67 -78 +69 =81 Enter76 .65 0_82…9_92（0=82,1=83,…7=89,8=91,9=92）
final class KeyboardLayoutView: NSView {
    private struct Cell { var main = ""; var shift = ""; var codes = Set<UInt16>()
                          var x: CGFloat = 0; var y: CGFloat = 0; var w: CGFloat = 1; var h: CGFloat = 1 }
    private var cells: [Cell] = []
    private var tested = Set<Int>()
    private var lit: Int?
    private var litAt = Date.distantPast

    override init(frame f: NSRect) { super.init(frame: f); wantsLayer = true; build() }
    required init?(coder: NSCoder) { fatalError() }

    private func add(_ x: CGFloat, _ y: CGFloat, main: String, shift: String = "", code: UInt16, w: CGFloat = 1, h: CGFloat = 1) {
        cells.append(Cell(main: main, shift: shift, codes: [code], x: x, y: y, w: w, h: h))
    }

    private func build() {
        // ── 功能行 y=0 h=0.7 ──
        add(0, 0, main: "esc", code: 53, h: 0.7)
        let fnRow: [(String, UInt16)] = [("F1",122),("F2",120),("F3",99),("F4",118),
                                           ("F5",96),("F6",97),("F7",98),("F8",100),
                                           ("F9",101),("F10",109),("F11",103),("F12",111)]
        var fx: CGFloat = 1.15
        for (i, it) in fnRow.enumerated() {
            if i == 4 || i == 8 { fx += 0.3 }
            add(fx, 0, main: it.0, code: it.1, h: 0.7); fx += 1
        }
        add(15.5, 0, main: "prtsc", code: 105, h: 0.7)
        add(16.55, 0, main: "scroll", code: 107, h: 0.7)
        add(17.6, 0, main: "pause", code: 113, h: 0.7)
        add(18.65, 0, main: "eject", code: 110, h: 0.7)

        // ── 数字行 y=1 ──
        let nums: [(String, String, UInt16)] = [
            ("`","~",50),("1","!",18),("2","@",19),("3","#",20),("4","$",21),("5","%",23),
            ("6","^",22),("7","&",26),("8","*",28),("9","(",25),("0",")",29),("-","_",27),("=","+",24)]
        var x: CGFloat = 0
        for n in nums { add(x, 1, main: n.0, shift: n.1, code: n.2); x += 1 }
        add(13, 1, main: "delete", code: 51, w: 1.9)

        // ── QWERTY y=2 ──
        add(0, 2, main: "tab", code: 48, w: 1.4)
        let qw: [(String, UInt16)] = [("Q",12),("W",13),("E",14),("R",15),("T",17),
                                        ("Y",16),("U",32),("I",34),("O",31),("P",35)]
        x = 1.5
        for n in qw { add(x, 2, main: n.0, code: n.1); x += 1 }
        add(x, 2, main: "[", shift: "{", code: 33); x += 1
        add(x, 2, main: "]", shift: "}", code: 30); x += 1
        add(x, 2, main: "\\", shift: "|", code: 42, w: 1.5)

        // ── ASDF y=3 ──
        add(0, 3, main: "caps", shift: "⇪", code: 57, w: 1.8)
        let asdf: [(String, UInt16)] = [("A",0),("S",1),("D",2),("F",3),("G",5),
                                          ("H",4),("J",38),("K",40),("L",37)]
        x = 1.9
        for n in asdf { add(x, 3, main: n.0, code: n.1); x += 1 }
        add(x, 3, main: ";", shift: ":", code: 41); x += 1
        add(x, 3, main: "'", shift: "\"", code: 39); x += 1
        add(x, 3, main: "return", shift: "↩", code: 36, w: 2.0)

        // ── ZXCV y=4（官方：Z6 X7 C8 V9 B11 N45 M46 ,43 .47 /44）──
        add(0, 4, main: "⇧", shift: "shift", code: 56, w: 2.3)
        let zxcv: [(String, UInt16)] = [("Z",6),("X",7),("C",8),("V",9),("B",11),
                                          ("N",45),("M",46)]
        x = 2.4
        for n in zxcv { add(x, 4, main: n.0, code: n.1); x += 1 }
        add(x, 4, main: ",", shift: "<", code: 43); x += 1
        add(x, 4, main: ".", shift: ">", code: 47); x += 1
        add(x, 4, main: "/", shift: "?", code: 44); x += 1
        add(x, 4, main: "⇧", shift: "shift", code: 60, w: 1.3)

        // ── 底行 y=5 ──
        add(0, 5, main: "control", shift: "⌃", code: 59, w: 1.2)
        add(1.3, 5, main: "option", shift: "⌥", code: 58, w: 1.2)
        add(2.6, 5, main: "command", shift: "⌘", code: 55, w: 1.2)
        add(3.9, 5, main: "space", code: 49, w: 6.2)
        add(10.2, 5, main: "command", shift: "⌘", code: 54, w: 1.2)
        add(11.5, 5, main: "option", shift: "⌥", code: 61, w: 1.2)
        add(12.8, 5, main: "fn", shift: "🌐", code: 63, w: 1.2)

        // ── 编辑区（主区右侧，间距分隔）──
        add(15.5, 1, main: "ins", code: 114)
        add(16.55, 1, main: "home", shift: "↖", code: 115)
        add(17.6, 1, main: "pgup", code: 116)
        add(15.5, 2, main: "del", code: 117)
        add(16.55, 2, main: "end", shift: "↘", code: 119)
        add(17.6, 2, main: "pgdn", shift: "↟", code: 121)

        // ── 方向键（↑独立上排）──
        add(16.55, 4, main: "↑", code: 126)
        add(15.5, 5, main: "←", code: 123)
        add(16.55, 5, main: "↓", code: 125)
        add(17.6, 5, main: "→", code: 124)

        // ── 数字小键盘 x≥20.3 ──
        add(20.3, 1, main: "num", code: 71)
        add(21.3, 1, main: "/", code: 75)
        add(22.3, 1, main: "×", shift: "*", code: 67)
        add(23.3, 1, main: "−", shift: "-", code: 78)
        add(20.3, 2, main: "7", code: 89)
        add(21.3, 2, main: "8", code: 91)
        add(22.3, 2, main: "9", code: 92)
        add(23.3, 2, main: "+", code: 69, h: 2)
        add(20.3, 3, main: "4", code: 86)
        add(21.3, 3, main: "5", code: 87)
        add(22.3, 3, main: "6", code: 88)
        add(20.3, 4, main: "1", code: 83)
        add(21.3, 4, main: "2", code: 84)
        add(22.3, 4, main: "3", code: 85)
        add(23.3, 4, main: "enter", shift: "↵", code: 76, h: 2)
        add(20.3, 5, main: "0", code: 82, w: 2)
        add(22.3, 5, main: ".", code: 65)

    }

    override var acceptsFirstResponder: Bool { true }
    override func viewDidMoveToWindow() { window?.makeFirstResponder(self) }
    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self) }

    override func keyDown(with event: NSEvent) {
        hit(event.keyCode)
    }
    /// 修饰键 / Globe(中英切换) / caps 只发 flagsChanged。
    override func flagsChanged(with event: NSEvent) {
        hit(event.keyCode)
    }
    /// 中文 IME 合成兜底。
    override func insertText(_ insertString: Any) {
        var ch: Character?
        if let str = insertString as? String { ch = str.lowercased().first }
        else if let attr = insertString as? NSAttributedString { ch = attr.string.lowercased().first }
        if let c = ch, c != Character(UnicodeScalar(27)) {
            if let i = cells.firstIndex(where: { $0.main.lowercased() == String(c) || $0.shift.lowercased() == String(c) }) {
                flash(i)
            }
        }
    }

    private func hit(_ code: UInt16) {
        if let i = cells.firstIndex(where: { $0.codes.contains(code) }) { flash(i) }
    }
    private func flash(_ i: Int) { lit = i; litAt = Date(); tested.insert(i); needsDisplay = true }

    /// 清空已测记录，重新开始
    func reset() { tested.removeAll(); lit = nil; needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        // 画布背景透明，直接坐在弹窗底色上（不再叠自己的灰块）
        let statusH: CGFloat = 26, pad: CGFloat = 12, gap: CGFloat = 3
        let availW = bounds.width - pad * 2
        let availH = bounds.height - pad - statusH
        // 键帽单位：吃满可用空间（宽高双约束），不再封顶 → 更大更清晰
        // 按内容实际跨度（最右单元格右缘）算块宽，水平严格居中
        let maxRight = cells.map { $0.x + $0.w }.max() ?? 24.35
        let unit = min(availW / maxRight, availH / 6.15)
        let kbW = maxRight * unit, kbH = 6.15 * unit
        let ox = bounds.midX - kbW / 2
        // NSView 坐标 y 向上增：键盘块顶边（功能行上沿），垂直居中留白
        let vertCenter = bounds.minY + statusH + availH / 2
        let blockTopY = vertCenter + kbH / 2

        let flashAlive = lit != nil && Date().timeIntervalSince(litAt) < 0.32
        for (idx, c) in cells.enumerated() {
            let isFn = c.y == 0
            // 网格坐标：y=1..5 主行，每行高 unit；功能行高 0.7unit
            let colX = ox + c.x * unit
            // y 向上增 → 行往下 = y 递减。功能行贴块顶，主行逐行向下排。
            let rowTopY: CGFloat = isFn ? blockTopY
                                         : blockTopY - 0.7 * unit - gap - (c.y - 1) * (unit + gap)
            let rowY = rowTopY - (isFn ? 0.7 : c.h) * unit
            let rect = NSRect(x: colX, y: rowY,
                              width: max(c.w * unit - gap, 10),
                              height: max((isFn ? 0.7 : c.h) * unit - gap, 12))
            let isLit = flashAlive && lit == idx
            let isTested = tested.contains(idx)
            let radius = max(4, unit * 0.16)
            let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

            // 拟真键帽：顶亮底暗的竖向渐变 + 描边 + 底部厚度阴影（模仿实机/在线键盘测试观感）
            let capTop: NSColor, capBottom: NSColor, border: NSColor, textColor: NSColor
            if isLit {
                capTop = NSColor.controlAccentColor.blended(withFraction: 0.35, of: .white) ?? .controlAccentColor
                capBottom = NSColor.controlAccentColor
                border = NSColor.controlAccentColor.blended(withFraction: 0.5, of: .black) ?? .controlAccentColor
                textColor = .white
            } else if isTested {
                capTop = NSColor.systemGreen.withAlphaComponent(0.42)
                capBottom = NSColor.systemGreen.withAlphaComponent(0.26)
                border = NSColor.systemGreen.withAlphaComponent(0.65)
                textColor = .labelColor
            } else if isFn {
                capTop = NSColor(calibratedWhite: 0.42, alpha: 0.20)
                capBottom = NSColor(calibratedWhite: 0.32, alpha: 0.16)
                border = NSColor(calibratedWhite: 0.6, alpha: 0.22)
                textColor = NSColor.secondaryLabelColor
            } else {
                capTop = NSColor(calibratedWhite: isDark ? 0.30 : 0.99, alpha: 1)
                capBottom = NSColor(calibratedWhite: isDark ? 0.20 : 0.90, alpha: 1)
                border = NSColor(calibratedWhite: isDark ? 0.45 : 0.72, alpha: 0.55)
                textColor = .labelColor
            }
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(isLit ? 0.0 : 0.22)
            shadow.shadowBlurRadius = 2.0
            shadow.shadowOffset = NSSize(width: 0, height: -1.5)
            shadow.set()
            (capTop).setFill()
            path.fill()
            NSGraphicsContext.restoreGraphicsState()

            if let grad = NSGradient(starting: capTop, ending: capBottom) {
                grad.draw(in: path, angle: -90)
            }
            border.setStroke()
            path.lineWidth = 0.8
            path.stroke()

            // 键帽文字：主标居中；有副标（shift）时小字放左上角，贴近实机键帽
            let main = c.main.isEmpty ? c.shift : c.main
            let alt = c.main.isEmpty ? "" : c.shift
            var fs = min(13, max(9, rect.height * 0.40))
            var attrs: [NSAttributedString.Key: Any] = [:]
            while fs > 5 {
                attrs = [.font: NSFont.systemFont(ofSize: fs, weight: isLit ? .bold : .medium),
                         .foregroundColor: textColor]
                if NSAttributedString(string: main, attributes: attrs).size().width <= rect.width - 6 { break }
                fs -= 0.5
            }
            let ps = NSMutableParagraphStyle(); ps.alignment = .center
            attrs[.paragraphStyle] = ps
            let textY = rect.midY - fs * 0.62 - (alt.isEmpty ? 0 : fs * 0.10)
            NSAttributedString(string: main, attributes: attrs)
                .draw(in: NSRect(x: rect.minX, y: textY, width: rect.width, height: fs * 1.35))

            if !alt.isEmpty, rect.width > unit * 0.85 {
                let afs = max(6.5, fs * 0.62)
                let aattrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: afs, weight: .regular),
                    .foregroundColor: textColor.withAlphaComponent(0.72)]
                NSAttributedString(string: alt, attributes: aattrs)
                    .draw(at: NSPoint(x: rect.minX + 4, y: rect.maxY - afs - 3))
            }
        }

        let remain = cells.count - tested.count
        let text = tested.isEmpty
            ? L10n.t("点击本区域取得焦点，然后逐个按下每个键（F 键无反应请按 fn+F）")
            : (remain == 0 ? L10n.t("✓ 全部 %ld 键已点亮 · Esc 退出", cells.count)
                           : L10n.t("已测 %ld/%ld · 剩余 %ld", tested.count, cells.count, remain))
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12.5, weight: .semibold),
            .foregroundColor: (remain == 0 && !tested.isEmpty) ? NSColor.systemGreen : NSColor.secondaryLabelColor]
        let w = NSAttributedString(string: text, attributes: attrs).size().width
        NSAttributedString(string: text, attributes: attrs)
            .draw(at: NSPoint(x: bounds.midX - w / 2, y: pad * 0.8))
    }

    private var isDark: Bool { effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
}

// MARK: - 触控板画布

struct TrackpadCanvasView: View {
    @State private var strokes: [[CGPoint]] = []
    @State private var current: [CGPoint] = []

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Canvas { ctx, size in
                ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color.primary.opacity(0.06)))
                var all = strokes
                if !current.isEmpty { all.append(current) }
                for stroke in all {
                    guard stroke.count > 1 else { continue }
                    var path = Path()
                    path.move(to: stroke[0])
                    for p in stroke.dropFirst() { path.addLine(to: p) }
                    ctx.stroke(path, with: .color(.accentColor), style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { v in current.append(v.location) }
                    .onEnded { _ in strokes.append(current); current = [] }
            )
            Button("清屏") { strokes = []; current = [] }.controlSize(.mini).padding(6)
        }
    }
}
