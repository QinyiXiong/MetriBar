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
    /// 独立 CPython 运行时：首次「一键构建环境」时经国内镜像自动下载到数据目录（不再内置于 App）。
    static let runtimeVersion = "cpython-3.11.13+20250918-aarch64-apple-darwin-install_only"
    static var runtimeDir: String { supportDir + "/runtime" }
    static var runtimePython: String { runtimeDir + "/python/bin/python3" }
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
        serverPort = d.string(forKey: "translate.serverPort") ?? ""
        burnIn = (d.string(forKey: "translate.burnIn") ?? "1") == "1"
    }

    func persist(_ k: String, _ v: String) { d.set(v, forKey: "translate.\(k)") }

    var effectiveModelDir: String { modelDir.isEmpty ? ToolPaths.defaultModelDir : modelDir }
    var effectivePython: String { envPythonReady ? ToolPaths.envPython : "" }
    var envPythonReady: Bool { FileManager.default.isExecutableFile(atPath: ToolPaths.envPython) }
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
    static let mt = ModelSpec(key: "mt", msRepo: "mlx-community/Hy-MT2-7B", dirName: "Hy-MT2-7B",
                              label: "Hy-MT2-7B · 翻译大模型", sizeText: "≈15 GB")
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
    @Published var envOK = false
    @Published var envStage: String = ""
    @Published var envBusy = false
    @Published var serverRunning = false
    @Published var log: [String] = []

    private var process: Process?
    private var serverProcess: Process?
    /// 翻译服务随机端口（不固定、不在界面展示）。
    private(set) var runtimePort: UInt16 = 0

    private static func findFreePort() -> UInt16 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return 0 }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let ok = withUnsafeMutablePointer(to: &addr) { ptr -> Bool in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(fd, sa, len) == 0 && getsockname(fd, sa, &len) == 0
            }
        }
        guard ok else { return 0 }
        return UInt16(bigEndian: addr.sin_port)
    }
    private var stopRequested = false

    func checkEnv() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let ready = FileManager.default.isExecutableFile(atPath: ToolPaths.envPython)
            var pass = false
            if ready { pass = Shell.run(ToolPaths.envPython, ["-c", "import funasr, mlx_lm"]).0 == 0 }
            DispatchQueue.main.async { self?.envOK = pass }
        }
    }

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

    /// 一键构建环境（全自动，不碰系统 Python）：
    /// ① curl 下载独立 CPython 运行时（npmmirror 国内镜像，约 19MB）
    /// ② 基于它创建独立虚拟环境 ③ 清华镜像安装全部依赖（不含模型）
    func buildEnv(_ settings: TranslateSettings) {
        guard !envBusy else { return }
        envBusy = true
        appendLog("→ 开始构建转写环境（全自动）")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let fm = FileManager.default
            try? fm.createDirectory(atPath: ToolPaths.supportDir, withIntermediateDirectories: true)

            if !fm.fileExists(atPath: ToolPaths.runtimePython) {
                DispatchQueue.main.async { self?.envStage = "下载 Python 运行时…（npmmirror 国内镜像）" }
                let tar = ToolPaths.supportDir + "/runtime.tar.gz"
                let url = "https://registry.npmmirror.com/-/binary/python-build-standalone/20250918/cpython-3.11.13%2B20250918-aarch64-apple-darwin-install_only.tar.gz"
                let (rc, out) = Shell.run("/usr/bin/curl", ["-fL", "--retry", "3", "-o", tar, url])
                guard rc == 0 else {
                    DispatchQueue.main.async { self?.envBusy = false; self?.envStage = "✗ 运行时下载失败（检查网络）：\(out.prefix(100))" }
                    return
                }
                DispatchQueue.main.async { self?.envStage = "解压运行时…" }
                try? fm.removeItem(atPath: ToolPaths.runtimeDir)
                let (rcU, _) = Shell.run("/usr/bin/tar", ["-xzf", tar, "-C", ToolPaths.runtimeDir.replacingOccurrences(of: "/runtime", with: "")])
                guard rcU == 0, fm.fileExists(atPath: ToolPaths.runtimePython) else {
                    DispatchQueue.main.async { self?.envBusy = false; self?.envStage = "✗ 运行时解压失败" }
                    return
                }
                try? fm.removeItem(atPath: tar)
                self?.appendLog("✓ Python 运行时就绪（3.11 · Apple Silicon）")
            }

            DispatchQueue.main.async { self?.envStage = "创建独立虚拟环境…" }
            if !fm.fileExists(atPath: ToolPaths.envPython) {
                let (rc, out) = Shell.run(ToolPaths.runtimePython, ["-m", "venv", ToolPaths.envDir])
                guard rc == 0 else {
                    DispatchQueue.main.async { self?.envBusy = false; self?.envStage = "✗ 虚拟环境创建失败：\(out.prefix(100))" }
                    return
                }
            }

            let pkgs = ["funasr==1.4.1", "torch", "torchaudio", "mlx-lm", "openai",
                        "opencc-python-reimplemented", "soundfile", "python-multipart", "librosa"]
            var ok = true
            for pkg in pkgs {
                DispatchQueue.main.async { self?.envStage = "安装 \(pkg)…（torch 较大，共约 2GB，视网络 3–15 分钟）" }
                let (rc, out) = Shell.run(ToolPaths.envPython, ["-m", "pip", "install", "--no-input", "-q",
                         "--index-url", "https://pypi.tuna.tsinghua.edu.cn/simple", pkg])
                self?.appendLog(rc == 0 ? "✓ \(pkg)" : "✗ \(pkg)：\(out.suffix(160))")
                if rc != 0 { ok = false; break }
            }
            let (rcV, _) = Shell.run(ToolPaths.envPython, ["-c", "import funasr, torch, mlx_lm, openai, soundfile, opencc"])
            DispatchQueue.main.async {
                self?.envBusy = false
                if ok, rcV == 0 { self?.envOK = true; self?.envStage = ""; self?.appendLog("✓ 转写环境已就绪") }
                else { self?.envStage = "✗ 构建失败，见日志（可重试）" }
            }
        }
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

    /// 转写开始前自动确保翻译服务在线；模型/环境缺失则跳过并提示（不阻塞转写本身）。
    private func ensureServer(_ settings: TranslateSettings) {
        if serverRunning, serverProcess?.isRunning == true { return }
        let mtDir = modelDir(for: ModelCatalog.mt, settings)
        guard FileManager.default.fileExists(atPath: mtDir) else {
            appendLog("⚠ 未找到 Hy-MT2 翻译模型 → 本次仅转写不翻译（可在右侧下载）"); return
        }
        guard FileManager.default.isExecutableFile(atPath: ToolPaths.envPython) else {
            appendLog("⚠ 环境未构建 → 请先「一键构建环境」"); return
        }
        let port = TranslateModel.findFreePort()
        guard port > 0 else { appendLog("✗ 无可用端口"); return }
        runtimePort = port
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ToolPaths.envPython)
        p.arguments = ["-m", "mlx_lm.server", "--model", mtDir, "--port", String(port)]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (env["PATH"] ?? "")
        p.environment = env
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let chunk = String(data: h.availableData, encoding: .utf8) ?? ""
            for l in chunk.split(separator: "\n") where !l.isEmpty {
                DispatchQueue.main.async { self?.appendLog("[服务] \(l.prefix(120))") }
            }
        }
        do { try p.run() } catch { appendLog("✗ 翻译服务启动失败：\(error.localizedDescription)"); return }
        serverProcess = p
        appendLog("→ 翻译服务启动中（加载 Hy-MT2-7B，约 10–40 秒）…")
        // 轮询健康检查：/v1/models 返回 200 即就绪
        let base = "http://127.0.0.1:\(port)/v1/models"
        var ready = false
        for _ in 0..<60 {
            Thread.sleep(forTimeInterval: 2)
            let (rc, _) = Shell.run("/usr/bin/curl", ["-fsS", "-m", "3", base])
            if rc == 0 { ready = true; break }
            if p.isRunning == false { break }
        }
        if ready { serverRunning = true; appendLog("✓ 翻译服务就绪") }
        else { appendLog("✗ 翻译服务未能就绪（模型损坏或内存不足？）") }
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
        patch(task.id) { $0.status = "准备中"; $0.message = "自动拉起翻译服务…" }
        ensureServer(settings)
        patch(task.id) { $0.status = "转写中"; $0.message = "启动子进程（模型加载…跑完自动卸载）" }
        let stem = (task.videoPath as NSString).deletingPathExtension
        let outSrt = stem + ".srt"

        var env = ProcessInfo.processInfo.environment
        env["METRIBAR_MODEL_DIR"] = settings.effectiveModelDir
        env["METRIBAR_JSON_PROGRESS"] = "1"
        env["PYTHONUNBUFFERED"] = "1"
                let baseURL = serverRunning && runtimePort > 0 ? "http://127.0.0.1:\(runtimePort)/v1" : settings.translateBaseURL
        env["METRIBAR_TRANSLATE_BASE_URL"] = baseURL
        if !settings.translateAPIKey.isEmpty { env["METRIBAR_TRANSLATE_API_KEY"] = settings.translateAPIKey }
        if !settings.translateModel.isEmpty { env["METRIBAR_TRANSLATE_MODEL"] = settings.translateModel }
        env["PATH"] = "/opt/homebrew/bin:/opt/homebrew/opt/ffmpeg-full/bin:/usr/local/bin:/usr/bin:/bin:" + (env["PATH"] ?? "")

        guard settings.envPythonReady else {
            patch(task.id) { $0.status = "失败"; $0.message = "请先在右侧「一键构建环境」" }
            process = nil; finish(); return
        }
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

    func stopCurrent() { stopRequested = true; process?.terminate(); stopServer() }
    func remove(_ id: UUID) { if let i = tasks.firstIndex(where: { $0.id == id }), tasks[i].status != "转写中" { tasks.remove(at: i) } }
    func retry(_ id: UUID) {
        if let i = tasks.firstIndex(where: { $0.id == id }), tasks[i].status != "转写中" {
            tasks[i].status = "排队中"; tasks[i].percent = 0; runNext()
        }
    }
    private func finish() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let active = self.tasks.contains { $0.status == "转写中" || $0.status == "排队中" || $0.status == "准备中" }
            if !active { self.stopServer() }   // 队列跑完 → 自动停止服务、卸载翻译模型
            self.runNext()
        }
    }
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
        .onAppear { model.checkEnv(); model.refreshAvailability(settings) }
    }

    private var queueColumn: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button { pickFiles() } label: { Label("添加视频", systemImage: "plus") }
                Picker("模型", selection: $model.selectedModelKey) {
                    ForEach(ModelCatalog.asr) { Text($0.dirName).tag($0.key) }
                }.frame(width: 220).labelsHidden()
                Spacer()
                HStack(spacing: 5) {
                    Circle().fill(model.serverRunning ? Color.green : Color.secondary.opacity(0.4))
                        .frame(width: 7, height: 7)
                    Text(model.serverRunning ? "翻译服务运行中（自动）" : "翻译服务待机")
                        .font(.system(size: 10)).foregroundColor(.secondary)
                }
                .help("全自动：转写开始时自动拉起翻译服务，队列跑完自动停止并卸载模型")
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

    private func pickModelDir() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.prompt = "使用此目录"
        if panel.runModal() == .OK, let url = panel.url {
            settings.modelDir = url.path; settings.persist("modelDir", url.path)
            model.refreshAvailability(settings)
        }
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
                Image(systemName: model.envOK ? "checkmark.seal.fill" : (model.envBusy ? "gearshape.2.fill" : "seal"))
                    .foregroundColor(model.envOK ? .green : model.envBusy ? .accentColor : .secondary)
                Text(model.envBusy ? (model.envStage.isEmpty ? "正在构建环境…" : model.envStage)
                                   : (model.envOK ? "转写环境已就绪" : "点右侧按钮一键构建（首次约 3–15 分钟）"))
                    .font(.system(size: 10)).foregroundColor(.secondary).lineLimit(2)
                Spacer()
                if !model.envBusy {
                    Button(model.envOK ? "重建" : "一键构建环境") { model.buildEnv(settings) }.controlSize(.small)
                        .help("基于 App 内置 Python 创建独立环境，经清华镜像安装 funasr/torch/mlx-lm（不含模型）")
                }
            }
            Divider()
            Label("模型 · ModelScope 魔搭", systemImage: "arrow.down.circle.fill").font(.system(size: 13, weight: .bold))
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(model.downloads) { dl in downloadRow(dl) }
                }
            }
            HStack(spacing: 8) {
                Button("全部下载缺失") { model.downloadAllMissing(settings) }.controlSize(.small)
                Spacer()
            }
            HStack(spacing: 6) {
                Image(systemName: "folder").foregroundColor(.secondary)
                Text(settings.effectiveModelDir).font(.system(size: 9, design: .monospaced)).foregroundColor(.secondary).lineLimit(1).textSelection(.enabled)
                Spacer()
                Button("更改目录") { pickModelDir() }.controlSize(.mini)
                    .help("指向已有的模型文件夹（内含 SenseVoiceSmall / Fun-ASR-Nano-2512 等子目录），不必重新下载")
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.04)))
            Spacer()
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
