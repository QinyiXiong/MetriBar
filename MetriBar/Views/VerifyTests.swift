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

/// 全尺寸键盘画布：主键区(15u) + 编辑区(3列) + 数字小键盘(4列) + 完整方向键。
/// keyCode 用 Apple 官方 kVK_* 权威表；数字小键盘与主区数字靠 keyCode 区分。
final class KeyboardLayoutView: NSView {
    private struct Cell { var label = ""; var codes = Set<UInt16>()
                          var x: CGFloat = 0; var y: CGFloat = 0; var w: CGFloat = 1; var h: CGFloat = 1 }
    private var cells: [Cell] = []
    private var tested = Set<Int>()
    private var lit: Int?
    private var litAt = Date.distantPast

    override init(frame f: NSRect) { super.init(frame: f); wantsLayer = true; build() }
    required init?(coder: NSCoder) { fatalError() }

    private func add(_ label: String, _ code: UInt16? = nil, x: CGFloat, y: CGFloat, w: CGFloat = 1, h: CGFloat = 1) {
        var c = Cell(label: label, x: x, y: y, w: w, h: h)
        if let code { c.codes.insert(code) }
        cells.append(c)
    }

    private func build() {
        // ── 功能行（h=0.7）──
        add("esc", 53, x: 0, y: 0, h: 0.7)
        let fR: [(String, UInt16)] = [("F1",122),("F2",120),("F3",99),("F4",118),
                                        ("F5",96),("F6",97),("F7",98),("F8",100),
                                        ("F9",101),("F10",109),("F11",103),("F12",111)]
        var fx: CGFloat = 1.15
        for (i, it) in fR.enumerated() {
            if i == 4 || i == 8 { fx += 0.3 }
            add(it.0, it.1, x: fx, y: 0, h: 0.7); fx += 1
        }
        add("prtsc", 105, x: 15.5, y: 0, h: 0.7)
        add("scroll", 107, x: 16.55, y: 0, h: 0.7)
        add("pause", 113, x: 17.6, y: 0, h: 0.7)
        add("eject", 110, x: 18.65, y: 0, h: 0.7)

        // ── 数字行 ──
        let nums: [(String, UInt16)] = [("~`",50),("1!",18),("2@",19),("3#",20),("4$",21),
                                          ("5%",23),("6^",22),("7&",26),("8*",28),("9(",25),("0)",29),("-_",27),("=+",24)]
        var x: CGFloat = 0
        for n in nums { add(n.0, n.1, x: x, y: 1); x += 1 }
        add("delete", 51, x: 13, y: 1, w: 1.9)

        // ── QWERTY ──
        add("tab", 48, x: 0, y: 2, w: 1.4)
        let qw: [(String, UInt16)] = [("Q",12),("W",13),("E",14),("R",15),("T",17),
                                        ("Y",16),("U",32),("I",34),("O",31),("P",35)]
        x = 1.5
        for n in qw { add(n.0, n.1, x: x, y: 2); x += 1 }
        add("[{", 30, x: x, y: 2); x += 1
        add("]}", 33, x: x, y: 2); x += 1
        add("\\|", 42, x: x, y: 2, w: 1.5)

        // ── ASDF ──
        add("caps", 57, x: 0, y: 3, w: 1.8)
        let asd: [(String, UInt16)] = [("A",0),("S",1),("D",2),("F",3),("G",5),
                                         ("H",4),("J",6),("K",7),("L",8)]
        x = 1.9
        for n in asd { add(n.0, n.1, x: x, y: 3); x += 1 }
        add(";:", 41, x: x, y: 3); x += 1
        add("'\"", 39, x: x, y: 3); x += 1
        add("return", 36, x: x, y: 3, w: 2.0)

        // ── ZXCV（含 , . /）──
        add("⇧", 56, x: 0, y: 4, w: 2.3)
        let zxCodes: [(String, UInt16)] = [("Z",46),("X",45),("C",47),("V",9),("B",11),("N",0x2D),("M",0x2E)]
        x = 2.4
        for n in zxCodes { add(n.0, n.1, x: x, y: 4); x += 1 }
        add(",<", 43, x: x, y: 4); x += 1
        add(".>", 47, x: x, y: 4); x += 1
        add("/?", 44, x: x, y: 4); x += 1
        add("⇧", 60, x: x, y: 4, w: 1.3)

        // ── 底行 ──
        add("control", 59, x: 0, y: 5, w: 1.2)
        add("option", 58, x: 1.3, y: 5, w: 1.2)
        add("command", 55, x: 2.6, y: 5, w: 1.2)
        add("space", 49, x: 3.9, y: 5, w: 6.2)
        add("command", 54, x: 10.2, y: 5, w: 1.2)
        add("option", 61, x: 11.5, y: 5, w: 1.2)
        add("fn", 63, x: 12.8, y: 5, w: 1.2)

        // ── 编辑区第二排 + 方向键（↑ 单独在上）──
        add("ins", 114, x: 15.5, y: 1)
        add("home", 115, x: 16.55, y: 1)
        add("pgup", 116, x: 17.6, y: 1)
        add("del", 117, x: 18.65, y: 1)
        add("end", 119, x: 16.55, y: 2)
        add("pgdn", 121, x: 17.6, y: 2)
        add("↑", 126, x: 16.55, y: 4)
        add("←", 123, x: 15.5, y: 5)
        add("↓", 125, x: 16.55, y: 5)
        add("→", 124, x: 17.6, y: 5)

        // ── 数字小键盘 ──
        add("num", 71, x: 20.4, y: 1)
        add("/", 75, x: 21.4, y: 1)
        add("×", 67, x: 22.4, y: 1)
        add("−", 78, x: 23.4, y: 1)
        add("7", 89, x: 20.4, y: 2)
        add("8", 91, x: 21.4, y: 2)
        add("9", 92, x: 22.4, y: 2)
        add("+", 69, x: 23.4, y: 2, h: 2)
        add("4", 86, x: 20.4, y: 3)
        add("5", 87, x: 21.4, y: 3)
        add("6", 88, x: 22.4, y: 3)
        add("1", 83, x: 20.4, y: 4)
        add("2", 84, x: 21.4, y: 4)
        add("3", 85, x: 22.4, y: 4)
        add("enter", 76, x: 23.4, y: 4, h: 2)
        add("0", 82, x: 20.4, y: 5, w: 2)
        add(".", 65, x: 22.4, y: 5)
    }

    override var acceptsFirstResponder: Bool { true }
    override func viewDidMoveToWindow() { window?.makeFirstResponder(self) }
    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self) }

    override func keyDown(with event: NSEvent) {
        // 小键盘数字用 keyCode；主区字母数字同用 keyCode（keyCode 全局唯一物理位置）
        let hit = cells.firstIndex(where: { $0.codes.contains(event.keyCode) })
        if let i = hit { lit = i; litAt = Date(); tested.insert(i); needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedWhite: 0.5, alpha: 0.08).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10).fill()
        let pad: CGFloat = 10, gap: CGFloat = 3
        let area = bounds.insetBy(dx: pad, dy: pad)
        let unitX = area.width / 24.6
        let bandH = (area.height - 22) / 5.7            // 5 主行 + fn(0.7)
        let flashAlive = lit != nil && Date().timeIntervalSince(litAt) < 0.3
        for (idx, c) in cells.enumerated() {
            let topOffset: CGFloat = c.y == 0 ? bandH - bandH * 0.7 : c.y * bandH
            let rect = NSRect(x: area.minX + c.x * unitX,
                              y: area.maxY - topOffset - (c.y == 0 ? bandH * 0.7 : c.h * bandH),
                              width: max(c.w * unitX - gap, 8),
                              height: (c.y == 0 ? bandH * 0.7 : c.h * bandH) - gap)
            let isLit = flashAlive && lit == idx
            let isTested = tested.contains(idx)
            (isLit ? NSColor.controlAccentColor
                    : isTested ? NSColor.systemGreen.withAlphaComponent(0.6)
                    : NSColor(calibratedWhite: 0.5, alpha: 0.15)).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
            let ps = NSMutableParagraphStyle(); ps.alignment = .center
            NSAttributedString(string: c.label, attributes: [
                .font: NSFont.systemFont(ofSize: min(8.5, rect.height * 0.3), weight: isLit ? .bold : .medium),
                .foregroundColor: isLit ? NSColor.white : NSColor.labelColor,
                .paragraphStyle: ps
            ]).draw(in: rect.insetBy(dx: 1, dy: rect.height * 0.34))
        }
        let remain = cells.count - tested.count
        let text = tested.isEmpty ? "点击此处取得焦点后逐键按下 · 共 \(cells.count) 键（全键盘含小键盘/方向键）"
            : (remain == 0 ? "✓ 全部 \(cells.count) 键已点亮 · Esc 退出" : "已测 \(tested.count)/\(cells.count) · 剩余 \(remain)")
        NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: (remain == 0 && !tested.isEmpty) ? NSColor.systemGreen : NSColor.secondaryLabelColor,
        ]).draw(at: NSPoint(x: bounds.midX - 190, y: pad / 2))
    }
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
