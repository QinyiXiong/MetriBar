//
//  TranslateTab.swift
//  MetriBar
//
//  视频翻译：桥接本地 FunASR 流水线（Person/translation 项目）。
//  每个任务 = 一个独立 Python 子进程（transcribe.py），**进程退出即模型卸载**，
//  绝不常驻内存。模型目录 / Python 路径 / 翻译端点全部可在界面上配置，
//  通过 METRIBAR_* 环境变量注入（脚本侧已做向后兼容支持）。
//

import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers

// MARK: - 配置（UserDefaults 持久化）

@MainActor
final class TranslateSettings: ObservableObject {
    static let shared = TranslateSettings()

    private let d = UserDefaults.standard
    func get(_ k: String, _ def: String = "") -> String { d.string(forKey: "translate.\(k)") ?? def }
    func set(_ k: String, _ v: String) { d.set(v, forKey: "translate.\(k)") }

    @Published var pipelineDir: String
    @Published var pythonPath: String
    @Published var modelDir: String
    @Published var translateBaseURL: String
    @Published var translateAPIKey: String
    @Published var translateModel: String
    @Published var burnIn: Bool

    private init() {
        pipelineDir = d.string(forKey: "translate.pipelineDir") ?? "/Users/qinyixiong/Programer/CodeManager/Person/translation"
        pythonPath = d.string(forKey: "translate.pythonPath") ?? "/opt/anaconda3/envs/work/bin/python3"
        modelDir = d.string(forKey: "translate.modelDir") ?? ""
        translateBaseURL = d.string(forKey: "translate.translateBaseURL") ?? "http://127.0.0.1:18888/v1"
        translateAPIKey = d.string(forKey: "translate.translateAPIKey") ?? ""
        translateModel = d.string(forKey: "translate.translateModel") ?? "hy-mt2-7b"
        burnIn = (d.string(forKey: "translate.burnIn") ?? "1") == "1"
    }

    func persistAll() {
        set("pipelineDir", pipelineDir); set("pythonPath", pythonPath); set("modelDir", modelDir)
        set("translateBaseURL", translateBaseURL); set("translateAPIKey", translateAPIKey)
        set("translateModel", translateModel); set("burnIn", burnIn ? "1" : "0")
    }

    var effectiveModelDir: String { modelDir.isEmpty ? pipelineDir + "/models" : modelDir }
}

// MARK: - 任务模型

enum TaskStatus: String { case queued = "排队中", running = "转写中", done = "完成", failed = "失败", stopped = "已停止" }

struct TranslateTask: Identifiable, Equatable {
    let id = UUID()
    var videoPath: String
    var modelKey: String
    var status: TaskStatus = .queued
    var stage: String = ""
    var percent: Double = 0
    var message: String = ""
}

@MainActor
final class TranslateModel: ObservableObject {
    @Published var tasks: [TranslateTask] = []
    @Published var selectedModelKey = "sensevoice"
    @Published var modelRows: [(key: String, dirName: String, bytes: Int64, present: Bool)] = []
    @Published var selfCheckText: String = ""
    @Published var running = false

    private var process: Process?
    private var stopRequested = false

    static let knownModels: [(key: String, dirName: String, label: String)] = [
        ("sensevoice", "SenseVoiceSmall", "SenseVoice Small · 中英快速"),
        ("nano", "Fun-ASR-Nano-2512", "Fun-ASR Nano · 中文更强"),
        ("mlt-nano", "Fun-ASR-MLT-Nano-2512", "Fun-ASR MLT Nano · 多语种"),
    ]

    func scanModels(_ settings: TranslateSettings) {
        let fm = FileManager.default
        var rows: [(String, String, Int64, Bool)] = []
        for m in Self.knownModels {
            let dir = settings.effectiveModelDir + "/" + m.dirName
            var isDir: ObjCBool = false
            let present = fm.fileExists(atPath: dir, isDirectory: &isDir) && isDir.boolValue
            var bytes: Int64 = 0
            if present, let en = fm.enumerator(atPath: dir) {
                for case let f as String in en where !f.hasPrefix(".") {
                    if let a = try? fm.attributesOfItem(atPath: dir + "/" + f), let n = a[.size] as? Int64 { bytes += n }
                }
            }
            rows.append((m.key, m.dirName, bytes, present))
        }
        DispatchQueue.main.async { [weak self] in self?.modelRows = rows }
    }

    // MARK: 队列执行（串行，一次只跑一个子进程）

    func runNext() {
        guard !running, let idx = tasks.firstIndex(where: { $0.status == .queued }) else { return }
        running = true
        stopRequested = false
        let task = tasks[idx]
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.execute(task)
        }
    }

    private func update(_ id: UUID, _ patch: @escaping (inout TranslateTask) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let i = self.tasks.firstIndex(where: { $0.id == id }) else { return }
            patch(&self.tasks[i])
        }
    }

    private func execute(_ task: TranslateTask) {
        let settings = TranslateSettings.shared
        update(task.id) { $0.status = .running; $0.stage = "launch"; $0.message = "启动转写进程（模型加载中，首次较慢）" }

        let stem = (task.videoPath as NSString).deletingPathExtension
        let outSrt = stem + ".srt"
        let args = [settings.pipelineDir + "/transcribe.py",
                    (task.videoPath as NSString).lastPathComponent,
                    task.videoPath, outSrt, task.modelKey]

        var env = ProcessInfo.processInfo.environment
        env["METRIBAR_MODEL_DIR"] = settings.effectiveModelDir
        env["METRIBAR_JSON_PROGRESS"] = "1"
        env["PYTHONUNBUFFERED"] = "1"
        env["METRIBAR_TRANSLATE_BASE_URL"] = settings.translateBaseURL
        // GUI 启动的进程 PATH 很精简：补上 homebrew 等，保证脚本能找到 ffmpeg
        env["PATH"] = "/opt/homebrew/bin:/opt/homebrew/opt/ffmpeg-full/bin:/usr/local/bin:/usr/bin:/bin:" + (env["PATH"] ?? "")
        if !settings.translateAPIKey.isEmpty { env["METRIBAR_TRANSLATE_API_KEY"] = settings.translateAPIKey }
        if !settings.translateModel.isEmpty { env["METRIBAR_TRANSLATE_MODEL"] = settings.translateModel }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: settings.pythonPath)
        p.arguments = args
        p.currentDirectoryURL = URL(fileURLWithPath: settings.pipelineDir)
        p.environment = env

        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = String(data: handle.availableData, encoding: .utf8) ?? ""
            guard let self else { return }
            for line in chunk.split(separator: "\n", omittingEmptySubsequences: true) {
                DispatchQueue.main.async { self.consume(line: String(line), taskId: task.id) }
            }
        }

        process = p
        do { try p.run() } catch {
            update(task.id) { $0.status = .failed; $0.message = "无法启动 Python：\(error.localizedDescription)（检查设置里的 Python 路径）" }
            process = nil; finish(); return
        }
        Diag.notice(Diag.lifecycle, "视频翻译·启动 \(task.modelKey) \((task.videoPath as NSString).lastPathComponent)")
        p.waitUntilExit()
        pipe.fileHandleForReading.readabilityHandler = nil
        process = nil

        let rc = p.terminationStatus
        if stopRequested {
            update(task.id) { $0.status = .stopped; $0.message = "已停止 · 子进程退出，模型已卸载" }
        } else if rc != 0 {
            update(task.id) { $0.status = .failed; $0.message = "转写失败（退出码 \(rc)）" }
        } else {
            if settings.burnIn && !burnIn(task, outSrt: outSrt) {
                update(task.id) { $0.status = .failed; $0.message = "字幕烧制失败（检查 ffmpeg 是否安装）" }
            } else {
                update(task.id) { $0.status = .done; $0.stage = "done"; $0.percent = 100; $0.message = "完成 · 模型已随进程卸载" }
            }
        }
        finish()
    }

    private func consume(line raw: String, taskId: UUID) {
        let line = raw.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty else { return }
        if line.hasPrefix("{"), line.contains("\"metriBarProgress\""), let data = line.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let stage = obj["stage"] as? String ?? ""
            let pct = (obj["percent"] as? NSNumber)?.doubleValue ?? 0
            let msg = obj["message"] as? String ?? ""
            update(taskId) { $0.stage = stage; $0.percent = pct; $0.message = msg }
            return
        }
        update(taskId) { $0.message = String(line.suffix(90)) }
    }

    private func burnIn(_ task: TranslateTask, outSrt: String) -> Bool {
        let settings = TranslateSettings.shared
        let stem = (task.videoPath as NSString).deletingPathExtension
        let srt = FileManager.default.fileExists(atPath: stem + ".(双语).srt") ? stem + ".(双语).srt" : outSrt
        guard FileManager.default.fileExists(atPath: srt) else { return false }
        let out = stem + ".字幕版.mp4"
        update(task.id) { $0.stage = "burn"; $0.message = "烧录字幕中（ffmpeg）…" }
        let (rc, _) = Shell.run(settings.pythonPath,
                                 [settings.pipelineDir + "/embed_subtitle.py", task.videoPath, "-s", srt, "-o", out])
        return rc == 0
    }

    // MARK: 队列操作

    func enqueue(_ urls: [URL]) {
        var added = false
        for url in urls where ["mp4", "mov", "mkv", "avi", "m4v"].contains(url.pathExtension.lowercased()) {
            tasks.append(TranslateTask(videoPath: url.path, modelKey: selectedModelKey))
            added = true
        }
        Diag.notice(Diag.lifecycle, "视频翻译·入队 \(urls.count) 项")
        if added { runNext() }
    }

    func stopCurrent() { stopRequested = true; process?.terminate() }

    func remove(_ id: UUID) {
        if let i = tasks.firstIndex(where: { $0.id == id }), tasks[i].status != .running { tasks.remove(at: i) }
    }

    func retry(_ id: UUID) {
        if let i = tasks.firstIndex(where: { $0.id == id }), tasks[i].status != .running {
            tasks[i].status = .queued; tasks[i].percent = 0; tasks[i].message = ""
            runNext()
        }
    }

    private func finish() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.running = false
            self.runNext()
        }
    }

    // MARK: Python 自动发现（免配置：找一个能 import funasr 的解释器）

    func autoDetectPython(_ settings: TranslateSettings) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let fm = FileManager.default
            var candidates = [settings.pythonPath, "/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"]
            for base in ["/opt/anaconda3/bin", "/opt/anaconda3/envs", "~/anaconda3/envs", "~/miniconda3/envs"] {
                let expanded = (base as NSString).expandingTildeInPath
                if base.hasSuffix("/envs"), let envs = try? fm.contentsOfDirectory(atPath: expanded) {
                    candidates.append(contentsOf: envs.map { expanded + "/" + $0 + "/bin/python3" })
                } else {
                    candidates.append(base.hasSuffix("bin") ? base + "/python3" : expanded)
                }
            }
            var seen = Set<String>()
            for py in candidates where fm.isExecutableFile(atPath: py) && seen.insert(py).inserted {
                let (rc, _) = Shell.run(py, ["-c", "import funasr"])
                if rc == 0 {
                    DispatchQueue.main.async {
                        if settings.pythonPath != py {
                            settings.pythonPath = py
                            settings.set("pythonPath", py)
                        }
                        self?.selfCheckText = "✓ 已自动选择转写环境：\(py)"
                        Diag.notice(Diag.lifecycle, "视频翻译·自动发现 Python：\(py)")
                    }
                    return
                }
            }
        }
    }

    func selfCheck(_ settings: TranslateSettings) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var msgs: [String] = []
            let (rcPy, _) = Shell.run(settings.pythonPath, ["--version"])
            msgs.append(rcPy == 0 ? "✓ Python 可用（含转写依赖则更优）" : "✗ Python 不可用（检查路径设置）")
            let fm = FileManager.default
            msgs.append(fm.fileExists(atPath: settings.pipelineDir + "/transcribe.py") ? "✓ 转写脚本就绪" : "✗ 未找到 transcribe.py（检查流水线目录）")
            let ready = Self.knownModels.filter { fm.fileExists(atPath: settings.effectiveModelDir + "/" + $0.dirName) }
            msgs.append(ready.isEmpty ? "✗ 模型目录为空" : "✓ 已装模型：" + ready.map(\.key).joined(separator: ", "))
            msgs.append(fm.fileExists(atPath: settings.effectiveModelDir + "/fsmn-vad") ? "✓ VAD 就绪" : "⚠ 缺少 fsmn-vad")
            let (rcFF, _) = Shell.run("/usr/bin/arch", ["-arm64", "/bin/echo", "x"])
            _ = rcFF
            msgs.append(Self.ffmpegPresent() ? "✓ ffmpeg 就绪" : "✗ 未找到 ffmpeg（烧录不可用）")
            DispatchQueue.main.async { self?.selfCheckText = msgs.joined(separator: "\n") }
        }
    }

    private static func ffmpegPresent() -> Bool {
        for p in ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"] where FileManager.default.isExecutableFile(atPath: p) { return true }
        let (_, out) = Shell.run("/bin/sh", ["-c", "command -v ffmpeg"])
        return !out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

// MARK: - 视图

struct TranslateTab: View {
    @ObservedObject private var settings = TranslateSettings.shared
    @StateObject private var model = TranslateModel()
    @State private var showingSettings = false

    var body: some View {
        HSplitView {
            queueColumn.frame(minWidth: 430, idealWidth: 520, minHeight: 480)
            sideColumn.frame(minWidth: 300, idealWidth: 340, minHeight: 480)
        }
        .onAppear { model.scanModels(settings); model.autoDetectPython(settings) }
    }

    private var queueColumn: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button { pickFiles() } label: { Label("添加视频", systemImage: "plus") }
                if model.running {
                    Button(role: .destructive) { model.stopCurrent() } label: { Label("停止当前", systemImage: "stop.circle") }
                }
                Spacer()
                Picker("默认模型", selection: $model.selectedModelKey) {
                    ForEach(model.modelRows, id: \.key) { Text($0.dirName).tag($0.key) }
                }.frame(width: 250).labelsHidden()
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            Divider()
            ScrollView {
                LazyVStack(spacing: 8) {
                    if model.tasks.isEmpty { dropHint }
                    ForEach(model.tasks) { taskView($0) }
                }
                .padding(14)
            }
            .dropDestination(for: URL.self) { urls, _ in model.enqueue(urls); return true }
        }
    }

    private var dropHint: some View {
        VStack(spacing: 8) {
            Image(systemName: "film.stack").font(.system(size: 34)).foregroundColor(.secondary)
            Text("拖入视频，或点「添加视频」").font(.system(size: 13, weight: .medium))
            Text("转写 → 翻译 → 双语字幕（可选烧录）。\n模型随任务进程加载、结束即卸载，不占常驻内存。")
                .font(.system(size: 11)).foregroundColor(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 46)
    }

    private func taskView(_ task: TranslateTask) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "film").foregroundColor(.secondary)
                Text((task.videoPath as NSString).lastPathComponent).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Text(task.modelKey).font(.system(size: 9, weight: .medium))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(Color.accentColor.opacity(0.12))).foregroundColor(.accentColor)
                Spacer()
                statusChip(task.status)
            }
            if task.status == .running || task.percent > 0 {
                ProgressView(value: max(task.percent, 2)).progressViewStyle(.linear)
            }
            if !task.message.isEmpty {
                Text(task.message).font(.system(size: 10)).foregroundColor(.secondary).lineLimit(1)
            }
            HStack(spacing: 10) {
                Button("打开输出") { revealOutput(task) }.controlSize(.mini)
                if task.status == .failed || task.status == .stopped { Button("重试") { model.retry(task.id) }.controlSize(.mini) }
                if task.status != .running { Button("移除") { model.remove(task.id) }.controlSize(.mini) }
                Spacer()
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.primary.opacity(0.045)))
    }

    private func statusChip(_ s: TaskStatus) -> some View {
        let color: Color = s == .done ? .green : s == .failed ? .red : s == .running ? .accentColor : .secondary
        return Text(s.rawValue).font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.14))).foregroundColor(color)
    }

    private func pickFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        if #available(macOS 14.0, *) { panel.allowedContentTypes = [.movie, .video, .mpeg4Movie, .quickTimeMovie] }
        panel.prompt = "加入队列"
        guard panel.runModal() == .OK else { return }
        model.enqueue(panel.urls)
    }

    private func revealOutput(_ task: TranslateTask) {
        let stem = (task.videoPath as NSString).deletingPathExtension
        for cand in [stem + ".字幕版.mp4", stem + ".(双语).srt", stem + ".(中文).srt", stem + ".srt"] {
            if FileManager.default.fileExists(atPath: cand) {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: cand)]); return
            }
        }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: task.videoPath).deletingLastPathComponent()])
    }

    private var sideColumn: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("本地 ASR 模型", systemImage: "circle.hexagongrid.fill").font(.system(size: 13, weight: .bold))
            ForEach(model.modelRows, id: \.key) { row in modelCard(row) }
            Divider()
            Button("环境自检") { model.selfCheck(settings) }
            if !model.selfCheckText.isEmpty {
                Text(model.selfCheckText).font(.system(size: 11)).textSelection(.enabled)
                    .padding(10).background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
            }
            Spacer()
            Button { showingSettings = true } label: { Label("高级设置（转写工程 · 模型目录 · 翻译端点）", systemImage: "gearshape") }
            Text("模型仅在任务运行期间驻留内存，进程退出即完全回收。")
                .font(.system(size: 10)).foregroundColor(.secondary)
        }
        .padding(14)
        .sheet(isPresented: $showingSettings) { TranslateSettingsPanel(settings: settings, model: model) }
    }

    private func modelCard(_ row: (key: String, dirName: String, bytes: Int64, present: Bool)) -> some View {
        let label = TranslateModel.knownModels.first(where: { $0.key == row.key })?.label ?? row.dirName
        return HStack(spacing: 8) {
            Image(systemName: row.present ? "checkmark.circle.fill" : "xmark.circle")
                .foregroundColor(row.present ? .green : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.system(size: 11, weight: .medium))
                Text(row.present ? String(format: "%.1f GB", Double(row.bytes) / 1e9) : "未安装")
                    .font(.system(size: 10)).foregroundColor(.secondary)
            }
            Spacer()
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.04)))
    }
}

// MARK: - 设置面板

struct TranslateSettingsPanel: View {
    @ObservedObject var settings: TranslateSettings
    @ObservedObject var model: TranslateModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("视频翻译设置").font(.system(size: 15, weight: .bold))
            group("转写环境") {
                Text("转写 = 语音→字幕的 Python 工程（含 transcribe.py）。App 会自动寻找装好依赖的环境，一般无需改动。")
                    .font(.system(size: 10)).foregroundColor(.secondary)
                pathField("Python 可执行文件", get: { settings.pythonPath }, set: { settings.pythonPath = $0 }, isDir: false)
                pathField("转写工程目录（含 transcribe.py）", get: { settings.pipelineDir }, set: { settings.pipelineDir = $0 }, isDir: true)
                Toggle("完成后烧录字幕进视频（ffmpeg，较慢）", isOn: $settings.burnIn)
            }
            group("模型") {
                pathField("模型目录（留空 = 流水线/models）", get: { settings.modelDir }, set: { settings.modelDir = $0 }, isDir: true)
                Text("模型不常驻：每个翻译任务独立子进程，结束即由系统回收全部内存。")
                    .font(.system(size: 10)).foregroundColor(.secondary)
            }
            group("翻译服务（OpenAI 兼容端点）") {
                TextField("Base URL", text: $settings.translateBaseURL)
                TextField("模型名", text: $settings.translateModel)
                SecureField("API Key（本机服务可留空）", text: $settings.translateAPIKey)
            }
            Spacer()
            HStack {
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") { settings.persistAll(); model.scanModels(settings); dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(18).frame(width: 460, height: 430)
    }

    private func group<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 12, weight: .semibold))
            content()
        }
    }

    @ViewBuilder
    private func pathField(_ label: String, get: @escaping () -> String, set: @escaping (String) -> Void, isDir: Bool) -> some View {
        HStack {
            TextField(label, text: Binding(get: get, set: set)).textFieldStyle(.roundedBorder)
            Button("选择") {
                let p = NSOpenPanel()
                p.canChooseDirectories = isDir
                p.canChooseFiles = !isDir
                if p.runModal() == .OK, let url = p.url { set(url.path) }
            }
        }
    }
}
