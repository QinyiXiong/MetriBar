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

/// 全键键盘画布：ANSI 布局逐格渲染，物理按键实时点亮，未测灰色、已测绿色，底部进度。
final class KeyboardLayoutView: NSView {
    private struct Key { let label: String; let chars: Set<String>; let codes: Set<UInt16>; var w: CGFloat }
    private var keys: [[Int]] = []            // 每行 key 索引
    private var flat: [Key] = []
    private var tested: Set<Int> = []
    private var lit: Int?
    private var litAt = Date.distantPast

    private func k(_ label: String, _ chars: String = "", _ codes: UInt16...) -> Key {
        var cs = Set(chars.lowercased().map(String.init))
        if label.count == 1 { cs.insert(label.lowercased()) }
        return Key(label: label, chars: cs, codes: Set(codes), w: 1)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        buildLayout()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func buildLayout() {
        func wide(_ key: Key, _ w: CGFloat) -> Key { var x = key; x.w = w; return x }
        let fnCodes: [UInt16] = [122,120,99,118,96,97,98,100,101,109,103,111]
        let numLabels = ["`","1","2","3","4","5","6","7","8","9","0","-","="]
        let numCodes: [UInt16] = [50,18,19,20,21,23,22,26,28,25,24,27,24]
        let qwerty = zip(["Q","W","E","R","T","Y","U","I","O","P"], [UInt16](repeating: 0, count: 10))
        let qwertyCodes: [UInt16] = [12,13,14,15,17,16,32,34,31,35]
        _ = qwerty
        let asdfCodes: [UInt16] = [0,1,2,3,5,4,6,7,8]
        let zxcvLabels = ["Z","X","C","V","B","N","M"]
        let zxcvCodes: [UInt16] = [46,45,47,9,11,45,0x2E]
        var rows: [[Key]] = []
        rows.append([k("esc","",53)] + zip(["F1","F2","F3","F4","F5","F6","F7","F8","F9","F10","F11","F12"], fnCodes).map { k($0,"",$1) } + [k("del","",117)])
        rows.append(numLabels.enumerated().map { i, l in k(l, l, numCodes[i]) } + [wide(k("delete","",51), 1.6)])
        rows.append([wide(k("tab","",48), 1.5)] + zip(["Q","W","E","R","T","Y","U","I","O","P"], qwertyCodes).map { k($0, String($0).lowercased(), $1) } + [k("[","[",39), k("]","]",42), k("\\","\\\\",42)])
        rows.append([wide(k("caps lock","",57), 1.8)] + zip(["A","S","D","F","G","H","J","K","L"], asdfCodes).map { k($0, String($0).lowercased(), $1) } + [k(";", ";", 41), k("'", "'", 39), wide(k("return","",36), 1.9)])
        rows.append([wide(k("⇧ shift","",56), 2.3)] + zxcvLabels.enumerated().map { i, l in k(l, l.lowercased(), zxcvCodes[i]) } + [k("/","/",76), wide(k("⇧ shift","",60), 2.3)])
        rows.append([wide(k("control","",59), 1.3), wide(k("option","",58), 1.3), wide(k("command","",55), 1.3),
                     wide(k("space","",49), 6.2), wide(k("command","",54), 1.3), wide(k("fn","",63), 1.3), wide(k("option","",61), 1.3),
                     k("←","",123), k("↑","",126), k("↓","",125), k("→","",124)])

        flat = rows.flatMap { $0 }
        keys = rows.map { row in row.indices.map { _ in 0 } }
        // 直接按行顺序展开索引即可
        var cursor = 0
        keys = rows.map { row in let r = (cursor..<(cursor + row.count)).map { $0 }; cursor += row.count; return r }
    }

    override var acceptsFirstResponder: Bool { true }
    override func viewDidMoveToWindow() { window?.makeFirstResponder(self) }
    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self) }

    override func keyDown(with event: NSEvent) {
        let ch = (event.charactersIgnoringModifiers ?? "").lowercased()
        var hit: Int?
        if !ch.isEmpty, let c = ch.first {
            hit = flat.firstIndex(where: { $0.chars.contains(String(c)) })
        }
        if hit == nil { hit = flat.firstIndex(where: { $0.codes.contains(event.keyCode) }) }
        if let i = hit {
            tested.insert(i); lit = i; litAt = Date()
            needsDisplay = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedWhite: 0.5, alpha: 0.08).setFill()
        let outer = NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10)
        outer.fill()

        let pad: CGFloat = 12, gap: CGFloat = 5
        let bottomBar: CGFloat = 26
        let area = bounds.insetBy(dx: pad, dy: pad)
        let rowsN = CGFloat(keys.count)
        var y = area.maxY
        let flashAlive = lit != nil && Date().timeIntervalSince(litAt) < 0.28
        var idx = 0
        for row in keys {
            let unitW = (area.width - gap * 12) / 15.0
            let rowH = (area.height - bottomBar) / rowsN - gap
            var x = area.minX
            for _ in row {
                let key = flat[idx]
                defer { idx += 1 }
                let w = unitW * key.w
                let rect = NSRect(x: x, y: y - rowH, width: w, height: rowH)
                let isLit = flashAlive && lit == idx
                let isTested = tested.contains(idx)
                (isLit ? NSColor.controlAccentColor
                        : isTested ? NSColor.systemGreen.withAlphaComponent(0.55)
                        : NSColor(calibratedWhite: 0.5, alpha: 0.16)).setFill()
                NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
                let p = NSMutableParagraphStyle(); p.alignment = .center
                NSAttributedString(string: key.label, attributes: [
                    .font: NSFont.systemFont(ofSize: rect.height > 34 ? 9 : 8.5, weight: isLit ? .bold : .medium),
                    .foregroundColor: isLit ? NSColor.white : NSColor.labelColor,
                    .paragraphStyle: p
                ]).draw(in: rect.insetBy(dx: 2, dy: rect.height * 0.32))
                x += w + gap
            }
            y -= rowH + gap
        }

        let remain = flat.count - tested.count
        let text = tested.isEmpty ? "点击此区域取得焦点后，逐键按下…共 \(flat.count) 键"
            : (remain == 0 ? "✓ 全部 \(flat.count) 键已点亮 · 按 Esc 退出" : "已测 \(tested.count)/\(flat.count) · 剩余 \(remain)")
        NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: remain == 0 && !tested.isEmpty ? NSColor.systemGreen : NSColor.secondaryLabelColor
        ]).draw(at: NSPoint(x: bounds.midX - 110, y: pad * 0.5 + 2))
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
