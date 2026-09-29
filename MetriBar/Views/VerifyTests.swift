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
    @StateObject private var store = KeyboardStore()

    func makeNSView(context: Context) -> KeyboardNSView { KeyboardNSView(store: store) }
    func updateNSView(_ nsView: KeyboardNSView, context: Context) {}
}

@MainActor
final class KeyboardStore: ObservableObject {
    @Published var presses: [String] = []
    @Published var total: Int = 0

    func record(_ event: NSEvent) {
        let label = event.charactersIgnoringModifiers?.uppercased().isEmpty == false
            ? event.charactersIgnoringModifiers!.uppercased()
            : Self.specialName(event.keyCode)
        total += 1
        presses.append(label)
        if presses.count > 80 { presses.removeFirst(presses.count - 80) }
    }

    static func specialName(_ code: UInt16) -> String {
        switch code {
        case 36: return "⏎"; case 48: return "⇥"; case 49: return "␣"; case 51: return "⌫"
        case 53: return "⎋"; case 123: return "←"; case 124: return "→"; case 125: return "↓"; case 126: return "↑"
        default: return "键\(code)"
        }
    }
}

final class KeyboardNSView: NSView {
    private let store: KeyboardStore
    private var label: NSTextField!

    init(store: KeyboardStore) {
        self.store = store
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedWhite: 0.5, alpha: 0.10).cgColor
        layer?.cornerRadius = 8
        label = NSTextField(labelWithString: "点击此区域后，按下任意键…")
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }
    override var acceptsFirstResponder: Bool { true }
    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self) }

    override func keyDown(with event: NSEvent) {
        store.record(event)
        refresh()
    }

    func refresh() {
        let tail = store.presses.suffix(24).reversed().joined(separator: " ")
        label.stringValue = "已按下 \(store.total) 次｜最近：\(tail)"
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
