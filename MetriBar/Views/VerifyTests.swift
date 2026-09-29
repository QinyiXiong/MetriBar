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

// MARK: - 全屏坏点检测

@MainActor
final class DeadPixelController {
    static let shared = DeadPixelController()

    private let colors: [NSColor] = [.black, .white, .red, .green, .blue]
    private var index = 0
    private var window: NSWindow?
    private var monitor: Any?

    func show() {
        guard window == nil else { return }
        guard let screen = NSScreen.main else { return }
        index = 0
        let w = NSWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        w.level = .screenSaver
        w.isOpaque = true
        w.backgroundColor = colors[index]
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = w

        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == 53 { self.close(); return nil }        // Esc
            if event.keyCode == 49 || event.keyCode == 125 { self.next() } // Space / →
            return nil
        }
    }

    private func next() {
        index = (index + 1) % colors.count
        window?.backgroundColor = colors[index]
    }

    func close() {
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        window?.orderOut(nil)
        window = nil
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

    func toggle() {
        if recorder?.isRecording == true { stopAndPlayback(); return }
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            guard granted else {
                DispatchQueue.main.async { self?.notify("请在 系统设置 › 隐私与安全 › 麦克风 中允许 MetriBar") }
                return
            }
            DispatchQueue.main.async { self?.begin() }
        }
    }

    private func begin() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("metribar-mic-test.caf")
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM,
                                        AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 1,
                                        AVLinearPCMBitDepthKey: 16]
        recorder = try? AVAudioRecorder(url: url, settings: settings)
        recorder?.delegate = self
        guard recorder?.prepareToRecord() == true else { notify("录音器不可用"); return }
        recorder?.record(forDuration: 5)
        notify("正在录制 5 秒…对麦克风说话")
        workTimer = Timer.scheduledTimer(withTimeInterval: 5.2, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.stopAndPlayback() }
        }
    }

    private func stopAndPlayback() {
        workTimer?.invalidate()
        guard let rec = recorder, rec.isRecording else { return }
        rec.stop()
        usleep(120_000)
        if let p = try? AVAudioPlayer(contentsOf: rec.url) {
            player = p; p.play()
            notify("回放刚才的录音…")
        } else {
            notify("录音文件不可用")
        }
    }

    func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        if flag, recorder.isRecording == false {}
    }

    private func notify(_ text: String) {
        Diag.notice(Diag.lifecycle, "验机·麦克风：\(text)")
        NSSound.beep()
    }
}

// MARK: - 摄像头预览（独立小窗）

@MainActor
final class CameraPreviewController {
    static let shared = CameraPreviewController()

    private var window: NSWindow?
    private var session: AVCaptureSession?

    func toggle() {
        if let w = window { w.close(); window = nil; session?.stopRunning(); session = nil; return }
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            guard granted else {
                DispatchQueue.main.async {
                    let a = NSAlert(); a.messageText = "摄像头权限"
                    a.informativeText = "请在 系统设置 › 隐私与安全 › 摄像头 中允许 MetriBar，然后再次点击。"
                    a.runModal()
                }
                return
            }
            DispatchQueue.main.async { self?.openWindow() }
        }
    }

    private func openWindow() {
        let session = AVCaptureSession()
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else { return }
        session.addInput(input)
        session.startRunning()
        self.session = session

        let hosting = NSHostingView(rootView: CameraPreviewView(session: session))
        let w = NSWindow(contentViewController: NSViewController())
        w.contentView = hosting
        w.title = "摄像头预览"
        w.styleMask = [.titled, .closable]
        w.isReleasedWhenClosed = false
        w.setContentSize(NSSize(width: 512, height: 384))
        w.center()
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.session?.stopRunning(); self?.session = nil; self?.window = nil }
        }
        window = w
    }
}

private struct CameraPreviewView: NSViewRepresentable {
    let session: AVCaptureSession
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        let sessionRef = self.session
        DispatchQueue.global(qos: .userInitiated).async {
            let layer = AVCaptureVideoPreviewLayer(session: sessionRef)
            layer.videoGravity = .resizeAspect
            DispatchQueue.main.async {
                v.wantsLayer = true
                v.layer?.addSublayer(layer)
            }
        }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView.layer?.sublayers?.first as? AVCaptureVideoPreviewLayer)?.frame = nsView.bounds
    }
}

// MARK: - 键盘实时检测（内联小面板）

struct KeyboardTestView: NSViewRepresentable {
    func makeNSView(context: Context) -> KeyboardLayoutView { KeyboardLayoutView() }
    func updateNSView(_ nsView: KeyboardLayoutView, context: Context) {}
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

    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedWhite: 0.5, alpha: 0.08).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10).fill()

        let statusH: CGFloat = 26, pad: CGFloat = 12, gap: CGFloat = 3
        let availW = bounds.width - pad * 2
        let availH = bounds.height - pad - statusH
        // 键帽单位：吃满可用空间（宽高双约束），不再封顶 → 更大更清晰
        let unit = min(availW / 24.55, availH / 6.15)
        let kbW = 24.55 * unit, kbH = 6.15 * unit
        let ox = bounds.midX - kbW / 2
        // NSView 坐标 y 向上增：键盘块顶边（功能行上沿），垂直居中留白
        let topGap = max((availH - kbH) / 2, 0)
        let blockTopY = bounds.maxY - pad - topGap

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
            (isLit ? NSColor.controlAccentColor
                    : isTested ? NSColor.systemGreen.withAlphaComponent(0.55)
                    : NSColor(calibratedWhite: 0.5, alpha: 0.16)).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()

            // 文字自适应缩字号，禁止截断
            let text = c.main.isEmpty ? c.shift : c.main
            var fs = min(11, max(8.5, rect.height * 0.36))
            var attrs: [NSAttributedString.Key: Any] = [:]
            while fs > 5 {
                attrs = [.font: NSFont.systemFont(ofSize: fs, weight: isLit ? .bold : .medium),
                        .foregroundColor: isLit ? NSColor.white : NSColor.labelColor]
                if NSAttributedString(string: text, attributes: attrs).size().width <= rect.width - 4 { break }
                fs -= 0.5
            }
            let ps = NSMutableParagraphStyle(); ps.alignment = .center
            attrs[.paragraphStyle] = ps
            NSAttributedString(string: text, attributes: attrs)
                .draw(in: NSRect(x: rect.minX, y: rect.midY - fs * 0.62, width: rect.width, height: fs * 1.3))
        }

        let remain = cells.count - tested.count
        let text = tested.isEmpty ? "点击后逐键按下（F 键无反应请按 fn+F）"
            : (remain == 0 ? "✓ 全部 \(cells.count) 键已点亮 · Esc 退出" : "已测 \(tested.count)/\(cells.count) · 剩余 \(remain)")
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: (remain == 0 && !tested.isEmpty) ? NSColor.systemGreen : NSColor.secondaryLabelColor]
        let w = NSAttributedString(string: text, attributes: attrs).size().width
        NSAttributedString(string: text, attributes: attrs)
            .draw(at: NSPoint(x: bounds.midX - w / 2, y: pad * 0.5))
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
