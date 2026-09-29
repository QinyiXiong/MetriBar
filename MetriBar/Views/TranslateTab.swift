//
//  TranslateTab.swift
//  MetriBar
//
//  视频翻译（全自动零配置版）：
//   · Python 运行时 **已内置于 App**（Resources/python，独立可搬运 CPython）；
//   · 转写流水线脚本已内置（Resources/pipeline：transcribe.py / embed_subtitle.py）；
//   · 「一键构建环境」：基于内置 Python 在 App 数据目录建 venv，
//     经国内镜像自动安装 funasr/torch/openai/mlx-lm 等全部依赖（不含模型）；
//   · ASR 三模型 + Hy-MT2 翻译模型：一键从 **ModelScope 魔搭** 直连下载（带进度）；
//   · 「部署翻译服务」：mlx_lm.server 子进程跑 Hy-MT2（OpenAI 兼容端点），
//     随时可停——停止/任务结束 = 模型从内存卸载，不常驻。
//   · 转写任务 = 每任务一个子进程，跑完即退（模型随进程卸载）。
//

import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers

// MARK: - 内置路径

enum ToolPaths {
    static var bundledPython: String { (Bundle.main.resourcePath ?? "") + "/python/bin/python3" }
    static var bundledPipeline: String { (Bundle.main.resourcePath ?? "") + "/pipeline" }
    static var supportDir: String {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("MetriBar").path
    }
    static var envDir: String { supportDir + "/env" }
    static var envPython: String { envDir + "/bin/python3" }
    static var defaultModelDir: String { supportDir + "/models" }
}

// MARK: - 配置

@MainActor
final class TranslateSettings: ObservableObject {
    static let shared = TranslateSettings()
    private let d = UserDefaults.standard

    @Published var pipelineDir: String
    @Published var pythonPath: String
    @Published var modelDir: String
    @Published var translateBaseURL: String
    @Published var translateAPIKey: String
    @Published var translateModel: String
    @Published var serverPort: String
    @Published var burnIn: Bool

    private init() {
        pipelineDir = d.string(forKey: "translate.pipelineDir") ?? ToolPaths.bundledPipeline
        pythonPath = d.string(forKey: "translate.pythonPath") ?? ""
        modelDir = d.string(forKey: "translate.modelDir") ?? ""
        translateBaseURL = d.string(forKey: "translate.translateBaseURL") ?? "http://127.0.0.1:18888/v1"
        translateAPIKey = d.string(forKey: "translate.translateAPIKey") ?? ""
        translateModel = d.string(forKey: "translate.translateModel") ?? "hy-mt2-7b"
        serverPort = d.string(forKey: "translate.serverPort") ?? "18888"
        burnIn = (d.string(forKey: "translate.burnIn") ?? "1") == "1"
    }

    func persist(_ k: String, _ v: String) { d.set(v, forKey: "translate.\(k)") }

    var effectiveModelDir: String { modelDir.isEmpty ? ToolPaths.defaultModelDir : modelDir }
    var effectivePython: String {
        if !pythonPath.isEmpty, FileManager.default.isExecutableFile(atPath: pythonPath) { return pythonPath }
        if FileManager.default.isExecutableFile(atPath: ToolPaths.envPython) { return ToolPaths.envPython }
        if FileManager.default.isExecutableFile(atPath: ToolPaths.bundledPython) { return ToolPaths.bundledPython }
        return "/usr/bin/python3"
    }
    var effectivePipeline: String {
        FileManager.default.fileExists(atPath: pipelineDir + "/transcribe.py") ? pipelineDir : ToolPaths.bundledPipeline
    }
}

// MARK: - 模型目录（ModelScope）

struct ModelSpec: Identifiable {
    let id = UUID()
    let key: String
    let msRepo: String
    let dirName: String
    let label: String
    let sizeText: String
}

enum ModelCatalog {
    static let asr: [ModelSpec] = [
        ModelSpec(key: "sensevoice", msRepo: "iic/SenseVoiceSmall", dirName: "SenseVoiceSmall",
                  label: "SenseVoice Small · 中英快速", sizeText: "≈900 MB"),
        ModelSpec(key: "nano", msRepo: "iic/Fun-ASR-Nano-2512", dirName: "Fun-ASR-Nano-2512",
                  label: "Fun-ASR Nano · 中文更强", sizeText: "≈2 GB"),
        ModelSpec(key: "mlt-nano", msRepo: "iic/Fun-ASR-MLT-Nano-2512", dirName: "Fun-ASR-MLT-Nano-2512",
                  label: "Fun-ASR MLT Nano · 多语种", sizeText: "≈1.9 GB"),
    ]
    static let vad = ModelSpec(key: "vad", msRepo: "iic/fsmn-vad", dirName: "fsmn-vad",
                               label: "FSMN-VAD · 长音频断句必需", sizeText: "≈4 MB")
    static let mt = ModelSpec(key: "mt", msRepo: "mlx-community/Hy-MT2-7B-4bit", dirName: "Hy-MT2-7B-4bit",
                              label: "Hy-MT2-7B · 翻译大模型（MLX 4bit）", sizeText: "≈4 GB")
    static var all: [ModelSpec] { asr + [vad, mt] }
}

struct DownloadState: Identifiable {
    var id: String { spec.id.uuidString }
    let spec: ModelSpec
    var status: String = "未下载"
    var percent: Double = 0
    var filesDone: Int = 0
    var filesTotal: Int = 0
}

// MARK: - 主模型

@MainActor
final class TranslateModel: ObservableObject {
    struct TranslateTask: Identifiable, Equatable {
        let id = UUID()
        var videoPath: String
        var modelKey: String
        var status: String = "排队中"
        var stage: String = ""
        var percent: Double = 0
        var message: String = ""
    }

    @Published var tasks: [TranslateTask] = []
    @Published var selectedModelKey = "sensevoice"
    @Published var downloads: [DownloadState] = ModelCatalog.all.map { DownloadState(spec: $0) }
    @Published var envStatus: String = "未初始化"
    @Published var envBusy = false
    @Published var serverRunning = false
    @Published var log: [String] = []

    private var process: Process?
    private var serverProcess: Process?
    private var stopRequested = false

    func appendLog(_ s: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.log.append(s)
            if self.log.count > 200 { self.log.removeFirst(self.log.count - 200) }
        }
    }

    func refreshAvailability(_ settings: TranslateSettings) {
        let fm = FileManager.default
        let roots = [settings.effectiveModelDir, settings.pipelineDir + "/models"]
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            for i in self.downloads.indices {
                let spec = self.downloads[i].spec
                guard self.downloads[i].status != "下载中" else { continue }
                let present = roots.contains { fm.fileExists(atPath: $0 + "/" + spec.dirName) }
                self.downloads[i].status = present ? "✓ 已就绪" : "未下载"
            }
        }
    }

    func modelDir(for spec: ModelSpec, _ settings: TranslateSettings) -> String {
        let fm = FileManager.default
        if !settings.modelDir.isEmpty, fm.fileExists(atPath: settings.modelDir + "/" + spec.dirName) { return settings.modelDir + "/" + spec.dirName }
        let legacy = settings.pipelineDir + "/" + spec.dirName
        if fm.fileExists(atPath: legacy) { return legacy }
        return settings.effectiveModelDir + "/" + spec.dirName
    }

    // MARK: 一键构建 Python 环境（venv + 清华镜像，torch/funasr/mlx-lm）

    func buildEnv(_ settings: TranslateSettings) {
        guard !envBusy else { return }
        envBusy = true
        envStatus = "创建虚拟环境…"
        appendLog("→ 基于内置 Python 创建 venv：\(ToolPaths.envDir)")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let fm = FileManager.default
            try? fm.createDirectory(atPath: ToolPaths.supportDir, withIntermediateDirectories: true)
            if !fm.fileExists(atPath: ToolPaths.envPython) {
                let (rc, out) = Shell.run(ToolPaths.bundledPython, ["-m", "venv", ToolPaths.envDir])
                if rc != 0 { self?.failEnv("venv 创建失败：\(out.prefix(200))"); return }
            }
            DispatchQueue.main.async { self?.envStatus = "安装依赖（torch 较大，视网络约 3–15 分钟）…" }
            let pkgs = ["funasr==1.4.1", "openai", "opencc-python-reimplemented",
                        "soundfile", "python-multipart", "mlx-lm"]
            var ok = true
            for pkg in pkgs {
                DispatchQueue.main.async { self?.envStatus = "安装 \(pkg)…" }
                let (rc, out) = Shell.run(ToolPaths.envPython,
                        ["-m", "pip", "install", "--no-input", "-q",
                         "--index-url", "https://pypi.tuna.tsinghua.edu.cn/simple", pkg])
                self?.appendLog(rc == 0 ? "✓ \(pkg)" : "✗ \(pkg)：\(out.suffix(200))")
                if rc != 0 { ok = false; break }
            }
            let (rcV, _) = Shell.run(ToolPaths.envPython, ["-c", "import funasr, openai, soundfile"])
            DispatchQueue.main.async {
                self?.envBusy = false
                if ok, rcV == 0 {
                    self?.envStatus = "✓ 转写环境就绪"
                    self?.appendLog("✓ 环境就绪：\(ToolPaths.envPython)")
                } else {
                    self?.envStatus = "✗ 构建失败，见日志"
                }
            }
        }
    }

    private func failEnv(_ msg: String) {
        DispatchQueue.main.async { self.envBusy = false; self.envStatus = "✗ \(msg)" }
    }

    // MARK: ModelScope 直连下载（带进度）

    func download(_ spec: ModelSpec, _ settings: TranslateSettings) {
        guard let idx = downloads.firstIndex(where: { $0.id == spec.id.uuidString }), downloads[idx].status != "下载中" else { return }
        downloads[idx].status = "下载中"
        appendLog("→ ModelScope \(spec.msRepo) → \(settings.effectiveModelDir)/\(spec.dirName)")
        DispatchQueue.global(qos: .background).async { [weak self] in
            let (rc, out) = Shell.run("/usr/bin/curl", ["-fsSL",
                "https://modelscope.cn/api/v1/models/\(spec.msRepo)/repo/files?Revision=master&Recursive=true"])
            guard rc == 0, let data = out.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let d = obj["Data"] as? [String: Any],
                  let files = d["Files"] as? [[String: Any]] else {
                self?.updateDL(spec) { $0.status = "✗ 清单获取失败" }
                return
            }
            var paths: [String] = []
            func walk(_ arr: [[String: Any]]) {
                for f in arr {
                    if let p = f["Path"] as? String, !p.isEmpty, !p.hasPrefix(".") { paths.append(p) }
                    if let kids = f["Files"] as? [[String: Any]] { walk(kids) }
                }
            }
            walk(files)
            let total = paths.count
            let destRoot = settings.effectiveModelDir + "/" + spec.dirName
            try? FileManager.default.createDirectory(atPath: destRoot, withIntermediateDirectories: true)
            var done = 0
            DispatchQueue.main.async { if let i = self?.downloads.firstIndex(where: { $0.id == spec.id.uuidString }) { self?.downloads[i].filesTotal = total } }
            for path in paths {
                let dest = destRoot + "/" + path
                try? FileManager.default.createDirectory(atPath: (dest as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                let encoded = path.split(separator: "/").map { $0.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? String($0) }.joined(separator: "/")
                let url = "https://modelscope.cn/models/\(spec.msRepo)/resolve/master/\(encoded)"
                let (rcD, _) = Shell.run("/usr/bin/curl", ["-fSL", "--retry", "3", "-o", dest, url])
                done += 1
                let pct = Double(done) / Double(max(total, 1)) * 100
                self?.updateDL(spec) { $0.percent = pct; $0.filesDone = done
                    $0.status = rcD == 0 ? "下载中 \(done)/\(total) · \((path as NSString).lastPathComponent)" : "下载中 \(done)/\(total)（有失败，可重试）" }
                if rcD != 0 { self?.appendLog("✗ \(path)") }
            }
            self?.updateDL(spec) { $0.status = "✓ 已就绪"; $0.percent = 100 }
            self?.appendLog("✓ \(spec.label) 下载完成")
        }
    }

    func downloadAllMissing(_ settings: TranslateSettings) {
        for dl in downloads where !dl.status.hasPrefix("✓") && dl.status != "下载中" {
            download(dl.spec, settings)
        }
    }

    private func updateDL(_ spec: ModelSpec, _ patch: @escaping (inout DownloadState) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let i = self.downloads.firstIndex(where: { $0.id == spec.id.uuidString }) else { return }
            patch(&self.downloads[i])
        }
    }

    // MARK: 翻译服务部署（mlx_lm.server）/停止=卸载

    func toggleServer(_ settings: TranslateSettings) {
        if serverRunning || serverProcess?.isRunning == true { stopServer(); return }
        let mtDir = modelDir(for: ModelCatalog.mt, settings)
        guard FileManager.default.fileExists(atPath: mtDir) else { appendLog("✗ 未找到 Hy-MT2 翻译模型，请先在上方下载"); return }
        guard FileManager.default.isExecutableFile(atPath: ToolPaths.envPython) else { appendLog("✗ 请先「一键构建环境」（需要 mlx-lm）"); return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ToolPaths.envPython)
        p.arguments = ["-m", "mlx_lm.server", "--model", mtDir, "--port", settings.serverPort]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (env["PATH"] ?? "")
        p.environment = env
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let chunk = String(data: h.availableData, encoding: .utf8) ?? ""
            for l in chunk.split(separator: "\n") where !l.isEmpty { DispatchQueue.main.async { self?.appendLog("[服务] \(l.prefix(120))") } }
        }
        do { try p.run() } catch { appendLog("✗ 服务启动失败：\(error.localizedDescription)"); return }
        serverProcess = p; serverRunning = true
        Diag.notice(Diag.lifecycle, "翻译服务部署 mlx_lm.server :\(settings.serverPort)")
        appendLog("✓ 翻译服务已启动：\(settings.translateBaseURL)（停止按钮 = 卸载模型）")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            guard let self else { return }
            if self.serverProcess?.isRunning != true {
                self.serverRunning = false
                self.appendLog("✗ 服务已退出——检查 mlx-lm 是否装好、端口 \(settings.serverPort) 是否被占用")
            }
        }
    }

    func stopServer() {
        serverProcess?.terminate(); serverProcess = nil; serverRunning = false
        Diag.notice(Diag.lifecycle, "翻译服务停止（模型已从内存卸载）")
        appendLog("■ 翻译服务已停止，模型已从内存卸载")
    }

    // MARK: 转写任务（每任务一子进程·退出即卸载）

    func enqueue(_ urls: [URL]) {
        for url in urls where ["mp4", "mov", "mkv", "avi", "m4v"].contains(url.pathExtension.lowercased()) {
            tasks.append(TranslateTask(videoPath: url.path, modelKey: selectedModelKey))
        }
        if !tasks.isEmpty { runNext() }
    }

    func runNext() {
        guard process == nil, let idx = tasks.firstIndex(where: { $0.status == "排队中" }) else { return }
        stopRequested = false
        let task = tasks[idx]
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in self?.execute(task) }
    }

    private func patch(_ id: UUID, _ body: @escaping (inout TranslateTask) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let i = self.tasks.firstIndex(where: { $0.id == id }) else { return }
            body(&self.tasks[i])
        }
    }

    private func execute(_ task: TranslateTask) {
        let settings = TranslateSettings.shared
        patch(task.id) { $0.status = "转写中"; $0.message = "启动子进程（模型加载…跑完自动卸载）" }
        let stem = (task.videoPath as NSString).deletingPathExtension
        let outSrt = stem + ".srt"

        var env = ProcessInfo.processInfo.environment
        env["METRIBAR_MODEL_DIR"] = settings.effectiveModelDir
        env["METRIBAR_JSON_PROGRESS"] = "1"
        env["PYTHONUNBUFFERED"] = "1"
        env["METRIBAR_TRANSLATE_BASE_URL"] = settings.translateBaseURL
        if !settings.translateAPIKey.isEmpty { env["METRIBAR_TRANSLATE_API_KEY"] = settings.translateAPIKey }
        if !settings.translateModel.isEmpty { env["METRIBAR_TRANSLATE_MODEL"] = settings.translateModel }
        env["PATH"] = "/opt/homebrew/bin:/opt/homebrew/opt/ffmpeg-full/bin:/usr/local/bin:/usr/bin:/bin:" + (env["PATH"] ?? "")

        let p = Process()
        p.executableURL = URL(fileURLWithPath: settings.effectivePython)
        p.arguments = [settings.effectivePipeline + "/transcribe.py",
                       (task.videoPath as NSString).lastPathComponent, task.videoPath, outSrt, task.modelKey]
        p.currentDirectoryURL = URL(fileURLWithPath: (task.videoPath as NSString).deletingLastPathComponent)
        p.environment = env
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let chunk = String(data: h.availableData, encoding: .utf8) ?? ""
            for line in chunk.split(separator: "\n", omittingEmptySubsequences: true) {
                DispatchQueue.main.async { self?.consume(line: String(line), taskId: task.id) }
            }
        }
        process = p
        do { try p.run() } catch {
            patch(task.id) { $0.status = "失败"; $0.message = "无法启动 Python：\(error.localizedDescription)" }
            process = nil; finish(); return
        }
        p.waitUntilExit()
        pipe.fileHandleForReading.readabilityHandler = nil
        process = nil

        if stopRequested { patch(task.id) { $0.status = "已停止"; $0.message = "子进程已终止 · 模型已卸载" } }
        else if p.terminationStatus != 0 { patch(task.id) { $0.status = "失败"; $0.message = "退出码 \(p.terminationStatus)" } }
        else if settings.burnIn && !burnIn(task, outSrt: outSrt) { patch(task.id) { $0.status = "失败"; $0.message = "烧制失败（检查 ffmpeg）" } }
        else { patch(task.id) { $0.status = "完成"; $0.percent = 100; $0.message = "完成 · 模型已随进程卸载" } }
        finish()
    }

    private func consume(line raw: String, taskId: UUID) {
        let line = raw.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty else { return }
        if line.hasPrefix("{"), line.contains("\"metriBarProgress\""), let data = line.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            patch(taskId) { $0.stage = obj["stage"] as? String ?? ""
                           $0.percent = (obj["percent"] as? NSNumber)?.doubleValue ?? 0
                           $0.message = obj["message"] as? String ?? "" }
            return
        }
        patch(taskId) { $0.message = String(line.suffix(90)) }
    }

    private func burnIn(_ task: TranslateTask, outSrt: String) -> Bool {
        let settings = TranslateSettings.shared
        let stem = (task.videoPath as NSString).deletingPathExtension
        let srt = FileManager.default.fileExists(atPath: stem + ".(双语).srt") ? stem + ".(双语).srt" : outSrt
        guard FileManager.default.fileExists(atPath: srt) else { return false }
        patch(task.id) { $0.message = "烧录字幕中（ffmpeg）…" }
        let (rc, _) = Shell.run(settings.effectivePython,
                                 [settings.effectivePipeline + "/embed_subtitle.py", task.videoPath, "-s", srt, "-o", stem + ".字幕版.mp4"])
        return rc == 0
    }

    func stopCurrent() { stopRequested = true; process?.terminate() }
    func remove(_ id: UUID) { if let i = tasks.firstIndex(where: { $0.id == id }), tasks[i].status != "转写中" { tasks.remove(at: i) } }
    func retry(_ id: UUID) {
        if let i = tasks.firstIndex(where: { $0.id == id }), tasks[i].status != "转写中" {
            tasks[i].status = "排队中"; tasks[i].percent = 0; runNext()
        }
    }
    private func finish() { DispatchQueue.main.async { [weak self] in self?.runNext() } }
}

// MARK: - 视图

struct TranslateTab: View {
    @ObservedObject private var settings = TranslateSettings.shared
    @StateObject private var model = TranslateModel()

    var body: some View {
        HSplitView {
            queueColumn.frame(minWidth: 420, idealWidth: 500, minHeight: 480)
            sideColumn.frame(minWidth: 320, idealWidth: 360, minHeight: 480)
        }
        .onAppear { model.refreshAvailability(settings) }
    }

    private var queueColumn: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button { pickFiles() } label: { Label("添加视频", systemImage: "plus") }
                Picker("模型", selection: $model.selectedModelKey) {
                    ForEach(ModelCatalog.asr) { Text($0.dirName).tag($0.key) }
                }.frame(width: 220).labelsHidden()
                Spacer()
                Button { model.toggleServer(settings) } label: {
                    Label(model.serverRunning ? "停止翻译服务" : "部署翻译服务",
                          systemImage: model.serverRunning ? "stop.circle.fill" : "play.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(model.serverRunning ? .red : .accentColor)
                .help("启停本地 Hy-MT2 翻译服务（mlx_lm.server）。停止 = 模型从内存卸载")
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
            Divider()
            logPanel
        }
    }

    private var dropHint: some View {
        VStack(spacing: 8) {
            Image(systemName: "film.stack").font(.system(size: 34)).foregroundColor(.secondary)
            Text("拖入视频，或点「添加视频」").font(.system(size: 13, weight: .medium))
            Text("转写 → 翻译 → 双语字幕（可选烧录）。\n运行时与脚本已内置；模型随任务进程加载、结束即卸载。")
                .font(.system(size: 11)).foregroundColor(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 40)
    }

    private func taskView(_ task: TranslateModel.TranslateTask) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "film").foregroundColor(.secondary)
                Text((task.videoPath as NSString).lastPathComponent).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Spacer()
                Text(task.status).font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .background(Capsule().fill(statusColor(task.status).opacity(0.14))).foregroundColor(statusColor(task.status))
            }
            if task.percent > 0 { ProgressView(value: max(task.percent, 2)) }
            if !task.message.isEmpty { Text(task.message).font(.system(size: 10)).foregroundColor(.secondary).lineLimit(1) }
            HStack(spacing: 10) {
                Button("打开输出") { reveal(task.videoPath) }.controlSize(.mini)
                if task.status == "失败" || task.status == "已停止" { Button("重试") { model.retry(task.id) }.controlSize(.mini) }
                if task.status != "转写中" { Button("移除") { model.remove(task.id) }.controlSize(.mini) }
                Spacer()
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.primary.opacity(0.045)))
    }

    private func statusColor(_ s: String) -> Color {
        switch s { case "完成": return .green; case "失败": return .red; case "转写中": return .accentColor; default: return .secondary }
    }

    private func pickFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = "加入队列"
        guard panel.runModal() == .OK else { return }
        model.enqueue(panel.urls)
    }

    private func reveal(_ videoPath: String) {
        let stem = (videoPath as NSString).deletingPathExtension
        for cand in [stem + ".字幕版.mp4", stem + ".(双语).srt", stem + ".(中文).srt", stem + ".srt"] {
            if FileManager.default.fileExists(atPath: cand) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: cand)]); return }
        }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: videoPath).deletingLastPathComponent()])
    }

    private var sideColumn: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("运行时与依赖", systemImage: "shippingbox.fill").font(.system(size: 13, weight: .bold))
            HStack(spacing: 8) {
                Button(model.envBusy ? "构建中…" : "一键构建环境") { model.buildEnv(settings) }.disabled(model.envBusy)
                    .help("基于 App 内置独立 Python 建 venv，经清华镜像自动装 funasr/torch/mlx-lm 等全部依赖（模型除外）")
                Text(model.envStatus).font(.system(size: 10)).foregroundColor(.secondary).lineLimit(2)
            }
            Divider()
            Label("模型 · ModelScope 魔搭", systemImage: "arrow.down.circle.fill").font(.system(size: 13, weight: .bold))
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(model.downloads) { dl in downloadRow(dl) }
                }
            }
            Button("全部下载缺失") { model.downloadAllMissing(settings) }.controlSize(.small)
            Spacer()
            DisclosureGroup("高级设置（目录 / 端点）") { settingsRows }.font(.system(size: 11))
        }
        .padding(14)
    }

    private func downloadRow(_ dl: DownloadState) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: dl.status.hasPrefix("✓") ? "checkmark.circle.fill" : (dl.status == "下载中" ? "arrow.triangle.2.circlepath" : "circle"))
                    .foregroundColor(dl.status.hasPrefix("✓") ? .green : dl.status == "下载中" ? .accentColor : .secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(dl.spec.label).font(.system(size: 11, weight: .medium))
                    Text("\(dl.spec.msRepo) · \(dl.spec.sizeText)").font(.system(size: 9)).foregroundColor(.secondary)
                }
                Spacer()
                if dl.status != "下载中", !dl.status.hasPrefix("✓") {
                    Button("下载") { model.download(dl.spec, settings) }.controlSize(.mini)
                }
            }
            if dl.status == "下载中" { ProgressView(value: dl.percent) }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.04)))
    }

    private var settingsRows: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Python：\(TranslateSettings.shared.effectivePython)")
                .font(.system(size: 9, design: .monospaced)).foregroundColor(.secondary).textSelection(.enabled)
            pathRow("模型目录") { settings.modelDir } set: { v in settings.modelDir = v; settings.persist("modelDir", v) }
            pathRow("转写工程目录") { settings.pipelineDir } set: { v in settings.pipelineDir = v; settings.persist("pipelineDir", v) }
            TextField("翻译端点 Base URL", text: $settings.translateBaseURL).onSubmit { settings.persist("translateBaseURL", settings.translateBaseURL) }
            HStack {
                TextField("服务端口", text: $settings.serverPort).frame(width: 90).onSubmit { settings.persist("serverPort", settings.serverPort) }
                TextField("翻译模型名", text: $settings.translateModel).onSubmit { settings.persist("translateModel", settings.translateModel) }
            }
            SecureField("API Key（本机服务可留空）", text: $settings.translateAPIKey).onSubmit { settings.persist("translateAPIKey", settings.translateAPIKey) }
            Toggle("烧录字幕进视频（ffmpeg）", isOn: $settings.burnIn).onChange(of: settings.burnIn) { on in settings.persist("burnIn", on ? "1" : "0") }
        }
        .textFieldStyle(.roundedBorder)
        .controlSize(.small)
        .padding(.top, 4)
    }

    private func pathRow(_ label: String, get: @escaping () -> String, set: @escaping (String) -> Void) -> some View {
        HStack {
            TextField(label, text: Binding(get: get, set: set))
            Button("选择") {
                let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false
                if p.runModal() == .OK, let url = p.url { set(url.path) }
            }
        }
    }

    private var logPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("日志").font(.system(size: 10, weight: .semibold)).foregroundColor(.secondary)
                Spacer()
                Button("清空") { model.log.removeAll() }.controlSize(.mini)
            }.padding(.horizontal, 12).padding(.top, 8)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(model.log.enumerated()), id: \.offset) { i, line in
                            Text(line).font(.system(size: 9, design: .monospaced))
                                .foregroundColor(line.hasPrefix("✗") ? .red : line.hasPrefix("✓") ? .green : .secondary)
                                .id(i).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }.padding(8)
                }
                .frame(height: 90)
                .onChange(of: model.log.count) { _ in proxy.scrollTo(model.log.count - 1, anchor: .bottom) }
            }
        }
    }
}
