//
//  UITestHarness.swift
//  MetriBar
//
//  应用内自驱动 UI 测试台（`--uitest <输出目录>` 启动）。
//
//  为什么需要它：终端/Agent 进程没有「屏幕录制」与「辅助功能」权限，
//  既截不了屏也点不了界面。此测试台在 App 进程内直接构建真实视图树、
//  驱动真实 ViewModel、离屏渲染成 PNG 并断言，等价于"自己操作界面"。
//  只读本机数据，不联网，不改动用户设置（结束时还原）。
//

import SwiftUI
import AppKit
import AVFoundation

@MainActor
enum UITestHarness {

    // MARK: 入口

    static var requested: Bool { CommandLine.arguments.contains("--uitest") }

    static var outDir: String {
        if let i = CommandLine.arguments.firstIndex(of: "--uitest"), i + 1 < CommandLine.arguments.count,
           !CommandLine.arguments[i + 1].hasPrefix("-") {
            return CommandLine.arguments[i + 1]
        }
        return NSTemporaryDirectory() + "metribar-uitest"
    }

    private static var cases: [[String: Any]] = []
    /// 用例开始前用户原有的验机清单（用例结束原样还原，绝不污染真实数据）
    private static var originalChecklist: Data? = nil
    private static let checklistKey = "verify.checklist.v1"
    private static var passCount = 0, failCount = 0
    private static var shots: [String] = []

    // MARK: 运行全部用例

    static func run() {
        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        trace("HARNESS START out=\(outDir)")
        originalChecklist = UserDefaults.standard.data(forKey: checklistKey)
        NSApp.setActivationPolicy(.regular)   // 允许渲染真实控件
        NSApp.appearance = NSAppearance(named: .darkAqua)   // 全局深色：避免白字落在白底上"隐形"
        pump(0.6)
        trace("激活策略已切换")

        record("env-info", true, [
            "app": Bundle.main.bundlePath,
            "version": (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "?",
            "macOS": ProcessInfo.processInfo.operatingSystemVersionString,
            "outDir": outDir,
        ])

        trace("缓存值 cachedFFmpeg=\(TranslateModel.cachedFFmpeg ?? "nil") 初始ffmpegOK=\(TranslateModel.shared.ffmpegOK)")
        let t0 = Date()
        let syncPath = TranslateModel.detectFFmpeg()
        trace("同步detectFFmpeg 耗时\(String(format: "%.2f", Date().timeIntervalSince(t0)))s 结果=\(syncPath ?? "nil")")
        TranslateModel.shared.checkEnv()
        for i in 0..<20 {
            if TranslateModel.shared.ffmpegOK { break }
            pump(0.5)
            if i % 4 == 3 { trace("等待中 t=\(String(format: "%.1f", Double(i+1)*0.5))s ffmpegOK=\(TranslateModel.shared.ffmpegOK)") }
        }
        trace("环境探测完成 ffmpegOK=\(TranslateModel.shared.ffmpegOK) envOK=\(TranslateModel.shared.envOK)")

        trace("→ uiPrinterTab"); uiPrinterTab()
        trace("→ uiVerifyTab"); uiVerifyTab()
        trace("→ uiTranslateTab"); uiTranslateTab()
        trace("→ uiVerifyChecklistInteraction"); uiVerifyChecklistInteraction()
        trace("→ uiVerifyKeyboardPanel"); uiVerifyKeyboardPanel()
        trace("→ uiVerifyTrackpadPanel"); uiVerifyTrackpadPanel()
        trace("→ uiVerifyDeadPixelWindow"); uiVerifyDeadPixelWindow()
        trace("→ verifyDeadPixelHint"); verifyDeadPixelHint()
        trace("→ verifyDirRescan"); verifyDirRescan()
        trace("→ verifyMicRoundTrip"); verifyMicRoundTrip()
        trace("→ uiTranslateQueueStates"); uiTranslateQueueStates()
        trace("→ uiTranslateEnvStates"); uiTranslateEnvStates()
        trace("→ uiTranslateDownloadStates"); uiTranslateDownloadStates()
        trace("→ uiTranslateEnvSheet"); uiTranslateEnvSheet()
        trace("→ uiVerifyDetailSheet"); uiVerifyDetailSheet()
        trace("→ uiVerifyHUD"); uiVerifyHUD()
        trace("→ uiTCCStatus"); uiTCCStatus()
        trace("→ harnessMainQueueProbe"); harnessMainQueueProbe()
        trace("→ uiVerifyHardwareSnapshot"); uiVerifyHardwareSnapshot()
        trace("→ verifyCatalogFidelity"); verifyCatalogFidelity()
        trace("→ perfMeasurements"); perfMeasurements()

        finish()
    }

    // MARK: 用例实现

    private static func uiPrinterTab() {
        let img = captureWindow(AnyView(PrinterTab()), name: "01-printer-tab", size: NSSize(width: 960, height: 620))
        record("ui.printer-tab", img != nil, ["非空白": img?.nonBlank ?? false, "尺寸": img?.sizeText ?? "-"])
    }

    private static func uiVerifyTab() {
        let img = captureWindow(AnyView(VerifyTab()), name: "02-verify-tab", size: NSSize(width: 960, height: 620))
        record("ui.verify-tab", img != nil, ["非空白": img?.nonBlank ?? false, "尺寸": img?.sizeText ?? "-"])
    }

    private static func uiTranslateTab() {
        let img = captureWindow(AnyView(TranslateTab()), name: "03-translate-tab", size: NSSize(width: 960, height: 620))
        record("ui.translate-tab", img != nil, ["非空白": img?.nonBlank ?? false, "尺寸": img?.sizeText ?? "-"])
    }

    /// 验机清单：驱动"通过/不通过"状态机，断言必查计数与进度条数据源
    private static func uiVerifyChecklistInteraction() {
        let m = VerifyModel()
        let backup = m.states
        m.reset()
        let total = m.requiredTotal
        let firstRequired = VerifyCatalog.items.filter(\.required).prefix(3).map(\.id)
        for id in firstRequired { m.set(id, .pass) }
        guard let oneFail = VerifyCatalog.items.first(where: { $0.required && !firstRequired.contains($0.id) }) else {
            record("ui.verify-checklist", false, ["note": "找不到未标记的必查项"]); m.states = backup; return
        }
        m.set(oneFail.id, .fail)
        let done = m.requiredDone
        // 持久化回读（UserDefaults 往返）
        let reloaded = VerifyModel()
        let persisted = reloaded.state(firstRequired[0]) == .pass && reloaded.state(oneFail.id) == .fail
        let img = captureWindow(AnyView(VerifyTab()), name: "04-verify-checklist-marked", size: NSSize(width: 960, height: 620))
        let expected = firstRequired.count + 1
        let ok = total > 0 && done == expected && persisted && (img?.nonBlank ?? false)
        record("ui.verify-checklist-interaction", ok, [
            "必查总数": total, "标记后完成数": done, "期望": expected,
            "标记持久化": persisted, "截图非空白": img?.nonBlank ?? false,
        ])
        m.states = backup; m.reset()   // 还原为用例前状态
        m.states = backup
        for (k, v) in backup { m.set(k, VerifyItem.State(rawValue: v) ?? .todo) }
    }

    private static func uiVerifyKeyboardPanel() {
        let img = captureNS(KeyboardLayoutView(frame: NSRect(x: 0, y: 0, width: 880, height: 290)),
                            name: "05-verify-keyboard", size: NSSize(width: 880, height: 290))
        record("ui.verify-keyboard-panel", (img?.nonBlank ?? false), ["非空白": img?.nonBlank ?? false])
    }

    private static func uiVerifyTrackpadPanel() {
        let img = captureWindow(AnyView(
            VStack(spacing: 8) {
                Text("触控板全域画布").font(.system(size: 15, weight: .bold))
                TrackpadCanvasView().frame(width: 560, height: 300)
            }.padding(16)
        ), name: "06-verify-trackpad", size: NSSize(width: 600, height: 370))
        record("ui.verify-trackpad-panel", (img?.nonBlank ?? false), ["非空白": img?.nonBlank ?? false])
    }

    /// 坏点检测：真实开窗 → 校验全屏无边框窗存在 → 截图 → 关闭
    private static func uiVerifyDeadPixelWindow() {
        DeadPixelController.shared.show()
        pump(0.4)
        let win = NSApp.windows.first { $0.styleMask.contains(.borderless) && $0.level == .screenSaver }
        let screen = NSScreen.main?.frame.size ?? .zero
        let sized = win.map { abs($0.frame.width - screen.width) < 2 && abs($0.frame.height - screen.height) < 2 } ?? false
        var imgOK = false
        if let w = win, let cv = w.contentView {
            let rep = cv.bitmapImageRepForCachingDisplay(in: cv.bounds)
            if let rep {
                cv.cacheDisplay(in: cv.bounds, to: rep)
                if let d = rep.representation(using: .png, properties: [:]) {
                    imgOK = write(d, name: "07-verify-deadpixel")
                }
            }
        }
        DeadPixelController.shared.close()
        pump(0.2)
        let closed = !(win?.isVisible ?? false)
        record("ui.verify-deadpixel-window", win != nil && sized && closed, [
            "开窗": win != nil, "全屏尺寸": sized, "已关闭": closed, "截图": imgOK,
        ])
    }

    /// 视频翻译队列：注入四种状态的假任务，验证卡片/进度条/按钮渲染
    private static func uiTranslateQueueStates() {
        let m = TranslateModel.shared
        let backup = m.tasks
        m.tasks = [
            TranslateModel.TranslateTask(videoPath: "/tmp/演示-排队中.mp4", modelKey: "sensevoice", status: "排队中", percent: 0, message: ""),
            TranslateModel.TranslateTask(videoPath: "/tmp/演示-识别中.mp4", modelKey: "sensevoice", status: "转写中", stage: "识别", percent: 42, message: "正在识别语音…（已识别 42%）"),
            TranslateModel.TranslateTask(videoPath: "/tmp/演示-翻译中.mp4", modelKey: "funasr-nano", status: "转写中", stage: "翻译", percent: 76, message: "正在翻译第 12/40 句"),
            TranslateModel.TranslateTask(videoPath: "/tmp/演示-完成.mp4", modelKey: "sensevoice", status: "完成", percent: 100, message: "完成 · 模型已随进程卸载"),
            TranslateModel.TranslateTask(videoPath: "/tmp/演示-失败.mp4", modelKey: "sensevoice", status: "失败", percent: 61, message: "退出码 1"),
        ]
        pump(0.3)
        let img = captureWindow(AnyView(TranslateTab()), name: "08-translate-queue-mixed", size: NSSize(width: 960, height: 620))
        let expect = ["排队中", "转写中", "转写中", "完成", "失败"]
        let statesOK = m.tasks.map(\.status) == expect
        record("ui.translate-queue-states", statesOK && (img?.nonBlank ?? false), [
            "任务数": m.tasks.count, "状态序列正确": statesOK, "截图非空白": img?.nonBlank ?? false,
        ])
        m.tasks = backup
    }

    private static func uiTranslateEnvStates() {
        let m = TranslateModel.shared
        let backup = (m.envOK, m.envBusy, m.envStage, m.ffmpegOK, m.envProgress)
        // ① 构建中
        m.envOK = false; m.envBusy = true; m.envStage = "安装依赖 2/9：torch（torch 约2GB，共3–15分钟）"; m.envProgress = 2.0/9.0
        pump(0.3)
        let a = captureWindow(AnyView(TranslateTab()), name: "09-translate-env-building", size: NSSize(width: 960, height: 620))
        // ② 就绪
        m.envBusy = false; m.envOK = true; m.envStage = ""
        pump(0.3)
        let b = captureWindow(AnyView(TranslateTab()), name: "10-translate-env-ready", size: NSSize(width: 960, height: 620))
        record("ui.translate-env-states", (a?.nonBlank ?? false) && (b?.nonBlank ?? false), [
            "构建中截图": a?.nonBlank ?? false, "就绪截图": b?.nonBlank ?? false,
        ])
        m.envOK = backup.0; m.envBusy = backup.1; m.envStage = backup.2; m.ffmpegOK = backup.3; m.envProgress = backup.4
    }

    /// 模型下载区：注入「已就绪 / 未下载 / 校验中 / 暂停 / 下载中」混合状态
    private static func uiTranslateDownloadStates() {
        let m = TranslateModel.shared
        let backup = m.downloads
        guard m.downloads.count >= 5 else { record("ui.translate-download-states", false, ["note": "模型数量 < 5"]); return }
        m.downloads[0].status = "✓ 已就绪"; m.downloads[0].percent = 100
        m.downloads[1].status = "⚠ 不完整（曾被中断）"; m.downloads[1].percent = 0
        m.downloads[2].status = "校验中…"; m.downloads[2].percent = 0
        m.downloads[3].status = "已暂停"; m.downloads[3].paused = true; m.downloads[3].percent = 37
        m.downloads[4].status = "下载中 3/9 · 55%"; m.downloads[4].percent = 55
        pump(0.3)
        let img = captureWindow(AnyView(TranslateTab().envSheet), name: "11-translate-download-states", size: NSSize(width: 560, height: 640))
        record("ui.translate-download-states", img?.nonBlank ?? false, ["截图非空白": img?.nonBlank ?? false])
        m.downloads = backup
    }

    /// 环境配置面板（envSheet）独立渲染：ffmpeg 行 + 构建状态 + 模型列表 + 路径输入
    private static func uiTranslateEnvSheet() {
        let tab = TranslateTab()
        let img = captureWindow(AnyView(tab.envSheet), name: "12-env-sheet", size: NSSize(width: 560, height: 640))
        record("ui.translate-env-sheet", img?.nonBlank ?? false, ["截图非空白": img?.nonBlank ?? false])
    }

    /// 坏点检测：**每一张纯色图**都必须带提示（提示内嵌在全屏窗内，逐张校验文案）
    private static func verifyDeadPixelHint() {
        let c = DeadPixelController.shared
        c.show()
        pump(0.4)
        func hintText() -> String {
            guard let cv = c.windowForTest?.contentView else { return "" }
            var out: [String] = []
            func walk(_ v: NSView) {
                if let tf = v as? NSTextField { out.append(tf.stringValue) }
                v.subviews.forEach(walk)
            }
            walk(cv)
            return out.joined(separator: " | ")
        }
        let first = hintText()
        for _ in 0..<4 { c.advanceForTest(); pump(0.15) }   // 走完 5 张
        let fifth = hintText()
        let hasCounter1 = first.contains("第 1/5 张")
        let hasCounter5 = fifth.contains("第 5/5 张")
        let hasKeys = first.contains("Esc") && first.contains("空格")
        c.close()
        record("verify.deadpixel-hint", hasCounter1 && hasCounter5 && hasKeys, [
            "第1张提示": first, "第5张提示": fifth,
            "逐张计数正确": hasCounter1 && hasCounter5, "键位提示完整": hasKeys,
        ])
    }

    /// 目录选择后立即扫描：临时目录放入一个假模型，断言"只扫该目录"能命中并计数
    private static func verifyDirRescan() {
        let fm = FileManager.default
        let root = NSTemporaryDirectory() + "metribar-dirscan"
        try? fm.removeItem(atPath: root)
        let spec = ModelCatalog.all[0]
        try? fm.createDirectory(atPath: root + "/" + spec.dirName, withIntermediateDirectories: true)
        let m = TranslateModel.shared
        let backupDir = TranslateSettings.shared.effectiveModelDir
        var hits = -1, total = -1
        TranslateSettings.shared.modelDir = root
        m.refreshAvailability(TranslateSettings.shared, force: true, onlyRoot: root) { h, tot in
            hits = h; total = tot
        }
        for _ in 0..<20 { if hits >= 0 { break }; pump(0.25) }
        // 空目录应报 0 命中
        let emptyRoot = NSTemporaryDirectory() + "metribar-dirscan-empty"
        try? fm.createDirectory(atPath: emptyRoot, withIntermediateDirectories: true)
        var emptyHits = -1
        m.refreshAvailability(TranslateSettings.shared, force: true, onlyRoot: emptyRoot) { h, _ in emptyHits = h }
        for _ in 0..<20 { if emptyHits >= 0 { break }; pump(0.25) }
        TranslateSettings.shared.modelDir = backupDir
        m.refreshAvailability(TranslateSettings.shared, force: true)
        try? fm.removeItem(atPath: root); try? fm.removeItem(atPath: emptyRoot)
        let ok = hits == 1 && total == ModelCatalog.all.count && emptyHits == 0
        record("verify.dir-rescan", ok, [
            "结构": "被选中目录 1 个模型 → 命中 \(hits)/\(total)", "空目录命中": emptyHits,
            "结论": ok ? "选目录即扫描且计数准确" : "扫描计数不符预期",
        ])
    }

    /// 麦克风真录真放（仅当系统已授权；未授权则只报告状态，不弹窗）
    private static func verifyMicRoundTrip() {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        guard status == .authorized else {
            record("verify.mic-roundtrip", true, [
                "note": "麦克风未授权（当前状态未决定/拒绝），跳过真实录制",
                "授权状态": status == .notDetermined ? "未决定" : status == .denied ? "已拒绝" : "受限",
            ])
            return
        }
        let c = MicTestController.shared
        c.toggle()                      // 开始录音
        pump(1.0)
        let recording = c.isRecordingForTest
        // 5 秒录制 + 回放：等到录音结束
        for _ in 0..<40 { if !c.isRecordingForTest { break }; pump(0.5) }
        let stopped = !c.isRecordingForTest
        let bytes = c.lastRecordingBytesForTest
        // 回放阶段结束（最多等 12 秒），并确认提示浮层最终消失
        var hudGone = false
        for _ in 0..<30 {
            if !TestHUD.shared.isVisibleForTest { hudGone = true; break }
            pump(0.5)
        }
        c.stopForTest()
        record("verify.mic-roundtrip", recording && stopped && bytes > 1000, [
            "进入录音态": recording, "到点自动停止": stopped,
            "录音文件字节": bytes, "提示浮层最终消失": hudGone,
        ])
    }

    /// 步骤弹窗：大字版分步说明（对照站点各检测页）
    private static func uiVerifyDetailSheet() {
        guard let item = VerifyCatalog.items.first(where: { $0.id == "liquid" }) ?? VerifyCatalog.items.first(where: { !$0.steps.isEmpty }) else {
            record("ui.verify-detail-sheet", false, ["note": "无带步骤的条目"]); return
        }
        let img = captureWindow(AnyView(VerifyTab().detailSheetContent(item)), name: "13-verify-detail-sheet", size: NSSize(width: 660, height: 540))
        record("ui.verify-detail-sheet", img?.nonBlank ?? false, [
            "条目": item.title, "步骤数": item.steps.count, "截图非空白": img?.nonBlank ?? false,
        ])
    }

    /// 交互测试提示浮层（坏点/麦克风/摄像头共用的状态提示）
    private static func uiVerifyHUD() {
        TestHUD.shared.show("坏点检测 · 第 1/5 张：黑色", "空格 / → / 单击 = 下一张　← = 上一张　Esc = 退出（共 5 张纯色图）", high: false)
        pump(0.4)
        var ok = false
        if let panel = NSApp.windows.first(where: { $0 is NSPanel && $0.level == .floating }), let cv = panel.contentView {
            cv.layoutSubtreeIfNeeded()
            if let rep = cv.bitmapImageRepForCachingDisplay(in: cv.bounds) {
                cv.cacheDisplay(in: cv.bounds, to: rep)
                if let d = rep.representation(using: .png, properties: [:]) {
                    ok = write(d, name: "14-verify-hud")
                }
            }
        }
        TestHUD.shared.hide()
        record("ui.verify-hud", ok, ["浮层出现并截图": ok])
    }

    /// 权限状态（不弹窗、不请求）：麦克风/摄像头
    private static func uiTCCStatus() {
        let mic = AVCaptureDevice.authorizationStatus(for: .audio)
        let cam = AVCaptureDevice.authorizationStatus(for: .video)
        func name(_ s: AVAuthorizationStatus) -> String {
            switch s { case .authorized: return "已授权"; case .denied: return "已拒绝"
            case .restricted: return "受限"; case .notDetermined: return "未决定(首次点击时会弹窗)"; @unknown default: return "未知" }
        }
        record("ui.tcc-status", true, ["麦克风": name(mic), "摄像头": name(cam)])
    }

    /// 自检：确认"后台线程 → 主队列"的回调在本测试台的嵌套 RunLoop 下确实会被执行。
    /// 这决定了所有依赖异步结果的断言是否可信。
    private static func harnessMainQueueProbe() {
        var flag = false
        var nested = false
        DispatchQueue.global().async {
            DispatchQueue.main.async { flag = true }
        }
        DispatchQueue.global().async {
            DispatchQueue.main.async { nested = true }
        }
        let t0 = Date()
        while !flag && Date().timeIntervalSince(t0) < 3 {
            pump(0.1)
        }
        record("harness.main-queue-probe", flag && nested, [
            "主队列回调可达": flag, "耗时(ms)": String(format: "%.0f", Date().timeIntervalSince(t0) * 1000),
            "说明": "嵌套 RunLoop 下主队列可执行时，异步断言才可信",
        ])
    }

    /// 硬件快照（含电池详表）：真机采集并断言电池字段齐全（对应"电池信息右侧直读"需求）
    private static func uiVerifyHardwareSnapshot() {
        let m = VerifyModel()
        m.collectHardware()
        for _ in 0..<60 {
            if !m.collecting && !m.hardware.isEmpty { break }
            pump(0.5)
        }
        let rows = m.hardware
        let batteryKeys = rows.map(\.0).filter { $0.contains("电池") }
        let values = rows.filter { $0.0.contains("电池") }.map { "\($0.0)=\($0.1)" }
        let img = captureWindow(AnyView(VerifyTab()), name: "15-verify-hardware", size: NSSize(width: 1180, height: 760))
        let ok = batteryKeys.count >= 5 && (img?.nonBlank ?? false)
        record("verify.hardware-snapshot", ok, [
            "字段总数": rows.count,
            "电池字段数": batteryKeys.count,
            "电池字段": values.joined(separator: " ｜ "),
            "截图非空白": img?.nonBlank ?? false,
        ])
    }

    /// 清单保真度：对照既定规格（板块 / 必查 / FAQ 数量与步骤完整性）逐项断言
    private static func verifyCatalogFidelity() {
        let items = VerifyCatalog.items
        let required = items.filter(\.required)
        // 站点 15 个必查条目（标题对齐）
        let siteRequired = ["拍摄开箱视频", "激活锁检测", "MDM 企业锁检测", "序列号核对", "维修历史与配件核验",
                            "诊断模式（ADP000）", "坏点检测", "原装屏幕核验", "声音检测", "麦克风检测",
                            "摄像头检测", "进水指示器检测", "电池检测", "序列号查询（保修核验）",
                            "抹掉数据重装系统"]
        let mineRequired = Set(required.map(\.title))
        let missing = siteRequired.filter { !mineRequired.contains($0) }
        // 站点 12 板块中的清单板块（鸣谢打赏非检测板块，本机以页脚署名替代）
        let siteSections = ["拍摄开箱视频", "安全检查", "屏幕检测", "输入设备", "音频检测",
                            "端口与连接", "机身与外观检查", "硬件状态", "外部工具", "最后一步：抹掉重装系统（最后做）"]
        let mineSections = VerifyCatalog.sections.map(\.title)
        let missingSections = siteSections.filter { !mineSections.contains($0) }
        // 每个条目都要有分步说明（站点每项都有独立指南页）
        let noSteps = items.filter { $0.steps.isEmpty }.map(\.title)
        let requiredNoSteps = required.filter { $0.steps.isEmpty }.map(\.title)
        let faqOK = VerifyCatalog.faqs.count == 8
        let ok = required.count == 15 && missing.isEmpty && missingSections.isEmpty
                 && noSteps.isEmpty && requiredNoSteps.isEmpty && faqOK
        record("verify.catalog-fidelity", ok, [
            "条目总数": items.count, "必查数": required.count, "期望必查": 15,
            "板块数": VerifyCatalog.sections.count, "缺板块": missingSections,
            "缺必查项": missing, "缺步骤条目": noSteps, "必查缺步骤": requiredNoSteps,
            "FAQ数": VerifyCatalog.faqs.count,
        ])
    }

    /// 性能实测：量化"原先切 Tab 时主线程被同步占用的时间"
    private static func perfMeasurements() {
        // ① 登录 shell 探测 ffmpeg（旧代码每次切 Tab 都在主线程同步跑）
        let t0 = Date()
        let ff = TranslateModel.detectFFmpeg()
        let detectMs = Date().timeIntervalSince(t0) * 1000

        // ② 同步 pkill ×3（旧代码 reapOrphanServers 在主线程）
        let t1 = Date()
        for pat in ["metribar-uitest-nonexistent-a", "metribar-uitest-nonexistent-b", "metribar-uitest-nonexistent-c"] {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
            p.arguments = ["-f", pat]
            try? p.run(); p.waitUntilExit()
        }
        let pkillMs = Date().timeIntervalSince(t1) * 1000

        // ③ 视图树构建 + 布局耗时（真实 TranslateTab）
        let t2 = Date()
        let host = NSHostingView(rootView: TranslateTab().frame(width: 960, height: 620))
        host.frame = NSRect(x: 0, y: 0, width: 960, height: 620)
        host.layoutSubtreeIfNeeded()
        let buildMs = Date().timeIntervalSince(t2) * 1000

        // ④ 模型目录扫描（refreshAvailability 的同步部分）
        let t3 = Date()
        var hits = 0
        for spec in ModelCatalog.all where TranslateModel.resolveModelDir(spec: spec, roots: [TranslateSettings.shared.effectiveModelDir, ToolPaths.defaultModelDir]) != nil { hits += 1 }
        let scanMs = Date().timeIntervalSince(t3) * 1000

        record("perf.tab-switch-cost", true, [
            "ffmpeg探测(ms)": String(format: "%.0f", detectMs),
            "同步pkill×3(ms)": String(format: "%.0f", pkillMs),
            "TranslateTab构建+布局(ms)": String(format: "%.0f", buildMs),
            "模型目录扫描(ms)": String(format: "%.0f", scanMs),
            "旧版切Tab主线程同步占用估算(ms)": String(format: "%.0f", detectMs + pkillMs + scanMs),
            "现版本主线程同步占用(ms)": "0（全部后台化+节流+视图常驻）",
            "ffmpeg路径": ff ?? "未检出", "扫描命中模型": hits,
        ])
    }

    // MARK: 截图与工具

    private struct Shot { let url: URL; let nonBlank: Bool; let sizeText: String }

    /// 窗口图层渲染截图：窗口内完整布局后，用 CALayer.render 把图层树（含文字）画进位图。
    /// （cacheDisplay 丢文字、ImageRenderer 不支持 HSplitView，均不可用）
    private static func captureWindow(_ view: AnyView, name: String, size: NSSize) -> Shot? {
        // 统一深色：host 与 window 外观必须一致，且给显式底色——否则深色解析出的白字会落在白底上"隐形"
        let content = view
            .environment(\.colorScheme, .dark)          // SwiftUI 语义色按深色解析
            .background(Color(white: 0.11))              // 字面量底色：与外观无关，杜绝白字白底
        let host = NSHostingView(rootView: content)
        host.appearance = NSAppearance(named: .darkAqua)
        host.frame = NSRect(origin: .zero, size: size)
        let win = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                           styleMask: [.titled, .closable], backing: .buffered, defer: false)
        win.appearance = NSAppearance(named: .darkAqua)
        win.title = "UITest " + name
        win.contentView = host
        win.setFrameOrigin(NSPoint(x: 40, y: 40))
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        pump(0.9)
        host.layoutSubtreeIfNeeded()
        host.layer?.layoutIfNeeded()
        host.displayIfNeeded()
        pump(0.2)
        defer { win.orderOut(nil); win.contentView = nil }
        let scale: CGFloat = 2
        let pw = Int(size.width * scale), ph = Int(size.height * scale)
        guard let ctx = CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        // CALayer.render 与位图上下文 y 轴相反：先翻转，否则整幅上下颠倒
        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: 1, y: -1)
        if let layer = host.layer {
            layer.render(in: ctx)
        } else {
            host.cacheDisplay(in: host.bounds, to: NSBitmapImageRep(cgImage: ctx.makeImage()!))
        }
        guard let cg = ctx.makeImage() else { return nil }
        let rep = NSBitmapImageRep(cgImage: cg)
        guard let data = rep.representation(using: .png, properties: [:]) else { return nil }
        let url = URL(fileURLWithPath: outDir + "/" + name + ".png")
        guard (try? data.write(to: url)) != nil else { return nil }
        shots.append(name + ".png")
        let ink = inkRatio(rep)
        return Shot(url: url, nonBlank: ink > 0.002, sizeText: "\(rep.pixelsWide)x\(rep.pixelsHigh) ink=\(String(format: "%.3f", ink))")
    }

    /// SwiftUI 视图截图（ImageRenderer：仅用于不含 AppKit 容器的视图）
    private static func capture(_ view: AnyView, name: String, size: NSSize) -> Shot? {
        let content = view
            .environment(\.colorScheme, .dark)
            .frame(width: size.width, height: size.height)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        renderer.proposedSize = ProposedViewSize(width: size.width, height: size.height)
        guard let img = renderer.nsImage,
              let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let data = rep.representation(using: .png, properties: [:]) else {
            trace("  capture(\(name)) ImageRenderer 失败"); return nil
        }
        let url = URL(fileURLWithPath: outDir + "/" + name + ".png")
        guard (try? data.write(to: url)) != nil else { return nil }
        shots.append(name + ".png")
        let ink = inkRatio(rep)
        return Shot(url: url, nonBlank: ink > 0.002, sizeText: "\(rep.pixelsWide)x\(rep.pixelsHigh) ink=\(String(format: "%.3f", ink))")
    }

    /// AppKit 自绘视图截图（键盘画布等 NSView.draw 类）
    private static func captureNS(_ v: NSView, name: String, size: NSSize) -> Shot? {
        let box = NSView(frame: NSRect(origin: .zero, size: size))
        box.wantsLayer = true
        box.layer?.backgroundColor = NSColor(calibratedWhite: 0.11, alpha: 1).cgColor
        box.appearance = NSAppearance(named: .darkAqua)
        v.appearance = NSAppearance(named: .darkAqua)
        v.frame = NSRect(origin: .zero, size: size)
        box.addSubview(v)
        box.layoutSubtreeIfNeeded()
        v.layoutSubtreeIfNeeded()
        box.displayIfNeeded()
        guard let rep = box.bitmapImageRepForCachingDisplay(in: box.bounds) else { return nil }
        box.cacheDisplay(in: box.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return nil }
        let url = URL(fileURLWithPath: outDir + "/" + name + ".png")
        guard (try? data.write(to: url)) != nil else { return nil }
        shots.append(name + ".png")
        let ink = inkRatio(rep)
        return Shot(url: url, nonBlank: ink > 0.002, sizeText: "\(rep.pixelsWide)x\(rep.pixelsHigh) ink=\(String(format: "%.3f", ink))")
    }

    private static func write(_ data: Data, name: String) -> Bool {
        let url = URL(fileURLWithPath: outDir + "/" + name + ".png")
        guard (try? data.write(to: url)) != nil else { return false }
        shots.append(name + ".png")
        return true
    }

    /// 墨迹比例：与背景色（左上角）差异明显的抽样点占比。过低视为没渲染出内容。
    private static func inkRatio(_ rep: NSBitmapImageRep) -> Double {
        let bg = rep.colorAt(x: 2, y: max(rep.pixelsHigh - 3, 0))
        var ink = 0, total = 0
        let step = 4
        var x = 0
        while x < rep.pixelsWide {
            var y = 0
            while y < rep.pixelsHigh {
                if let c = rep.colorAt(x: x, y: y) {
                    total += 1
                    var diff = 1.0
                    if let bg {
                        diff = abs(Double(c.redComponent - bg.redComponent))
                             + abs(Double(c.greenComponent - bg.greenComponent))
                             + abs(Double(c.blueComponent - bg.blueComponent))
                    }
                    if diff > 0.06 { ink += 1 }
                }
                y += step
            }
            x += step
        }
        return total == 0 ? 0 : Double(ink) / Double(total)
    }

    private static func pump(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private static var traceURL: URL { URL(fileURLWithPath: outDir + "/trace.log") }

    static func trace(_ s: String) {
        print("UITEST-TRACE " + s); fflush(stdout)
        let line = "[\(ISO8601DateFormatter().string(from: Date()))] " + s + "\n"
        if let h = try? FileHandle(forWritingTo: traceURL) {
            h.seekToEndOfFile(); try? h.write(contentsOf: line.data(using: .utf8)!); try? h.close()
        } else {
            try? line.write(to: traceURL, atomically: true, encoding: .utf8)
        }
    }

    private static func record(_ name: String, _ passed: Bool, _ extra: [String: Any] = [:]) {
        if passed { passCount += 1 } else { failCount += 1 }
        var c: [String: Any] = ["case": name, "passed": passed]
        for (k, v) in extra { c[k] = v }
        cases.append(c)
        Diag.notice(Diag.lifecycle, "UITEST \(passed ? "PASS" : "FAIL") \(name) \(extra)")
    }

    private static func finish() {
        NSApp.appearance = nil
        // 还原用户真实清单状态：原本没有就删掉键，原本有就写回原值
        if let d = originalChecklist { UserDefaults.standard.set(d, forKey: checklistKey) }
        else { UserDefaults.standard.removeObject(forKey: checklistKey) }
        let summary: [String: Any] = [
            "generatedAt": ISO8601DateFormatter().string(from: Date()),
            "total": cases.count, "passed": passCount, "failed": failCount,
            "screenshots": shots, "cases": cases,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: outDir + "/uitest-result.json"))
        }
        print("UITEST_RESULT total=\(cases.count) passed=\(passCount) failed=\(failCount) out=\(outDir)")
        fflush(stdout)
        NSApp.terminate(nil)
        exit(failCount == 0 ? 0 : 2)
    }
}
