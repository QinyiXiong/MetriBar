//
//  VerifyTab.swift
//  MetriBar
//
//  MacBook 验机：卡片式必查清单（文案原创）+ 交互检测 + 硬件快照。
//  硬件信息全部来自 system_profiler JSON（键名稳定、不受系统语言影响）
//  与本机只读命令，绝不联网。
//

import SwiftUI
import Combine

// MARK: - 数据模型

struct VerifyItem: Identifiable, Equatable {
    enum State: Int { case todo = 0, pass = 1, fail = 2 }
    let id: String
    var required: Bool = false
    var interactive: Bool = false
    var auto: Bool = false        // 有系统自动核验结果
    let title: String
    let guide: String
}

@MainActor
final class VerifyModel: ObservableObject {
    @Published var states: [String: Int] = [:]
    @Published var hardware: [(String, String)] = []
    @Published var collecting = false

    private let defaultsKey = "verify.checklist.v1"

    init() {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let saved = try? JSONDecoder().decode([String: Int].self, from: data) { states = saved }
    }

    func state(_ id: String) -> VerifyItem.State { VerifyItem.State(rawValue: states[id] ?? 0) ?? .todo }
    func set(_ id: String, _ st: VerifyItem.State) { states[id] = st.rawValue; persist() }
    func reset() { states.removeAll(); persist() }
    private func persist() {
        if let data = try? JSONEncoder().encode(states) { UserDefaults.standard.set(data, forKey: defaultsKey) }
    }

    var requiredTotal: Int { VerifyCatalog.items.filter(\.required).count }
    var requiredDone: Int { VerifyCatalog.items.filter { $0.required && state($0.id) != .todo }.count }

    // MARK: 硬件快照（system_profiler JSON + 只读命令）

    func collectHardware() {
        DispatchQueue.main.async { [weak self] in self?.collecting = true }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var rows: [(String, String)] = []
            func prof(_ type: String) -> [String: Any]? {
                let (rc, out) = Shell.run("/usr/sbin/system_profiler", ["-json", type])
                guard rc == 0, let data = out.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
                return obj
            }
            func items(_ json: [String: Any]?, _ type: String) -> [String: Any] {
                guard let node = json?[type] else { return [:] }
                if let arr = node as? [[String: Any]], let first = arr.first { return first }
                if let dict = node as? [String: Any], let arr = dict["_items"] as? [[String: Any]], let first = arr.first { return first }
                return [:]
            }
            func deep(_ obj: Any?, _ keyContains: [String]) -> Any? {
                guard let obj else { return nil }
                if let d = obj as? [String: Any] {
                    for (k, v) in d where keyContains.allSatisfy(k.lowercased().contains) { return v }
                    for v in d.values { if let r = deep(v, keyContains) { return r } }
                }
                if let arr = obj as? [Any] { for v in arr { if let r = deep(v, keyContains) { return r } } }
                return nil
            }
            func str(_ v: Any?) -> String? { if let s = v as? String, !s.isEmpty { return s }; return nil }

            let hw = prof("SPHardwareDataType")
            let hwItem = items(hw, "SPHardwareDataType")
            rows.append(("机型", [str(hwItem["machine_name"]), str(hwItem["machine_model"])].compactMap { $0 }.joined(separator: " · ")))
            let chipName = str(hwItem["chip_type"]) ?? "Apple Silicon"
            // "proc 18:6:12:0" → 总核:能效?性能?…→ 翻译成人类语言
            var cpuText = chipName
            if let np = str(hwItem["number_processors"]) {
                let nums = np.split(separator: " ").last.map { $0.split(separator: ":").compactMap { Int($0) } } ?? []
                if nums.count >= 3 {
                    cpuText = "\(chipName) · \(nums[0]) 核 CPU（\(nums[1]) 性能 + \(nums[2]) 能效）"
                }
            }
            let dp0 = prof("SPDisplaysDataType")
            var gpuCores = 0
            if let node = dp0?["SPDisplaysDataType"] {
                let gpus: [[String: Any]] = (node as? [[String: Any]]) ?? ((node as? [String: Any])?["_items"] as? [[String: Any]] ?? [])
                for g in gpus where str(g["sppci_device_type"]) == "spdisplays_gpu" { gpuCores = Int(str(g["sppci_cores"]) ?? "") ?? 0 }
            }
            if gpuCores > 0 { cpuText += " · GPU \(gpuCores) 核" }
            rows.append(("处理器", cpuText))
            rows.append(("内存", str(hwItem["physical_memory"]) ?? "—"))
            rows.append(("序列号", str(hwItem["serial_number"]) ?? "读取失败"))
            if let lock = str(hwItem["activation_lock_status"]) {
                rows.append(("激活锁", lock.contains("enabled") ? "⚠️ 仍开启——交易前必须让卖家当面关闭" : "✓ 已解除"))
            }
            rows.append(("系统", "macOS \(ProcessInfo.processInfo.operatingSystemVersion.majorVersion)." +
                        "\(ProcessInfo.processInfo.operatingSystemVersion.minorVersion) (build \(ProcessInfo.processInfo.operatingSystemVersion.patchVersion))"))

            let sp = prof("SPPowerDataType")
            let cycle = deep(sp, ["cycle_count"]) as? Int
            let health = str(deep(sp, ["battery_health"]) ?? deep(sp, ["health"]))
            if cycle != nil || health != nil {
                var parts: [String] = []
                if let c = cycle { parts.append("循环 \(c) 次") }
                if let h = health, !h.isEmpty { parts.append("系统评估：\(h)") }
                rows.append(("电池", parts.joined(separator: " · ")))
            } else {
                rows.append(("电池", "未检测到内置电池"))
            }
            let (_, battPct) = Shell.run("/bin/bash", ["-lc", "/usr/bin/pmset -g batt"])
            let pctToken = battPct.split(whereSeparator: { " \t\n();;'\u{ff08}\u{ff09}".contains($0) })
                .first(where: { $0.hasSuffix("%") && $0.dropLast().allSatisfy(\.isNumber) })
            if let pct = pctToken {
                let ac = battPct.localizedCaseInsensitiveContains("AC Power") || battPct.contains("交流")
                rows.append(("电量", String(pct) + (ac ? " · 接电源" : " · 电池供电")))
            }

            let dp = prof("SPDisplaysDataType")
            if let node = dp?["SPDisplaysDataType"] {
                let gpus: [[String: Any]] = (node as? [[String: Any]]) ?? ((node as? [String: Any])?["_items"] as? [[String: Any]] ?? [])
                var monLines: [String] = []
                for g in gpus {
                    let drvrs = g["spdisplays_ndrvs"] as? [[String: Any]] ?? []
                    for drv in drvrs {
                        let name = str(drv["_name"]) ?? "未知显示器"
                        let ext = drv["_spdisplays_display-vendor-id"] != nil
                        let res = str(drv["spdisplays_resolution"]) ?? str(drv["_spdisplays_pixels"]) ?? ""
                        monLines.append((ext ? "外接 " : "内建 ") + name + (res.isEmpty ? "" : " · \(res)"))
                    }
                }
                for m in monLines { rows.append(("显示器", m)) }
            }

            let st = prof("SPStorageDataType")
            var ssdName = ""
            if let node = st?["SPStorageDataType"] {
                let items: [[String: Any]] = (node as? [[String: Any]])
                    ?? ((node as? [String: Any])?["_items"] as? [[String: Any]] ?? [])
                for it in items where str(it["mount_point"]) == "/" || (it["physical_drive"] != nil && ssdName.isEmpty) {
                    if let pd = it["physical_drive"] as? [String: Any],
                       let dn = str(pd["device_name"]), !(str(pd["media_type"]) ?? "").localizedCaseInsensitiveContains("Disk Image") {
                        ssdName = dn
                    }
                    if str(it["mount_point"]) == "/" || str(it["mount_point"])?.hasSuffix("/Data") == true {
                        if let sz = it["size_in_bytes"].flatMap({ Int64("\($0)") }),
                           let free = it["free_space_in_bytes"].flatMap({ Int64("\($0)") }) {
                            rows.append(("磁盘空间", String(format: "可用 %.0f GB / 总 %.0f GB（%.0f%% 已用）",
                                                            Double(free) / 1e9, Double(sz) / 1e9,
                                                            Double(sz - free) / Double(max(sz, 1)) * 100)))
                        }
                    }
                }
            }
            if !ssdName.isEmpty { rows.append(("内置硬盘", ssdName)) }
            if let smart = str(deep(st, ["smart_status"])) {
                rows.append(("磁盘 SMART", smart.localizedCaseInsensitiveContains("verified") ? "Verified ✓（正常）" : smart))
            }

            let (rc, profOut) = Shell.run("/usr/bin/profiles", ["status", "-type", "enrollment"])
            if rc == 0 {
                // 逐行解析「Enrolled via DEP: No」「MDM enrollment: No」——只看冒号后的值
                var enrolled = false
                for raw in profOut.split(separator: "\n") {
                    let line = String(raw).trimmingCharacters(in: .whitespaces)
                    guard line.localizedCaseInsensitiveContains("enroll") else { continue }
                    guard let colon = line.firstIndex(of: ":") ?? line.firstIndex(of: "：") else { continue }
                    let val = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces).lowercased()
                    if val.hasPrefix("yes") || val == "是" { enrolled = true }
                }
                rows.append(("MDM 监管", enrolled ? "⚠️ 已注册企业设备！" : "✓ 未注册（干净）"))
            } else {
                rows.append(("MDM 监管", "权限不足（终端：sudo profiles status -type enrollment）"))
            }

            DispatchQueue.main.async {
                self?.hardware = rows
                self?.collecting = false
            }
        }
    }
}

// MARK: - 验机项目表（原创文案）

enum VerifyCatalog {
    struct Section: Identifiable { let id = UUID(); let title: String; let icon: String; let items: [VerifyItem] }

    static let sections: [Section] = [
        Section(title: "安全与身份", icon: "lock.shield.fill", items: [
            VerifyItem(id: "activation-lock", required: true, title: "激活锁已解除",
                       guide: "系统设置 › Apple 账户 › iCloud › 查找：确认「查找我的 Mac」已关闭；让卖家当面执行「抹掉所有内容和设置」，重启后设置助理不再索要前机主密码才算真正解锁。右侧硬件快照也会自动读取系统激活锁状态辅助核对。带激活锁的机器绝对不能付款。"),
            VerifyItem(id: "mdm", required: true, title: "无 MDM 企业监管",
                       guide: "右侧「MDM 监管」为自动核验结果；抹机后首联网出现「远程管理」页 = 企业监管机，不要购买。"),
            VerifyItem(id: "serial-match", required: true, title: "序列号三处一致",
                       guide: "比对 系统设置›关于本机、机身底壳刻印、包装盒标签 三处序列号（右侧已自动读出系统侧序列号）。部分新机型无底壳刻印属正常。"),
            VerifyItem(id: "service-history", required: true, title: "维修历史核验",
                       guide: "系统设置 › 通用 › 关于本机 › 部件与维修：查看是否更换过屏幕/电池、配件是否为正品 Apple 部件；无该入口一般代表无维修记录。"),
            VerifyItem(id: "diagnostics", required: true, title: "Apple 诊断（ADP000）",
                       guide: "关机并拔掉全部外设：Apple Silicon 长按电源进启动选项后按 ⌘D；Intel 开机按住 D。结束出现 ADP000 = 未发现问题，其他代码逐条向卖家追问。"),
        ]),
        Section(title: "屏幕", icon: "display", items: [
            VerifyItem(id: "dead-pixel", required: true, interactive: true, title: "全屏坏点检测",
                       guide: "黑/白/红/绿/蓝逐色找固定亮点、暗点与色斑；空格换色，Esc 退出。"),
            VerifyItem(id: "screen-original", required: true, title: "原装屏核验",
                       guide: "先看「部件与维修」；检查 True Tone 与自动亮度——应支持却没有基本是换过非原装屏，再看四周边框有无撬压痕迹。"),
            VerifyItem(id: "backlight", title: "漏光检测",
                       guide: "暗环境、纯黑壁纸、亮度拉满观察四边四角；轻微均匀泛光正常，局部喷溅状亮斑异常。"),
            VerifyItem(id: "coating", title: "镀膜检查",
                       guide: "斜角光下轻擦屏幕，查看防反射膜有无脱落起皮/彩虹纹。"),
            VerifyItem(id: "brightness", title: "亮度与感光",
                       guide: "F1/F2 全行程；遮挡光感应区自动亮度应明显变化。"),
        ]),
        Section(title: "输入设备", icon: "keyboard.fill", items: [
            VerifyItem(id: "keyboard", required: true, interactive: true, title: "键盘全键测试",
                       guide: "在弹出画布内点击取得焦点后按下每个键（含功能键），实时点亮并计数；不触发/串键即故障。"),
            VerifyItem(id: "trackpad", required: true, interactive: true, title: "触控板全域画布",
                       guide: "在弹出画布上单指连续画圈与四角直线：跟手、无断线；再测双指滚动与用力点按。"),
            VerifyItem(id: "touchid", title: "Touch ID 指纹",
                       guide: "系统设置 › Touch ID 录入一枚新指纹并实际解锁，应一次成功。"),
        ]),
        Section(title: "音频与影像", icon: "waveform", items: [
            VerifyItem(id: "speakers", required: true, interactive: true, title: "扬声器左右声道",
                       guide: "依次播放 左→中→右 扫频音：定位清晰、无破音异响。"),
            VerifyItem(id: "mic", required: true, interactive: true, title: "麦克风录放",
                       guide: "录制 5 秒后自动回放；首次使用会请求麦克风权限。"),
            VerifyItem(id: "camera", required: true, interactive: true, title: "摄像头预览",
                       guide: "查看实时画面：清晰、无横纹黑块；首次使用会请求摄像头权限。"),
        ]),
        Section(title: "端口与无线", icon: "cable.connector", items: [
            VerifyItem(id: "usb-c", required: true, title: "USB-C / 雷电端口",
                       guide: "每口分别：插 U 盘读文件 + 外接显示器 + 充电；需调整角度才通电 = 松旷。"),
            VerifyItem(id: "magsafe", title: "MagSafe 充电",
                       guide: "自动吸附亮灯并稳定充电，轻碰不中断。"),
            VerifyItem(id: "wifi-bt", required: true, title: "Wi-Fi 与蓝牙",
                       guide: "连 Wi-Fi 看信号并测速；MetriBar 心率链路即现成的蓝牙连通性验证。"),
        ]),
        Section(title: "机身与散热", icon: "checkmark.seal.fill", items: [
            VerifyItem(id: "hinge", required: true, title: "转轴开合",
                       guide: "反复开合 10 次：阻尼均匀无异响，任意角度可悬停。"),
            VerifyItem(id: "liquid", required: true, title: "进液痕迹",
                       guide: "手电检查各端口触点绿锈/白渍与变色指示；进液机坚决不买。"),
            VerifyItem(id: "chassis", title: "外观结构",
                       guide: "侧光检查 C 面平整度、屏幕压痕亮斑、四角磕碰、壳缝均匀。"),
            VerifyItem(id: "fan-load", title: "满载散热",
                       guide: "跑 2 分钟负载：风扇平稳起转无金属摩擦声；实时转速回主面板观察。"),
        ]),
    ]

    static var items: [VerifyItem] { sections.flatMap(\.items) }
}

// MARK: - 验机 Tab UI（卡片式，与打印机 Tab 统一视觉）

struct InlineTestID: Identifiable { let id: String }

struct VerifyTab: View {
    @StateObject private var model = VerifyModel()
    @State private var inlineSheet: InlineTestID?   // "keyboard" / "trackpad"

    private let cols = [GridItem(.adaptive(minimum: 210, maximum: 260), spacing: 14)]

    var body: some View {
        HSplitView {
            checklistColumn.frame(minWidth: 470, idealWidth: 560, minHeight: 480)
            hardwareColumn.frame(minWidth: 320, idealWidth: 380, minHeight: 480)
        }
        .onAppear { if model.hardware.isEmpty { model.collectHardware() } }
        .sheet(item: $inlineSheet) { s in inlineSheetContent(s.id) }
    }

    private var checklistColumn: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                ProgressView(value: Double(model.requiredDone), total: Double(max(model.requiredTotal, 1)))
                    .frame(maxWidth: 240)
                Text("必查 \(model.requiredDone)/\(model.requiredTotal)")
                    .font(.system(size: 11, weight: .semibold)).foregroundColor(.secondary)
                Spacer()
                Button("重置") { model.reset() }.controlSize(.small)
            }
            .padding(.horizontal, 14).padding(.vertical, 9)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    ForEach(VerifyCatalog.sections) { section in
                        VStack(alignment: .leading, spacing: 8) {
                            Label(section.title, systemImage: section.icon).font(.system(size: 13, weight: .bold))
                            LazyVGrid(columns: cols, spacing: 12) {
                                ForEach(section.items) { card($0) }
                            }
                        }
                    }
                }
                .padding(14)
            }
        }
    }

    private func card(_ item: VerifyItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Circle().fill(dotColor(item.id)).frame(width: 7, height: 7)
                Text(item.title).font(.system(size: 13, weight: .semibold)).lineLimit(2)
                Spacer()
            }
            HStack(spacing: 5) {
                if item.required { badge("必查", Color.red.opacity(0.12), .red) }
                if item.interactive { badge("交互", Color.accentColor.opacity(0.12), .accentColor) }
                Spacer()
            }
            Text(item.guide).font(.system(size: 10)).foregroundColor(.secondary)
                .lineLimit(3).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                if item.interactive {
                    Button("开始") {
                        if item.id == "keyboard" || item.id == "trackpad" { inlineSheet = InlineTestID(id: item.id) }
                        else { VerifyTests.launch(item.id) }
                    }
                    .controlSize(.small)
                }
                Spacer()
                Button("通过") { model.set(item.id, .pass) }
                    .buttonStyle(.bordered).controlSize(.regular)
                    .tint(model.state(item.id) == .pass ? .green : .secondary)
                Button("不通过") { model.set(item.id, .fail) }
                    .buttonStyle(.bordered).controlSize(.regular)
                    .tint(model.state(item.id) == .fail ? .red : .secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.045)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
    }

    private func badge(_ text: String, _ bg: Color, _ fg: Color) -> some View {
        Text(text).font(.system(size: 9, weight: .medium))
            .padding(.horizontal, 5).padding(.vertical, 1.5)
            .background(Capsule().fill(bg)).foregroundColor(fg)
    }

    private func dotColor(_ id: String) -> Color {
        switch model.state(id) { case .pass: return .green; case .fail: return .red; case .todo: return Color.secondary.opacity(0.4) }
    }

    @ViewBuilder
    private func inlineSheetContent(_ id: String) -> some View {
        VStack(spacing: 12) {
            Text(id == "keyboard" ? "键盘全键测试" : "触控板全域画布")
                .font(.system(size: 15, weight: .bold))
            Text(id == "keyboard" ? "点击测试区取得焦点，按下每个键——应实时点亮并计数。Esc 退出。" :
                                        "用单指连续画圈、直线覆盖四角与边缘：应跟手无断线。")
                .font(.system(size: 11)).foregroundColor(.secondary)
            Group {
                if id == "keyboard" { KeyboardTestView() } else { TrackpadCanvasView() }
            }
            .frame(width: 560, height: 220)
            Button("完成") { inlineSheet = nil }.keyboardShortcut(.cancelAction)
        }
        .padding(20).frame(width: 620)
    }

    private var hardwareColumn: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("本机硬件快照", systemImage: "cpu").font(.system(size: 13, weight: .bold))
                Spacer()
                Button { model.collectHardware() } label: { Image(systemName: "arrow.clockwise") }.disabled(model.collecting)
            }
            Divider()
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(Array(model.hardware.enumerated()), id: \.offset) { _, row in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(row.0).font(.system(size: 10, weight: .medium)).foregroundColor(.secondary)
                            Text(row.1).font(.system(size: 11, weight: .semibold)).textSelection(.enabled)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(9)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.045)))
                    }
                    if model.collecting {
                        HStack(spacing: 6) { ProgressView().controlSize(.small); Text("采集中…").font(.system(size: 10)).foregroundColor(.secondary) }
                            .frame(maxWidth: .infinity).padding(.vertical, 6)
                    }
                }
            }
            Text("仅本机只读命令 · 不联网").font(.system(size: 10)).foregroundColor(.secondary)
        }
        .padding(14)
    }
}

