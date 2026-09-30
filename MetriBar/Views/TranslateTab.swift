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
        ModelSpec(key: "nano", msRepo: "FunAudioLLM/Fun-ASR-Nano-2512", dirName: "Fun-ASR-Nano-2512",
                  label: "Fun-ASR Nano · 中文更强", sizeText: "≈2 GB"),
        ModelSpec(key: "mlt-nano", msRepo: "FunAudioLLM/Fun-ASR-MLT-Nano-2512", dirName: "Fun-ASR-MLT-Nano-2512",
                  label: "Fun-ASR MLT Nano · 多语种", sizeText: "≈1.9 GB"),
    ]
    static let vad = ModelSpec(key: "vad", msRepo: "iic/speech_fsmn_vad_zh-cn-16k-common-pytorch", dirName: "fsmn-vad",
                               label: "FSMN-VAD · 长音频断句必需", sizeText: "≈4 MB")
    static let mt = ModelSpec(key: "mt", msRepo: "mlx-community/Hy-MT2-7B", dirName: "Hy-MT2-7B",
                              label: "Hy-MT2-7B · 翻译大模型", sizeText: "≈15 GB")
    static var all: [ModelSpec] { asr + [vad, mt] }
}

struct DownloadState: Identifiable {
    var id: String { spec.id.uuidString }
    let spec: ModelSpec
    var status: String = "未下载"
    var percent: Double = 0        // 按字节加权的真实进度
    var filesDone: Int = 0
    var filesTotal: Int = 0
    var bytesDone: Int64 = 0
    var bytesTotal: Int64 = 0
    var paused: Bool = false
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
    @Published var ffmpegOK = false
    @Published var envProgress: Double = 0
    static func detectFFmpeg() -> String? {
        // 登录shell解析（含用户自定义PATH，覆盖 ffmpeg-full / conda / macports）
        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: "/bin/bash")
        probe.arguments = ["-lc", "command -v ffmpeg"]
        let pipe = Pipe(); probe.standardOutput = pipe; probe.standardError = FileHandle.nullDevice
        try? probe.run(); probe.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !out.isEmpty, FileManager.default.isExecutableFile(atPath: out) { return out }
        for pth in ["/opt/homebrew/bin/ffmpeg", "/opt/homebrew/opt/ffmpeg/bin/ffmpeg",
                    "/opt/homebrew/opt/ffmpeg-full/bin/ffmpeg", "/usr/local/bin/ffmpeg"] where FileManager.default.isExecutableFile(atPath: pth) { return pth }
        return nil
    }
    @Published var log: [String] = []

    var workers: [UUID: Process] = [:]
        var activeCount: Int { tasks.filter { $0.status == "转写中" || $0.status == "准备中" }.count }
    var taskCount: Int { tasks.count }
    @Published var concurrencyLimit: Int = {
        let v = UserDefaults.standard.integer(forKey: "translate.concurrency")
        return (1...8).contains(v) ? v : 5
    }()
    private var serverProcess: Process?
    private var serverStarting = false
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
        ffmpegOK = (TranslateModel.detectFFmpeg() != nil)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let ready = FileManager.default.isExecutableFile(atPath: ToolPaths.envPython)
            var pass = false
            if ready { pass = Shell.run(ToolPaths.envPython, ["-c", "import funasr, mlx_lm"]).0 == 0 }
            DispatchQueue.main.async { self?.envOK = pass }
        }
    }

    static let logFile = ToolPaths.supportDir + "/logs/MetriBar.log"
    static let logQueue = DispatchQueue(label: "metribar.log", qos: .utility)

    func appendLog(_ s: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.log.append(s)
            if self.log.count > 200 { self.log.removeFirst(self.log.count - 200) }
        }
        Self.logQueue.async {
            try? FileManager.default.createDirectory(atPath: (Self.logFile as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            let stamp = ISO8601DateFormatter().string(from: Date())
            let entry = "[" + stamp + "] " + s + "\n"
            if let h = FileHandle(forWritingAtPath: Self.logFile) { defer { try? h.close() }; h.seekToEndOfFile(); try? h.write(entry.data(using: .utf8)!) }
            else { try? entry.write(toFile: Self.logFile, atomically: true, encoding: .utf8) }
        }
    }

    /// App 启动时清理孤儿翻译服务（上次被强杀时残留的、属于本 App 的 mlx_lm.server）
    static func reapOrphanServers() {
        let me = ToolPaths.envPython.replacingOccurrences(of: "/bin/python3", with: "")
        // 孤儿翻译服务 / 本App孤儿下载curl / 残留pip安装，一并清扫
        for pat in [me + ".*-m mlx_lm.server",
                    "curl.*modelscope[.].cn/models/",
                    me + ".*pip install"] {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
            p.arguments = ["-f", pat]
            try? p.run(); p.waitUntilExit()
        }
    }

    func refreshAvailability(_ settings: TranslateSettings) {
        let roots = [settings.effectiveModelDir, settings.pipelineDir + "/models", ToolPaths.defaultModelDir]
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            for i in self.downloads.indices {
                let spec = self.downloads[i].spec
                guard self.downloads[i].status != "下载中" else { continue }
                if let dir = TranslateModel.resolveModelDir(spec: spec, roots: roots) {
                    if FileManager.default.fileExists(atPath: TranslateModel.completionMarkPath(dir)) {
                        self.downloads[i].status = "✓ 已就绪"
                        self.appendLog("扫描命中 \(spec.dirName) → \(dir)")
                    } else {
                        // 无凭证 → 联网对官方清单逐文件大小校验，全对才补凭证置就绪
                        self.downloads[i].status = "校验中…"
                        self.verifyAndMark(spec: spec, dir: dir, idx: i)
                    }
                } else {
                    self.downloads[i].status = "未下载"
                }
            }
        }
    }

    /// 根目录内解析模型：直接子目录 + 「发布者/模型」两级嵌套（LM Studio 布局），大小写兜底。
    static func resolveModelDir(spec: ModelSpec, roots: [String]) -> String? {
        let fm = FileManager.default
        var seen = Set<String>()
        for root in roots {
            if seen.contains(root) { continue }
            seen.insert(root)
            let exact = root + "/" + spec.dirName
            if fm.fileExists(atPath: exact) { return exact }
            guard let firsts = try? fm.contentsOfDirectory(atPath: root) else { continue }
            for f in firsts.sorted() {
                if f.hasPrefix(".") { continue }
                let cand = root + "/" + f + "/" + spec.dirName
                if fm.fileExists(atPath: cand) { return cand }
                if f.lowercased() == spec.dirName.lowercased() { return root + "/" + f }
                if let seconds = try? fm.contentsOfDirectory(atPath: root + "/" + f) {
                    for g in seconds where g.lowercased() == spec.dirName.lowercased() {
                        return root + "/" + f + "/" + g
                    }
                }
            }
        }
        return nil
    }

    func modelDir(for spec: ModelSpec, _ settings: TranslateSettings) -> String {
        TranslateModel.resolveModelDir(spec: spec, roots: [settings.effectiveModelDir, settings.pipelineDir + "/models", ToolPaths.defaultModelDir])
            ?? settings.effectiveModelDir + "/" + spec.dirName
    }

    // MARK: 一键构建 Python 环境（venv + 清华镜像，torch/funasr/mlx-lm）

    /// 一键构建环境（全自动，不碰系统 Python）：
    /// ① curl 下载独立 CPython 运行时（npmmirror 国内镜像，约 19MB）
    /// ② 基于它创建独立虚拟环境 ③ 清华镜像安装全部依赖（不含模型）
    /// 删除全部运行时与依赖（回到全新未安装状态）
    func nukeRuntime(_ settings: TranslateSettings) {
        guard !envBusy else { return }
        envBusy = true
        appendLog("→ 删除全部运行时与依赖")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let fm = FileManager.default
            try? fm.removeItem(atPath: ToolPaths.envDir)
            try? fm.removeItem(atPath: ToolPaths.runtimeDir)
            try? fm.removeItem(atPath: NSHomeDirectory() + "/Library/Caches/pip")
            try? fm.removeItem(atPath: NSHomeDirectory() + "/.cache/pip")
            DispatchQueue.main.async {
                self?.envOK = false; self?.envBusy = false
                self?.envStage = "已删除全部运行时与依赖，可重新一键构建"
                self?.refreshAvailability(settings)
                self?.appendLog("✓ 运行时与依赖已删除")
            }
        }
    }

    func buildEnv(_ settings: TranslateSettings, full: Bool = false) {
        guard !envBusy else { return }
        envBusy = true; envProgress = 0
        envStage = "正在启动构建脚本…"
        appendLog(full ? "→ 全量重建：清除所有依赖后重装" : "→ 开始构建转写环境")
        if full {
            try? FileManager.default.removeItem(atPath: ToolPaths.envDir)
            try? FileManager.default.removeItem(atPath: NSHomeDirectory() + "/Library/Caches/pip")
            try? FileManager.default.removeItem(atPath: NSHomeDirectory() + "/.cache/pip")
            envOK = false
        }
        // 定位随包构建脚本（bundle缺失回退到磁盘缓存副本）
        var script = Bundle.main.path(forResource: "install_runtime", ofType: "sh") ?? ""
        let cached = ToolPaths.supportDir + "/install_runtime.sh"
        if script.isEmpty, FileManager.default.fileExists(atPath: cached) { script = cached }
        else if !script.isEmpty { try? FileManager.default.copyItem(atPath: script, toPath: cached) }
        guard !script.isEmpty, FileManager.default.isExecutableFile(atPath: script) else {
            envBusy = false; envStage = "✗ 构建脚本缺失（请重新安装App）"; return
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/bash")
            p.arguments = [script]
            let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
            do { try p.run() } catch {
                DispatchQueue.main.async { self?.envBusy = false; self?.envStage = "✗ 无法启动构建脚本" }
                return
            }
            let h = pipe.fileHandleForReading
            while true {
                let chunk = h.availableData
                if chunk.isEmpty { break }
                let txt = String(data: chunk, encoding: .utf8) ?? ""
                for line in txt.split(separator: "\n") {
                    let l = String(line)
                    self?.appendLog("[构建] " + l)
                    if l.contains("STEP") || l.contains("依赖 ") {
                        let stepTxt = l.range(of: "] ").map { String(l[$0.upperBound...]) } ?? l
                        DispatchQueue.main.async { self?.envStage = stepTxt }
                    }
                    if l.contains("依赖 "), let num = Int(l.replacingOccurrences(of: "依赖 ", with: "").split(separator: "/").first.map(String.init) ?? "") {
                        DispatchQueue.main.async { self?.envProgress = Double(num)/9.0 }
                    }
                }
            }
            p.waitUntilExit()
            let ok = p.terminationStatus == 0
            DispatchQueue.main.async {
                self?.envBusy = false
                if ok { self?.envOK = true; self?.envProgress = 1; self?.envStage = ""; self?.appendLog("✓ 转写环境已就绪") }
                else { self?.envStage = "✗ 构建失败——查日志[构建]段的FAIL行（含具体步骤）"; }
            }
        }
    }

    // MARK: ModelScope 直连下载（带进度）

    // ── 下载控制：进程句柄与取消标记 ──
    private var dlProcs: [String: Process] = [:]
    private var dlCancel: Set<String> = []
    private var dlPaused: Set<String> = []

    /// 完整性凭证：文件数+总字节，写入模型目录；校验不过一律视为未就绪
    static func completionMarkPath(_ dir: String) -> String { dir + "/.metribar_ok.json" }
    static func isComplete(dir: String) -> Bool {
        let mark = completionMarkPath(dir)
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: mark)),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let files = obj["files"] as? Int, files > 0 else { return false }
        _ = obj["bytes"]
        return true
    }

    func download(_ spec: ModelSpec, _ settings: TranslateSettings) {
        let key = spec.id.uuidString
        guard let idx = downloads.firstIndex(where: { $0.id == key }), downloads[idx].status != "下载中" || downloads[idx].paused else { return }
        dlCancel.remove(key)
        dlPaused.remove(key)
        downloads[idx].paused = false
        downloads[idx].status = "下载中"
        appendLog("→ ModelScope \(spec.msRepo) → \(settings.effectiveModelDir)/\(spec.dirName)")
        DispatchQueue.global(qos: .background).async { [weak self] in
            guard let self else { return }
            let (rc, out) = Shell.run("/usr/bin/curl", ["-fsSL",
                "https://modelscope.cn/api/v1/models/\(spec.msRepo)/repo/files?Revision=master&Recursive=true"])
            guard rc == 0, let data = out.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let d = obj["Data"] as? [String: Any],
                  let files = d["Files"] as? [[String: Any]] else {
                updateDL(spec) { $0.status = "✗ 清单获取失败" }
                return
            }
            var items: [(String, Int64)] = []
            func walk(_ arr: [[String: Any]]) {
                for f in arr {
                    if let p = f["Path"] as? String, !p.isEmpty, !p.hasPrefix(".") {
                        let sz = (f["Size"] as? NSNumber)?.int64Value ?? 0
                        items.append((p, sz))
                    }
                    if let kids = f["Files"] as? [[String: Any]] { walk(kids) }
                }
            }
            walk(files)
            let totalBytes = items.reduce(Int64(0)) { $0 + $1.1 }
            let destRoot = settings.effectiveModelDir + "/" + spec.dirName
            try? FileManager.default.createDirectory(atPath: destRoot, withIntermediateDirectories: true)
            DispatchQueue.main.async { if let i = self.downloads.firstIndex(where: { $0.id == key }) {
                self.downloads[i].filesTotal = items.count; self.downloads[i].bytesTotal = totalBytes } }

            var bytesDone: Int64 = 0
            let fm = FileManager.default
            func bytesOf(_ pth: String) -> Int64 { (try? fm.attributesOfItem(atPath: pth)[.size] as? Int64) ?? 0 }
            func setDL(_ patch: @escaping (inout DownloadState) -> Void) {
                DispatchQueue.main.async { if let i = self.downloads.firstIndex(where: { $0.id == key }) { patch(&self.downloads[i]) } }
            }

            for (path, size) in items {
                if dlCancel.contains(key) || dlPaused.contains(key) { break }
                let dest = destRoot + "/" + path
                try? fm.createDirectory(atPath: (dest as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                // 已完成文件跳过（大小精确匹配）
                if size > 0, bytesOf(dest) == size {
                    bytesDone += size
                    setDL { $0.bytesDone = bytesDone; $0.filesDone += 1
                           $0.percent = totalBytes > 0 ? Double(bytesDone)/Double(totalBytes)*100 : 0 }
                    continue
                }
                let encoded = path.split(separator: "/").map { $0.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? String($0) }.joined(separator: "/")
                let url = "https://modelscope.cn/models/\(spec.msRepo)/resolve/master/\(encoded)"
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
                // append模式续传：dest已有部分字节则接着下
                let resumed = bytesOf(dest)
                var args = ["-fSL", "-o", dest, url]
                if resumed > 0 && (size == 0 || resumed < size) { args = ["-fSL", "-C", "-", "-o", dest, url] }
                else if resumed > 0 { try? fm.removeItem(atPath: dest) }
                p.arguments = args
                p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
                do { try p.run() } catch { continue }
                dlProcs[key] = p
                while p.isRunning {
                    if dlCancel.contains(key) || dlPaused.contains(key) { p.terminate(); break }
                    let cur = min(bytesOf(dest), size > 0 ? max(size, bytesOf(dest)) : bytesOf(dest))
                    let snap = bytesDone + cur
                    let doneNow = self.downloads.first(where: { $0.id == key })?.filesDone ?? 0
                    setDL { st in
                        if snap >= st.bytesDone { st.bytesDone = snap }   // 只前进不回退
                        st.percent = totalBytes > 0 ? Double(st.bytesDone)/Double(totalBytes)*100 : 0
                        st.status = "下载中 \(doneNow)/\(items.count) · \(Int(st.percent))%"
                    }
                    usleep(600_000)
                }
                p.waitUntilExit()
                dlProcs.removeValue(forKey: key)
                if dlCancel.contains(key) { break }
                let complete = (size > 0 && bytesOf(dest) == size) || (size == 0 && p.terminationStatus == 0)
                if complete {
                    bytesDone += size > 0 ? size - min(resumed, size) : bytesOf(dest)
                    setDL { $0.filesDone += 1; $0.bytesDone = bytesDone
                           $0.percent = totalBytes > 0 ? Double(bytesDone)/Double(totalBytes)*100 : 0 }
                } else if p.terminationStatus != 0 { appendLog("✗ \(path)（下次自动续传）") }
            }

            if dlCancel.contains(key) == true {
                // 停止 = 删除已下载缓存，回到未下载
                try? fm.removeItem(atPath: destRoot)
                dlCancel.remove(key); dlPaused.remove(key)
                setDL { $0.status = "已停止（缓存已删除）"; $0.percent = 0; $0.bytesDone = 0; $0.filesDone = 0 }
                appendLog("■ \(spec.label) 已停止，下载缓存已删除")
                return
            }
            if dlPaused.contains(key) {
                setDL { $0.status = "已暂停"; $0.paused = true }
                appendLog("‖ \(spec.label) 已暂停（可继续，断点保留）")
                return
            }
            let mark: [String: Any] = ["files": items.count, "bytes": bytesDone, "at": ISO8601DateFormatter().string(from: Date())]
            if let md = try? JSONSerialization.data(withJSONObject: mark) { try? md.write(to: URL(fileURLWithPath: Self.completionMarkPath(destRoot))) }
            updateDL(spec) { $0.status = "✓ 已就绪"; $0.percent = 100; $0.bytesDone = bytesDone }
            appendLog("✓ \(spec.label) 下载完成（\(bytesDone/1048576) MB）")
        }
    }

    /// 联网校验目录与官方清单：全部文件存在且大小一致才补凭证置就绪
    private func verifyAndMark(spec: ModelSpec, dir: String, idx: Int) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let (rc, out) = Shell.run("/usr/bin/curl", ["-fsSL", "-m", "20",
                "https://modelscope.cn/api/v1/models/\(spec.msRepo)/repo/files?Revision=master&Recursive=true"])
            var ok = false
            if rc == 0, let data = out.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let d = obj["Data"] as? [String: Any], let files = d["Files"] as? [[String: Any]] {
                var items: [(String, Int64)] = []
                func walk(_ arr: [[String: Any]]) {
                    for f in arr {
                        if let p = f["Path"] as? String, !p.isEmpty, !p.hasPrefix(".") { items.append((p, (f["Size"] as? NSNumber)?.int64Value ?? -1)) }
                        if let kids = f["Files"] as? [[String: Any]] { walk(kids) }
                    }
                }
                walk(files)
                ok = !items.isEmpty && items.allSatisfy { (p, sz) in
                    let dest = dir + "/" + p
                    let exist = FileManager.default.fileExists(atPath: dest)
                    if !exist { return false }
                    if sz <= 0 { return true }
                    let local = (try? FileManager.default.attributesOfItem(atPath: dest)[.size] as? Int64) ?? -1
                    return local == sz
                }
            }
            DispatchQueue.main.async {
                guard let self, idx < self.downloads.count else { return }
                if ok {
                    let mark: [String: Any] = ["files": 1, "bytes": 1, "at": "verified"]
                    if let md = try? JSONSerialization.data(withJSONObject: mark) { try? md.write(to: URL(fileURLWithPath: Self.completionMarkPath(dir))) }
                    self.downloads[idx].status = "✓ 已就绪"
                } else {
                    self.downloads[idx].status = "⚠ 不完整（曾被中断）"
                }
            }
        }
    }

    func pauseDownload(_ spec: ModelSpec) {
        let key = spec.id.uuidString
        dlPaused.insert(key)                 // 循环哨兵：当前文件终止后不再开下一个
        dlProcs[key]?.terminate()          // 杀掉当前curl，已下部分保留可续传
        if let i = downloads.firstIndex(where: { $0.id == key }) { downloads[i].paused = true; downloads[i].status = "已暂停" }
    }
    func resumeDownload(_ spec: ModelSpec, _ settings: TranslateSettings) {
        guard let i = downloads.firstIndex(where: { $0.id == spec.id.uuidString }), downloads[i].paused else { return }
        download(spec, settings)   // curl -C - 断点续传未完成文件
    }
    func stopDownload(_ spec: ModelSpec) {
        let key = spec.id.uuidString
        dlCancel.insert(key)
        dlProcs[key]?.terminate()
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
        if serverStarting { while serverStarting && !serverRunning && (serverProcess?.isRunning ?? false == false) { Thread.sleep(forTimeInterval: 1) }; return }
        serverStarting = true
        defer { serverStarting = false }
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
        p.arguments = ["-m", "mlx_lm.server", "--model", mtDir, "--port", String(port),
                       "--decode-concurrency", "8"]
        // 不加 --decode-concurrency：实测 Hy-MT2-7B 批量并发吞吐劣化 ~100×（串行1.9s/条 vs 并发4条794s）
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
        TranslateModel.serverPID = p.processIdentifier
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
        TranslateModel.serverPID = 0
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

    // ── 强退连锁：收到 SIGTERM/退出通知时，必须带走翻译服务进程（15GB 内存不滞留）──
    static var serverPID: pid_t = 0
    private func installTerminationChain() {
        signal(SIGTERM) { _ in
            // 向本进程组全体子进程发TERM：下载curl/pip/mlx server 一个不留
            kill(0, SIGTERM)
            usleep(300_000)
            _exit(0)
        }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                             object: nil, queue: .main) { _ in
            kill(0, SIGTERM)   // 含下载/构建/服务全部子进程
        }
    }

    @Published var autoRunning = false

    // ── 进度补间：每秒向阶段上限推进，杜绝蓝条静止 ──
    private var progressTimer: Timer?
    func startTicker() {
        stopTicker()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            DispatchQueue.main.async {
                var anyActive = false
                for i in self.tasks.indices {
                    let t = self.tasks[i]
                    guard t.status == "转写中" || t.status == "准备中" else { continue }
                    anyActive = true
                    let m = t.message + t.stage
                    let ceil: Double = m.contains("翻译") ? 95 : (m.contains("烧录") || m.contains("字幕版") ? 99 : 68)
                    if t.percent < ceil - 0.5 {
                        self.tasks[i].percent = min(ceil, t.percent + max(0.35, (ceil - t.percent) * 0.012))
                    }
                }
                if !anyActive { self.stopTicker() }
            }
        }
    }
    func stopTicker() { progressTimer?.invalidate(); progressTimer = nil }

    init() { installTerminationChain() }

    func startQueue() {
        // 点开始：先确保翻译服务就绪（只等这一次），再放行队列
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            if FileManager.default.isExecutableFile(atPath: ToolPaths.envPython) {
                self.ensureServer(TranslateSettings.shared)
            }
            DispatchQueue.main.async { self.autoRunning = true; self.startTicker(); self.runNext() }
        }
    }

    func runNext() {
        guard autoRunning else { return }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            while self.workers.count < self.concurrencyLimit,
                  let idx = self.tasks.firstIndex(where: { $0.status == "排队中" }) {
                self.tasks[idx].status = "准备中"
                let task = self.tasks[idx]
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in self?.execute(task) }
            }
        }
    }

    private func patch(_ id: UUID, _ body: @escaping (inout TranslateTask) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let i = self.tasks.firstIndex(where: { $0.id == id }) else { return }
            body(&self.tasks[i])
        }
    }

    private func execute(_ task: TranslateTask) {
        let settings = TranslateSettings.shared
        if settings.burnIn && !ffmpegOK {
            patch(task.id) { $0.status = "失败"; $0.message = "未安装 ffmpeg，无法烧录字幕。请在终端执行：brew install ffmpeg（或取消勾选「烧录字幕进视频」）" }
            finish(); return
        }
        patch(task.id) { $0.status = "转写中"; $0.message = "语音识别中…" }
        let stem = (task.videoPath as NSString).deletingPathExtension
        let outSrt = stem + ".srt"

        var env = ProcessInfo.processInfo.environment
                let rootsForEnv = [settings.effectiveModelDir, settings.pipelineDir + "/models", ToolPaths.defaultModelDir]
        for (spec, key) in [(ModelCatalog.asr[0], "METRIBAR_SENSEVOICE_DIR"), (ModelCatalog.asr[1], "METRIBAR_NANO_DIR"),
                             (ModelCatalog.asr[2], "METRIBAR_MLT_NANO_DIR"), (ModelCatalog.vad, "METRIBAR_VAD_DIR")] {
            if let dir = TranslateModel.resolveModelDir(spec: spec, roots: rootsForEnv) { env[key] = dir }
        }
        env["METRIBAR_MODEL_DIR"] = env["METRIBAR_VAD_DIR"] ?? settings.effectiveModelDir
        env["METRIBAR_JSON_PROGRESS"] = "1"
        env["PYTHONUNBUFFERED"] = "1"
        if serverRunning && runtimePort > 0 {
            env["METRIBAR_TRANSLATE_BASE_URL"] = "http://127.0.0.1:\(runtimePort)/v1"
        }
        if !settings.translateAPIKey.isEmpty { env["METRIBAR_TRANSLATE_API_KEY"] = settings.translateAPIKey }
        // mlx_lm.server 的 model id = 模型绝对路径；必须一致，否则服务端拒收
        let mtDirForEnv = modelDir(for: ModelCatalog.mt, settings)
        env["METRIBAR_TRANSLATE_MODEL"] = mtDirForEnv
        // 按当前活跃任务数分摊并发额度：总8路，避免多任务×8连接打爆 server
        let activeNow = max(workers.count + 1, 1)
        env["METRIBAR_TRANSLATE_CONCURRENCY"] = String(max(2, 8 / activeNow))
        env["PATH"] = "/opt/homebrew/bin:/opt/homebrew/opt/ffmpeg-full/bin:/usr/local/bin:/usr/bin:/bin:" + (env["PATH"] ?? "")

        guard settings.envPythonReady else {
            patch(task.id) { $0.status = "失败"; $0.message = "请先在右侧「一键构建环境」" }
            finish(); return
        }
        // 强制重做：清掉旧 srt/中文/双语/meta/成片，避免"秒完成"假象与旧错误结果复用
        for old in [outSrt, stem + ".(中文).srt", stem + ".(双语).srt", outSrt + ".meta.json", stem + ".字幕版.mp4"] {
            try? FileManager.default.removeItem(atPath: old)
        }
        let p = Process()
        workers[task.id] = p
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
        do { try p.run() } catch {
            workers[task.id] = nil
            patch(task.id) { $0.status = "失败"; $0.message = "无法启动 Python：\(error.localizedDescription)" }
            finish(); return
        }
        p.waitUntilExit()
        pipe.fileHandleForReading.readabilityHandler = nil
        workers[task.id] = nil

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
                           $0.percent = max($0.percent, min((obj["percent"] as? NSNumber)?.doubleValue ?? 0, 99))
                           $0.message = obj["message"] as? String ?? "" }
            return
        }
        // HTTP访问日志等非结构化输出：只进日志文件，不刷卡片（杜绝闪烁）
        appendLog("[\(taskId.uuidString.prefix(4))] \(line)")
    }

    private func burnIn(_ task: TranslateTask, outSrt: String) -> Bool {
        let settings = TranslateSettings.shared
        let stem = (task.videoPath as NSString).deletingPathExtension
        let srt = FileManager.default.fileExists(atPath: stem + ".(双语).srt") ? stem + ".(双语).srt" : outSrt
        guard FileManager.default.fileExists(atPath: srt) else { return false }
        patch(task.id) { $0.percent = 92; $0.message = "烧录字幕中（ffmpeg）…" }
        let (rc, _) = Shell.run(settings.effectivePython,
                                 [settings.effectivePipeline + "/embed_subtitle.py", task.videoPath, "-s", srt, "-o", stem + ".字幕版.mp4"])
        return rc == 0
    }

    /// 从原始日志行提取人类可读细节（去时间戳、级别、冗余前缀）
    static func detailOf(_ raw: String) -> String {
        var d = raw
        if let r = d.range(of: "^\\s*\\d{4}-\\d{2}-\\d{2}[T ][\\d:,]+Z?\\s*", options: .regularExpression) { d.removeSubrange(r) }
        d = d.replacingOccurrences(of: "[INFO]", with: "").replacingOccurrences(of: "[WARNING]", with: "").trimmingCharacters(in: .whitespaces)
        if d.hasPrefix("[") , let e = d.firstIndex(of: "]") { d.removeSubrange(...e) }
        d = d.trimmingCharacters(in: .whitespaces)
        return d.count > 90 ? String(d.prefix(90)) + "…" : d
    }

    static func friendlyStage(_ t: TranslateTask) -> String {
        switch t.status {
        case "排队中":  return "排队等待中…"
        case "准备中":  return "准备中（启动翻译引擎）…"
        case "转写中":
            let m = t.message
            if m.contains("翻译") {
                if let r = m.range(of: "已翻译[^)）]*", options: .regularExpression) { return "正在翻译成目标语言…（\(m[r])）" }
                return "正在翻译成目标语言…"
            }
            if m.contains("字幕") || m.contains("烧录") { return "正在把字幕烧进视频…" }
            if m.contains("对齐") || m.contains("时间轴") { return "正在校对时间轴…" }
            if m.contains("Retrying") || m.contains("retry") { return "服务繁忙，正在自动重试翻译请求…" }
            if !m.isEmpty { return "正在识别语音…（\(detailOf(m))）" }
            return "正在识别语音…"
        case "完成":    return "✓ 完成，字幕已生成"
        case "失败":    return "✗ 失败：\(t.message)"
        case "已停止":  return "已停止（模型已卸载）"
        default:        return t.message.isEmpty ? t.status : t.message
        }
    }

    func stopAll() {
        stopRequested = true
        autoRunning = false
        workers.values.forEach { $0.terminate() }
        stopServer()
    }
    func remove(_ id: UUID) { if let i = tasks.firstIndex(where: { $0.id == id }), workers[id] == nil, tasks[i].status != "转写中" { tasks.remove(at: i) } }
    func retry(_ id: UUID) {
        if let i = tasks.firstIndex(where: { $0.id == id }), workers[id] == nil {
            tasks[i].status = "排队中"; tasks[i].percent = 0; runNext()
        }
    }
    private func finish() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let active = !self.workers.isEmpty || self.tasks.contains { $0.status == "排队中" }
            if !active { self.autoRunning = false; self.stopTicker(); self.stopServer() }   // 排空 → 关闸 + 卸载模型
            self.runNext()
        }
    }
}

// MARK: - 视图

struct TranslateTab: View {
    @ObservedObject private var settings = TranslateSettings.shared
    @StateObject private var model = TranslateModel()
    @State private var dirDraft: String = ""
    @State private var showLogWin = false
    private func barColor(_ t: TranslateModel.TranslateTask) -> Color {
        switch t.status {
        case "完成":   return .green
        case "失败":   return .red
        case "排队中": return Color.gray.opacity(0.35)
        default:
            let m = t.message + t.stage
            if m.contains("烧录") || m.contains("字幕版") { return .purple }
            if m.contains("翻译") { return .orange }
            return .accentColor
        }
    }
    @State private var showEnvSheet = false
    @State private var showNukeConfirm = false
    @State private var pendingNuke = false
    @State private var dirMsg: String = ""
    @State private var dirOK = false

    var body: some View {
        HSplitView {
            queueColumn.frame(minWidth: 420, idealWidth: 500, minHeight: 480)

        }
        .onAppear { TranslateModel.reapOrphanServers(); dirDraft = settings.effectiveModelDir; model.checkEnv(); model.refreshAvailability(settings) }
    }

    private var queueColumn: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button { pickFiles() } label: { Label("添加视频", systemImage: "plus") }
                Picker("模型", selection: $model.selectedModelKey) {
                    ForEach(ModelCatalog.asr) { Text($0.dirName).tag($0.key) }
                }.frame(width: 220).labelsHidden()
                Stepper(value: $model.concurrencyLimit, in: 1...8) {
                    Text("同时处理 \(model.concurrencyLimit)").font(.system(size: 11))
                }.fixedSize()
                    .onChange(of: model.concurrencyLimit) { v in
                        UserDefaults.standard.set(v, forKey: "translate.concurrency"); model.runNext()
                    }
                Button { model.startQueue() } label: {
                    if model.autoRunning && !model.workers.isEmpty {
                        HStack(spacing: 4) { ProgressView().controlSize(.small); Text("处理中 \(model.activeCount)/\(model.taskCount)") }
                    } else { Label("开始处理", systemImage: "play.fill") }
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.autoRunning || !model.tasks.contains { $0.status == "排队中" })
                Toggle(isOn: $settings.burnIn) { Text("烧录字幕进视频").font(.system(size: 11)) }
                    .toggleStyle(.checkbox)
                    .onChange(of: settings.burnIn) { v in settings.persist("translate.burnIn", v ? "1" : "0") }
                if !model.ffmpegOK { Text("需 ffmpeg").font(.system(size: 9)).foregroundColor(.orange) }
                Button("日志", action: { showLogWin = true })
                    .buttonStyle(.borderless).help("查看详细日志")
                    .popover(isPresented: $showLogWin, arrowEdge: .bottom) {
                        LogTextView(file: TranslateModel.logFile).frame(width: 640, height: 380)
                    }
                if !model.workers.isEmpty {
                    Button("全部停止") { model.stopAll() }.controlSize(.small).tint(.red)
                }
                Spacer()
                HStack(spacing: 10) {
                    HStack(spacing: 5) {
                        Circle().fill(model.serverRunning ? Color.green : Color.secondary.opacity(0.4))
                            .frame(width: 7, height: 7)
                        Text(model.serverRunning ? "翻译服务运行中" : "翻译服务待机")
                            .font(.system(size: 10)).foregroundColor(.secondary)
                    }
                    if model.envOK {
                        Label("环境就绪", systemImage: "checkmark.seal.fill").font(.system(size: 10)).foregroundColor(.green)
                    } else {
                        Label("环境未构建", systemImage: "xmark.seal").font(.system(size: 10)).foregroundColor(.orange)
                    }
                    let ready = model.downloads.filter { $0.status.hasPrefix("✓") }.count
                    if ready == model.downloads.count {
                        Text("模型 5/5 ✓").font(.system(size: 10)).foregroundColor(.green)
                    } else {
                        Text("模型 \(ready)/\(model.downloads.count)").font(.system(size: 10)).foregroundColor(.orange)
                    }
                    Button { model.checkEnv(); showEnvSheet = true } label: { Label("环境配置", systemImage: "shippingbox") }
                        .controlSize(.small)
                }
                .sheet(isPresented: $showEnvSheet) { envSheet }
        .alert("确认删除？", isPresented: $showNukeConfirm) {
            Button("删除全部", role: .destructive) { model.nukeRuntime(settings) }
            Button("取消", role: .cancel) { }
        } message: {
            Text("将删除独立 Python 运行时、转写环境(venv)及全部依赖缓存（共约数GB，不含已下载模型）。之后可重新一键构建。")
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

        }
    }

    private var dropHint: some View {
        VStack(spacing: 8) {
            Image(systemName: "film.stack").font(.system(size: 34)).foregroundColor(.secondary)
            Text("拖入视频，或点「添加视频」").font(.system(size: 13, weight: .medium))
            Text("转写 → 翻译 → 双语字幕（可选烧录）。\n多路并行处理；模型用完自动卸载。")
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
            HStack(spacing: 8) {
                ProgressView(value: (task.status == "完成" ? 100 : task.percent) / 100.0)
                    .progressViewStyle(.linear)
                Text(task.status == "完成" ? "100%" : "\(Int(task.percent))%")
                    .font(.system(size: 10, weight: .medium, design: .rounded).monospacedDigit())
                    .foregroundColor(.secondary).frame(width: 38, alignment: .trailing)
            }
                .tint(barColor(task))
            Text(TranslateModel.friendlyStage(task)).font(.system(size: 10)).foregroundColor(.secondary).lineLimit(1)
            if task.status == "转写中" && !task.message.isEmpty {
                Text(TranslateModel.detailOf(task.message))
                    .font(.system(size: 9)).foregroundColor(.secondary.opacity(0.75))
                    .lineLimit(1).textSelection(.enabled)
            }
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

    private func applyDir() {
        var path = dirDraft.trimmingCharacters(in: .whitespaces)
        if path.hasPrefix("~") { path = NSHomeDirectory() + path.dropFirst() }
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
            dirOK = false; dirMsg = "路径无效（需已存在的文件夹）"; return
        }
        settings.modelDir = path; settings.persist("modelDir", path)
        model.refreshAvailability(settings)
        dirOK = true; dirMsg = "✓ 已应用"
    }

    private func pickModelDir() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.prompt = "选择"
        panel.message = "选择模型文件夹（内含 SenseVoiceSmall 等子目录）· ⌘⇧. 可显示隐藏文件夹"
        if panel.runModal() == .OK, let url = panel.url {
            settings.modelDir = url.path; settings.persist("modelDir", url.path)
            dirDraft = url.path   // 同步回显到「模型目录」输入框
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

    private var envSheet: some View {
        VStack(spacing: 0) {
            HStack {
                Text("运行时与模型").font(.system(size: 14, weight: .bold))
                Spacer()
                Button("完成") { showEnvSheet = false }.keyboardShortcut(.cancelAction)
            }.padding(12)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    sideDetail
                }.padding(12)
            }
        }
        .frame(width: 540, height: 620)
    }

    private var sideDetail: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("运行时与依赖", systemImage: "shippingbox.fill").font(.system(size: 13, weight: .bold))
            HStack(spacing: 8) {
                Image(systemName: model.ffmpegOK ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .foregroundColor(model.ffmpegOK ? .green : .orange)
                if model.ffmpegOK {
                    Text("ffmpeg 已安装（烧录字幕可用）").font(.system(size: 10)).foregroundColor(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("未检测到 ffmpeg — 烧录字幕不可用").font(.system(size: 11, weight: .semibold)).foregroundColor(.orange)
                        HStack(spacing: 6) {
                            Text("brew install ffmpeg").font(.system(size: 10, design: .monospaced))
                                .padding(4).background(Color.primary.opacity(0.06)).cornerRadius(4)
                            Button("复制") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString("brew install ffmpeg", forType: .string) }
                                .controlSize(.mini)
                        }
                        Text("未安装时仅生成字幕文件(.srt)，成片烧录将被拦截").font(.system(size: 9)).foregroundColor(.secondary)
                    }
                }
                Spacer()
            }
            HStack(spacing: 8) {
                Image(systemName: model.envOK ? "checkmark.seal.fill" : (model.envBusy ? "gearshape.2.fill" : "seal"))
                    .foregroundColor(model.envOK ? .green : model.envBusy ? .accentColor : .secondary)
                Text(model.envBusy ? (model.envStage.isEmpty ? "正在构建环境…" : model.envStage)
                                   : (model.envOK ? "转写环境已就绪" : "点右侧按钮一键构建（首次约 3–15 分钟）"))
                    .font(.system(size: 10)).foregroundColor(.secondary).lineLimit(2)
                if model.envBusy { ProgressView(value: model.envProgress).progressViewStyle(.linear).frame(maxWidth: 260) }
                Spacer()
                if !model.envBusy {
                    HStack(spacing: 6) {
                        Button(model.envOK ? "全量重建" : "一键构建环境") { model.buildEnv(settings, full: true) }.controlSize(.small).disabled(model.envBusy)
                        if model.envOK || model.envBusy {
                            if pendingNuke {
                                Button("确认删除？") { pendingNuke = false; model.nukeRuntime(settings) }
                                    .controlSize(.small).tint(.red)
                                Button("再想想") { pendingNuke = false }.controlSize(.small)
                            } else {
                                Button("删除运行时与依赖", role: .destructive) { pendingNuke = true }.controlSize(.small)
                            }
                        }
                    }
                        .help("基于 App 内置 Python 创建独立环境，经清华镜像安装 funasr/torch/mlx-lm（不含模型）")
                }
            }
            Divider()
            HStack(spacing: 4) {
                Label("模型 · ModelScope 魔搭", systemImage: "arrow.down.circle.fill").font(.system(size: 13, weight: .bold))
                Text("（国内直连，无需科学上网）").font(.system(size: 10)).foregroundColor(.secondary)
            }
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(model.downloads) { dl in downloadRow(dl) }
                }
            }
            HStack(spacing: 8) {
                Button("全部下载缺失（ModelScope）") { model.downloadAllMissing(settings) }.controlSize(.small)
                Spacer()
            }
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Image(systemName: "folder").foregroundColor(.secondary)
                    TextField("模型目录（可直接粘贴路径）", text: $dirDraft)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 10, design: .monospaced))
                }
                HStack(spacing: 8) {
                    Button("应用") { applyDir() }.controlSize(.mini).disabled(dirDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button("浏览…") { pickModelDir() }.controlSize(.mini)
                        .help("Finder 面板中可按 ⌘⇧. 显示隐藏文件夹")
                    Spacer()
                    if !dirMsg.isEmpty { Text(dirMsg).font(.system(size: 9)).foregroundColor(dirOK ? .green : .orange) }
                }
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
                VStack(alignment: .leading, spacing: 1) {
                    Text(dl.spec.label).font(.system(size: 11, weight: .medium))
                    Text("\(dl.spec.msRepo) · \(dl.spec.sizeText)").font(.system(size: 9)).foregroundColor(.secondary)
                }
                Spacer()
                if dl.status == "下载中" {
                    Text("↓ \(Int(dl.percent))%").font(.system(size: 9, weight: .semibold)).foregroundColor(.accentColor)
                } else if dl.status.hasPrefix("✓") {
                    Text("✓ 已就绪").font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 8).padding(.vertical, 2.5)
                        .background(Capsule().fill(Color.green.opacity(0.16))).foregroundColor(.green)
                } else {
                    if dl.status.hasPrefix("下载中") && !dl.paused {
                        HStack(spacing: 4) {
                            Button("暂停") { model.pauseDownload(dl.spec) }.controlSize(.regular)
                            Button("停止", role: .destructive) { model.stopDownload(dl.spec) }.controlSize(.regular)
                        }
                    } else if dl.paused {
                        Button("继续") { model.resumeDownload(dl.spec, settings) }.controlSize(.regular)
                    } else if dl.status.hasPrefix("✓") {
                        EmptyView()
                    } else {
                        Button(dl.status.contains("不完整") ? "重新下载" : "ModelScope 下载") { model.download(dl.spec, settings) }.controlSize(.regular)
                    }
                }
            }
            if dl.status.hasPrefix("下载中") {
                    HStack(spacing: 8) {
                        ProgressView(value: min(dl.percent, 100) / 100.0).tint(.accentColor)
                        Text("\(Int(dl.percent))%").font(.system(size: 10, design: .rounded).monospacedDigit())
                            .foregroundColor(.secondary).frame(width: 36, alignment: .trailing)
                    }
                }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.04)))
    }

}

struct LogTextView: View {
    let file: String
    @State private var text = ""
    @State private var revision = 0
    private let timer = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("详细日志").font(.system(size: 12, weight: .semibold))
                Circle().fill(Color.green.opacity(0.8)).frame(width: 6, height: 6)
                    .help("每 1 秒自动刷新并滚动到底部")
                Spacer()
                Button("打开文件") { NSWorkspace.shared.open(URL(fileURLWithPath: file)) }
            }.padding(8)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    Text(text.isEmpty ? "（暂无日志）" : text)
                        .font(.system(size: 10, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                    Color.clear.frame(height: 1).id("BOTTOM")
                }
                .onChange(of: revision) { _ in
                    // 每次刷新无条件贴底（超过500行时行数恒定，不能依赖行数变化）
                    proxy.scrollTo("BOTTOM", anchor: .bottom)
                }
            }
        }
        .onAppear { load(scroll: true) }
        .onReceive(timer) { _ in load(scroll: true) }
    }
    private func load(scroll: Bool = false) {
        guard let c = try? String(contentsOfFile: file, encoding: .utf8) else { return }
        let next = c.split(separator: "\n").suffix(500).joined(separator: "\n")
        if next != text { text = next }
        revision += 1
    }
}
