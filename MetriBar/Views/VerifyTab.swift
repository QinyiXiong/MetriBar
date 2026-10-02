//
//  VerifyTab.swift
//  MetriBar
//
//  MacBook 验机：10 个板块的验机清单（板块与条目一一对应，每条带分步操作）；
//  清单结构、文案与步骤均为本项目原创整理。
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
    var steps: [String] = []      // 分步操作（对齐网站各检测页）
    var link: String? = nil       // 外部工具 / 官方页面
    var linkTitle: String? = nil
}

/// 常见问题（对齐网站 FAQ 七问）
struct VerifyFAQ: Identifiable {
    let id = UUID()
    let q: String
    let a: String
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
    var failCount: Int { VerifyCatalog.items.filter { state($0.id) == .fail }.count }

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

            // ── 电池详表：system_profiler + ioreg(AppleSmartBattery) 同源数据，
            //    与 coconutBattery 展示的字段一致，无需安装任何第三方 App ──
            let sp = prof("SPPowerDataType")
            let cycle = deep(sp, ["cycle_count"]) as? Int
            let health = str(deep(sp, ["battery_health"]) ?? deep(sp, ["health"]))
            let maxCap = str(deep(sp, ["health_maximum_capacity"]))
            let soc = (deep(sp, ["state_of_charge"]) as? NSNumber)?.intValue
            if cycle != nil || health != nil || maxCap != nil {
                var parts: [String] = []
                if let h = health, !h.isEmpty { parts.append("系统评估 \(h)") }
                if let mc = maxCap, !mc.isEmpty { parts.append("最大容量 \(mc)") }
                rows.append(("电池健康", parts.isEmpty ? "—" : parts.joined(separator: " · ")))
            } else {
                rows.append(("电池健康", "未检测到内置电池（台式机/无电池机型）"))
            }
            if let c = cycle { rows.append(("电池循环次数", "\(c) 次（机型标称寿命通常 1000 次）")) }

            let (rcIO, ioOut) = Shell.run("/usr/sbin/ioreg", ["-rn", "AppleSmartBattery"])
            if rcIO == 0 {
                func ioNum(_ key: String) -> Int? {
                    guard let r = ioOut.range(of: "\"\(key)\" = ") else { return nil }
                    let tail = ioOut[r.upperBound...]
                    let token = tail.prefix { $0.isNumber || $0 == "-" }
                    return Int(token)
                }
                func ioStr(_ key: String) -> String? {
                    guard let r = ioOut.range(of: "\"\(key)\" = \"") else { return nil }
                    let tail = ioOut[r.upperBound...]
                    guard let end = tail.firstIndex(of: "\"") else { return nil }
                    let v = String(tail[tail.startIndex..<end])
                    return v.isEmpty ? nil : v
                }
                let design = ioNum("DesignCapacity")
                let full = ioNum("NominalChargeCapacity") ?? ioNum("AppleRawMaxCapacity")
                if let d = design, let f = full, d > 0 {
                    let ratio = Double(f) / Double(d) * 100
                    rows.append(("电池容量", String(format: "满充 %d mAh / 设计 %d mAh（健康度 %.0f%%）", f, d, ratio)))
                }
                var power: [String] = []
                if let v = ioNum("Voltage") { power.append(String(format: "%.2f V", Double(v) / 1000)) }
                if let a = ioNum("Amperage") { power.append("\(a) mA") }
                if let t = ioNum("Temperature"), t > 0 { power.append(String(format: "%.1f ℃", Double(t) / 100)) }
                if !power.isEmpty { rows.append(("电池电压/电流/温度", power.joined(separator: " · "))) }
                var ids: [String] = []
                if let sn = ioStr("Serial") { ids.append(sn) }
                if let dn = ioStr("DeviceName") { ids.append(dn) }
                if !ids.isEmpty { rows.append(("电池序列号 / 型号", ids.joined(separator: " · "))) }
                let charging = ioNum("IsCharging") == 1
                let full2 = ioNum("FullyCharged") == 1
                let ext = ioStr("ExternalConnected").map { $0.lowercased() == "yes" } ?? false
                rows.append(("电池充电状态", (ext ? "接电源" : "电池供电")
                             + (full2 ? " · 已充满" : charging ? " · 正在充电" : " · 未充电")))
            }

            let (_, battPct) = Shell.run("/bin/bash", ["-lc", "/usr/bin/pmset -g batt"])
            let pctToken = battPct.split(whereSeparator: { " \t\n();;'\u{ff08}\u{ff09}".contains($0) })
                .first(where: { $0.hasSuffix("%") && $0.dropLast().allSatisfy(\.isNumber) })
            if let pct = pctToken {
                let ac = battPct.localizedCaseInsensitiveContains("AC Power") || battPct.contains("交流")
                rows.append(("电池当前电量", String(pct) + (ac ? " · 接电源" : " · 电池供电")
                             + (soc != nil ? "（系统读数 \(soc!)%）" : "")))
            }
            let (_, pmsetFull) = Shell.run("/usr/bin/pmset", ["-g", "custom"])
            let lowPower = pmsetFull.contains("lowpowermode         1")
            rows.append(("电源模式", lowPower ? "低电量模式已开启" : "标准模式"))

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

// MARK: - 验机项目表（板块与条目结构，文案原创）

enum VerifyCatalog {
    struct Section: Identifiable { let id = UUID(); let title: String; let icon: String; let items: [VerifyItem] }

    static let sections: [Section] = [
        Section(title: "拍摄开箱视频", icon: "video.fill", items: [
            VerifyItem(id: "unbox-video", required: true, title: "拍摄开箱视频",
                       guide: "接触包装前就开始录像，直到开机前不要停：拍清盒子六个面、纸质拉条、盒上序列号并核对机身一致。",
                       steps: [
                        "开封前开始录制：在接触包装之前就开录，清晰展示密封状态与包装盒六个面。",
                        "检查包装完整性：约 2022 年起的较新包装已无塑封膜、改为纸质拉条，确认拉条或塑封完好、无二次封装痕迹。",
                        "记录序列号：清晰拍摄盒上序列号，开箱后与机身序列号对比——必须完全一致。",
                        "核对配件清单：电源适配器功率、充电线与说明文档是否符合 Apple 官方规格。",
                        "一镜到底不中断：全程不要停止录制，口述观察内容可增加视频可信度。",
                        "保留原始未剪辑视频，作为退换货或维权凭证。",
                       ]),
        ]),
        Section(title: "安全检查", icon: "lock.shield.fill", items: [
            VerifyItem(id: "activation-lock", required: true, title: "激活锁检测",
                       guide: "确认「查找我的 Mac」已关闭，抹机后不再索要前机主 Apple 账户密码。",
                       steps: [
                        "系统设置 › Apple 账户 › iCloud › 查找：确认「查找我的 Mac」已关闭。",
                        "让卖家当面执行「抹掉所有内容和设置」，重启进入设置助理。",
                        "设置助理若仍要求输入前机主 Apple 账户密码 = 激活锁未解除，绝对不能付款。",
                        "右侧硬件快照已自动读取系统激活锁状态，可辅助核对。",
                       ]),
            VerifyItem(id: "mdm", required: true, title: "MDM 企业锁检测",
                       guide: "终端核验 + 抹机后联网复验，出现「远程管理」页即为企业监管机。",
                       steps: [
                        "终端执行：profiles status -type enrollment，两行都显示 No 才正常。",
                        "更可靠的方法：抹机后联网进入设置助理，若出现「远程管理」页面即为企业注册机。",
                        "企业监管机可能被远程锁定或抹除，不要购买；右侧快照已自动核验一次。",
                       ]),
            VerifyItem(id: "serial-match", required: true, title: "序列号核对",
                       guide: "系统、机身底壳、包装盒三处序列号必须完全一致。",
                       steps: [
                        "系统设置 › 通用 › 关于本机：读出序列号（右侧快照也已自动读取）。",
                        "与机身底部刻印比对（若底壳更换过则无刻印，需追问原因）。",
                        "与包装盒标签比对，三处一致才算通过。",
                        "再到 Apple「检查覆盖范围」页面输入序列号，核对机型与保修状态是否匹配。",
                       ],
                       link: "https://checkcoverage.apple.com/", linkTitle: "Apple 保修状态查询"),
            VerifyItem(id: "service-history", required: true, title: "维修历史与配件核验",
                       guide: "「部件与维修」查看是否换过屏幕/电池，配件是否正品 Apple 部件。",
                       steps: [
                        "系统设置 › 通用 › 关于本机 › 部件与维修：查看维修记录。",
                        "部件会标注「正品 Apple 部件 / 二手 Apple 部件 / 未知或未验证」。",
                        "该入口只在检测到维修时显示；没有入口一般说明无维修记录。",
                        "出现未说明的换屏、换电池记录需向卖家追问，或直接放弃。",
                       ]),
            VerifyItem(id: "diagnostics", required: true, title: "诊断模式（ADP000）",
                       guide: "关机拔外设后进诊断模式，参考代码 ADP000 表示未发现问题。",
                       steps: [
                        "关机：完全关闭 MacBook；运行前断开所有外部设备，仅保留键盘、鼠标、显示器、以太网与电源适配器。",
                        "启动诊断 · Apple 芯片：按住电源键直到看到启动选项，然后按 Command (⌘) + D。",
                        "启动诊断 · Intel 芯片：开机后立即按住 D；如果无效，再尝试 Option (⌥) + D。",
                        "按提示操作：依系统版本可能先要求选择语言，或选择要运行的检测项目。",
                        "查看结果：记录参考代码（ADP000 = 未发现问题），其他代码即对应硬件故障，逐条向卖家追问，然后按屏幕选项重启或关机。",
                       ]),
        ]),
        Section(title: "屏幕检测", icon: "display", items: [
            VerifyItem(id: "dead-pixel", required: true, interactive: true, title: "坏点检测",
                       guide: "黑/白/红/绿/蓝逐色找固定亮点、暗点与色斑。",
                       steps: [
                        "点「开始」进入全屏纯色画面，空格或 → 切换颜色，Esc 退出。",
                        "逐色观察是否有固定不变的亮点（卡点）或黑点（坏点）。",
                        "再在全黑房间把亮度调到最高，看四角是否有明显漏光。",
                       ]),            VerifyItem(id: "coating", title: "屏幕镀膜检查",
                       guide: "轻擦屏幕，查看防反射镀膜是否脱落（2012–2019 款高发）。",
                       steps: [
                        "关闭屏幕，用超细纤维布轻擦屏幕表面。",
                        "斜角光线下观察是否有彩虹纹、起皮、脱落斑块。",
                        "主要影响 2012–2019 款机型，脱落面积大不建议购买。",
                       ]),            VerifyItem(id: "screen-pressure", title: "屏幕压力测试",
                       guide: "用无纺布轻压屏幕四角，观察是否出现黑斑。",
                       steps: [
                        "用无纺布或超细纤维布轻压屏幕四角与边缘。",
                        "观察是否出现黑斑、水波纹样扩散。",
                        "松手后应在数秒内完全恢复；出现永久暗斑说明屏幕已受损。",
                       ]),            VerifyItem(id: "screen-original", required: true, title: "原装屏幕核验",
                       guide: "查「部件与维修」+ True Tone/自动亮度是否可用 + 边框撬痕。",
                       steps: [
                        "macOS 26 及以上：系统设置 › 通用 › 关于本机 › 部件与维修，显示器出现在列表即换过屏（M5 及更新机型才记录显示屏）。",
                        "更早机型：看 True Tone 原彩显示与自动亮度是否可用——本应支持却没有，通常是非原装屏。",
                        "仔细观察屏幕四周边框有无撬压痕迹、胶痕、缝隙不均。",
                       ]),            VerifyItem(id: "backlight", title: "屏幕漏光检测",
                       guide: "暗环境下纯黑画面、亮度拉满，检查四边四角是否漏光。",
                       steps: [
                        "在全黑房间，显示纯黑画面（可用坏点检测的全屏黑）。",
                        "亮度调到最高，从正面与侧面观察四边四角。",
                        "轻微均匀的边缘泛光属正常；局部喷溅状亮斑属异常。",
                       ]),            VerifyItem(id: "brightness", title: "亮度检测",
                       guide: "测试最大/最小亮度与自动亮度传感器。",
                       steps: [
                        "用 F1 / F2 走完亮度全行程，观察是否有跳变或闪烁。",
                        "开启自动亮度，用手遮挡光感应区（屏幕上方），亮度应明显变化。",
                        "最高亮度下与同机型对比，明显偏暗说明背光老化。",
                       ]),

        ]),
        Section(title: "输入设备", icon: "keyboard.fill", items: [
            VerifyItem(id: "trackpad", interactive: true, title: "触控板检测",
                       guide: "绘制图案检查各区域跟踪与响应，再测双指滚动与用力点按。",
                       steps: [
                        "点「开始」在画布上单指连续画圈与四角直线：应跟手、无断线。",
                        "覆盖四个角与边缘，检查是否存在无响应区域。",
                        "再测双指滚动、三指拖动与用力点按（Force Touch）手感是否一致。",
                       ]),
            VerifyItem(id: "keyboard", interactive: true, title: "键盘全键测试",
                       guide: "内置拟真键盘画布：逐个按键实时点亮并计数，不触发或串键即为故障。",
                       steps: [
                        "点「开始」后在画布上按顺序敲击每个按键（含功能键与方向键）。",
                        "被按下的键应实时点亮并计数；未点亮的键即为不触发。",
                        "注意检查串键（按 A 亮 B）与连击。",
                       ],
                       link: nil, linkTitle: nil),
            VerifyItem(id: "touchid", title: "Touch ID 检测",
                       guide: "录入一枚新指纹并实际解锁，应一次成功。",
                       steps: [
                        "系统设置 › Touch ID 与密码：录入一枚新指纹。",
                        "锁屏后用该指纹解锁，应一次识别成功。",
                        "反复 5 次观察识别率，明显迟钝可能是传感器老化。",
                       ]),
        ]),
        Section(title: "音频检测", icon: "waveform", items: [
            VerifyItem(id: "speakers", required: true, interactive: true, title: "声音检测",
                       guide: "依次播放 左→中→右 提示音，定位清晰、无破音异响。",
                       steps: [
                        "点「开始」依次播放左 / 中 / 右三声提示音。",
                        "确认左右声道定位清晰、音量均衡、无破音与杂音。",
                        "播放一段熟悉的音乐，注意是否有共振、金属杂音。",
                       ],
                       link: nil, linkTitle: nil),
            VerifyItem(id: "mic", required: true, interactive: true, title: "麦克风检测",
                       guide: "录制并回放，检查内置麦克风是否正常。",
                       steps: [
                        "点「开始」录制约 5 秒，随后自动回放。",
                        "回放应清晰、无明显底噪或断续；首次使用会请求麦克风权限。",
                        "靠近左右麦克风孔说话分别测试，回放应有对应强弱。",
                       ]),
            VerifyItem(id: "camera", required: true, interactive: true, title: "摄像头检测",
                       guide: "查看实时画面：清晰、无横纹黑块。",
                       steps: [
                        "点「开始」打开实时预览窗口（首次会请求摄像头权限）。",
                        "画面应清晰、色彩正常、无横纹、黑块或彩点。",
                        "用手遮挡镜头再移开，观察曝光响应是否正常。",
                       ]),
        ]),
        Section(title: "端口与连接", icon: "cable.connector", items: [
            VerifyItem(id: "usb-c", title: "USB-C / 雷电端口检测",
                       guide: "每个口分别测数据传输、外接显示与充电，松旷即异常。",
                       steps: [
                        "每个 USB-C / 雷电口分别插入 U 盘，确认能正常读写文件。",
                        "接外接显示器或转接器，确认视频输出正常。",
                        "接充电器，确认充电指示与功率正常；需调整角度才通电 = 接口松旷。",
                       ]),            VerifyItem(id: "wifi-bt", title: "WiFi 与蓝牙检测",
                       guide: "连 Wi-Fi 看信号并测速，蓝牙配对设备验证。",
                       steps: [
                        "连接 Wi-Fi，检查信号强度与实测网速是否正常。",
                        "连接蓝牙耳机或键鼠，确认配对与音频/输入正常。",
                        "在多个位置移动，观察是否频繁掉线（天线故障征兆）。",
                       ]),
            VerifyItem(id: "magsafe", title: "MagSafe 充电检测",
                       guide: "测试磁吸对齐与充电稳定性。",
                       steps: [
                        "接上 MagSafe 磁吸头，应自动吸附并亮起充电指示灯。",
                        "轻轻碰动线缆，充电不应中断。",
                        "观察充电头与接口有无烧灼、发黑痕迹。",
                       ]),
        ]),
        Section(title: "机身与外观检查", icon: "checkmark.seal.fill", items: [
            VerifyItem(id: "hinge", title: "铰链 / 转轴检测",
                       guide: "反复开合 10 次：阻尼均匀无异响，任意角度可悬停。",
                       steps: [
                        "反复开合屏幕 10 次，感受阻尼是否均匀、有无异响。",
                        "把屏幕停在多个角度，应能稳定悬停不下坠。",
                        "单手握持机身晃动，屏幕不应自由翻转（转轴松动）。",
                       ]),
            VerifyItem(id: "liquid", required: true, title: "进水指示器检测",
                       guide: "LCI 接触液体由白变红；2016 年及以后机型 LCI 在主板与键盘面板上，不拆底壳看不到。",
                       steps: [
                        "了解 LCI：机内白色小圆点指示器，接触液体后变红；2016 年及之后机型位于键盘面板和主板，不拆底壳无法看到。",
                        "检查耳机孔（仅老机型）：用手电照 3.5mm 耳机孔可见 LCI——白色正常、红色进水；较新机型外部看不到。",
                        "检查端口残留：灯光照入 USB-C 等端口查看腐蚀、水渍圈或黏腻残留；老款 MagSafe 口周围是进水高发点。",
                        "检查腐蚀迹象：端口边缘、扬声器开孔与散热孔是否有白色/绿色残留。",
                        "如需拆底壳（卖家允许时）：关机断电 → 五角星 P5 螺丝刀拧下 8–10 颗螺丝（记录位置，长短不同）→ 从转轴一侧撬起掀开 → 在主板与键盘面板找 2–3mm 小纸点，白色正常、红色进水；切勿硬撬或触碰主板。",
                        "注意：进水会导致保修失效并留下间歇性故障；沿海潮湿环境极少数情况下 LCI 会因长期高湿度变红，需结合其他迹象判断。",
                       ]),
            VerifyItem(id: "chassis", title: "外壳检查",
                       guide: "检查机身是否有凹痕、划痕、裂缝或氧化。",
                       steps: [
                        "侧光检查 C 面（键盘面）是否平整，有无翘曲。",
                        "检查屏幕是否有键盘压痕、亮斑。",
                        "检查四角与边缘有无磕碰、掉漆，壳缝是否均匀。",
                       ]),
        ]),
        Section(title: "硬件状态", icon: "internaldrive", items: [
            VerifyItem(id: "ssd-health", title: "SSD 健康检测",
                       guide: "查看固态硬盘健康状态与剩余寿命（右侧快照已给出 SMART 与累计读写）。",
                       steps: [
                        "右侧「磁盘 SMART」为系统自动核验结果，Verified 即正常。",
                        "终端执行：diskutil info / | grep -i smart，确认为 Verified。",
                        "拷贝数 GB 大文件，观察速度是否稳定、是否掉盘。",
                       ]),
            VerifyItem(id: "fan-load", title: "风扇 / 散热检测",
                       guide: "检查风扇有无异响，负载时散热是否正常。",
                       steps: [
                        "跑 2 分钟高负载（编译、跑分或视频导出）。",
                        "靠近听风扇：应平稳起转，无金属摩擦声或哒哒异响。",
                        "触摸机身底部与键盘上方，温度应均匀上升而非局部烫手。",
                       ]),
        ]),
        Section(title: "外部工具", icon: "wrench.and.screwdriver.fill", items: [
            VerifyItem(id: "battery-tool", required: true, title: "电池检测",
                       guide: "右侧「本机硬件快照」已直接读出全部电池数据：健康度、循环次数、设计/满充容量、电压电流温度、序列号，无需安装任何第三方 App。",
                       steps: [
                        "看右侧快照「电池健康」「电池循环次数」「电池容量」三行：健康度 = 满充容量 / 设计容量。",
                        "循环次数对比机型标称寿命（通常 1000 次），过高说明重度使用；健康度低于 80% 通常需更换电池。",
                        "「电池充电状态」应随插拔电源实时变化：接电源显示充电/已充满，拔掉显示电池供电。",
                        "如需交叉验证：系统设置 › 电池 › 电池健康，与右侧读数对照应一致。",
                       ]),
            VerifyItem(id: "serial-query", required: true, title: "序列号查询（保修核验）",
                       guide: "到 Apple 官方页面输入序列号，验证保修状态与设备信息。",
                       steps: [
                        "打开 Apple「检查覆盖范围」页面（checkcoverage.apple.com）。",
                        "输入序列号，核对显示的机型、购买日期与保修/AppleCare 状态是否与卖家描述一致。",
                        "序列号无效、机型不符或显示已更换设备，都是高风险信号。",
                       ],
                       link: "https://checkcoverage.apple.com/", linkTitle: "打开 Apple 保修查询"),
            VerifyItem(id: "geekbench", title: "性能测试",
                       guide: "用 Geekbench 跑分对比同机型公开成绩。",
                       steps: [
                        "下载并安装 Geekbench（macOS 版）。",
                        "接电源、关闭后台程序，跑 CPU 单核/多核与 GPU 测试。",
                        "与同机型同配置的公开成绩对比，明显偏低说明散热或硬件异常。",
                       ],
                       link: "https://www.geekbench.com/download/", linkTitle: "下载 Geekbench"),
            VerifyItem(id: "av-quality", title: "音画质量测试",
                       guide: "检测扬声器与屏幕表现，建议到直营店对比体验。",
                       steps: [
                        "播放高质量音视频素材，检查音质、音量与画面色彩。",
                        "与直营店同型号样机对比，注意破音、偏色、亮度不均。",
                        "有条件时带自己的素材与耳机做 A/B 对比。",
                       ],
                       link: "https://www.bilibili.com/video/BV11f4y1K7Wx", linkTitle: "音画质量对照素材"),
            VerifyItem(id: "refresh-rate", title: "刷新率检测",
                       guide: "用 UFO Test 测试屏幕刷新率是否达标。",
                       steps: [
                        "打开 UFO Test（Display Refresh Rate Test）：看 Current / Average / Low / Max FPS 四项实时指标。",
                        "运动流畅度测试：方块应平滑移动，卡顿说明掉帧；滚动线条应平滑无撕裂或抖动。",
                        "对照预期：MacBook Pro 14/16 吋带 ProMotion 最高可达 120 FPS，其他 MacBook 通常显示 60 FPS；FPS 应保持稳定不剧烈波动。",
                        "ProMotion 不显示 120Hz 时排查：Safari 默认把页面渲染限制在 60 FPS——Develop 菜单 → Feature Flags，取消勾选 “Prefer Page Rendering Updates near 60fps” 后刷新页面。",
                        "再检查 系统设置 → 显示器 → 刷新率 是否设为 ProMotion；新版 Chrome 已支持 macOS 120Hz，若仍停在 60 可换浏览器复测。",
                       ],
                       link: "https://www.testufo.com/", linkTitle: "打开 UFO Test"),
        ]),
        Section(title: "最后一步：抹掉重装系统（最后做）", icon: "arrow.counterclockwise.circle.fill", items: [
            VerifyItem(id: "reinstall", required: true, title: "抹掉数据重装系统",
                       guide: "所有检查通过后最后再做；优先用系统自带抹掉功能，没有该选项才进恢复模式重装。",
                       steps: [
                        "备份数据：先用 Time Machine 或手动备份重要文件（此步会删除全部数据）。",
                        "优先用系统自带抹掉：macOS Monterey 及以上、Apple 芯片或带 T2 芯片机型，进入 系统设置 › 通用 › 传输或还原 › 抹掉所有内容与设置。",
                        "没有该选项时进恢复模式 · Apple 芯片：关机后按住电源键直到「正在载入启动选项」，点「选项」›「继续」。",
                        "没有该选项时进恢复模式 · Intel 芯片：重启后立即按住 Command (⌘) + R 直到出现苹果标志。",
                        "谨慎抹掉内置磁盘：在恢复模式打开「磁盘工具」，选 Macintosh HD；若有「抹掉卷组」优先用它，否则点「抹掉」并保持 APFS 格式。",
                        "重新安装 macOS：退出磁盘工具后选「重新安装 macOS」；卖机或送人则装完停在设置助理界面，不要登录自己的账号。",
                        "复验企业监管：重装后联网进入设置助理，出现「远程管理」页 = 企业监管机，立即退货；索要前机主 Apple 账户密码 = 激活锁仍在，立即退货。",
                       ]),
        ]),
    ]

    static var items: [VerifyItem] { sections.flatMap(\.items) }

    /// 常见问题（对齐网站 FAQ 七问）
    static let faqs: [VerifyFAQ] = [
        VerifyFAQ(q: "买二手 MacBook 付款前必须检查哪些项目？",
                  a: "先过账户与身份关：激活锁已解除、无 MDM 企业锁、序列号三处一致（系统/机身/包装）、「部件与维修」里没有未说明的维修记录、Apple 诊断跑出 ADP000。再看硬件硬伤：屏幕是否原装、有无进水痕迹、坏点、扬声器/麦克风/摄像头、电池健康。全部通过后最后抹盘重装。任一必查项不过都不要付款，其余键盘、接口、外壳等按需选做。"),
        VerifyFAQ(q: "怎么判断 MacBook 有没有激活锁？",
                  a: "系统设置 › 你的名字 › iCloud › 查找我的 Mac，确认已关闭且系统里不再显示前机主的 Apple 账户。最保险的做法是让卖家当面「抹掉所有内容和设置」，抹机后进入设置助理若不要求输入前机主密码，才算真正解锁。仍有激活锁的 Mac 绝对不能买。"),
        VerifyFAQ(q: "怎么检查 MacBook 是否被企业 MDM 管理？",
                  a: "在终端运行 profiles status -type enrollment，两行都显示 No 才正常。更可靠的方法是抹机后联网进入设置助理，出现「远程管理」页面就说明被企业注册监管，这类机器可能被远程锁定或抹除，不要购买。"),
        VerifyFAQ(q: "怎么判断 MacBook 屏幕是不是原装？",
                  a: "macOS 26 及以上先看 系统设置 › 通用 › 关于本机 › 部件与维修，显示器出现在列表里就是换过屏（M5 及更新机型才记录显示屏）。更早机型看 True Tone 原彩和自动亮度是否可用，本应支持却没有该选项通常就是换了非原装屏，再结合边框撬痕判断。"),
        VerifyFAQ(q: "MacBook 屏幕坏点怎么检测？",
                  a: "用坏点检测页全屏切换红、绿、蓝、白、黑纯色画面，逐色观察有没有固定不变的亮点或黑点。再在全黑房间把亮度调到最高看四角有无明显漏光，轻微均匀的边缘泛光属正常。"),
        VerifyFAQ(q: "怎么查看 MacBook 的维修记录？",
                  a: "macOS 26 及以上进入 系统设置 › 通用 › 关于本机 › 部件与维修，会列出检测到的维修并把部件标为正品 Apple 部件、二手 Apple 部件、未知或未验证。这个入口只在检测到维修时才显示，没有入口一般说明没有维修记录。"),
        VerifyFAQ(q: "这个验机工具要收费或安装软件吗？",
                  a: "不需要，也不用装任何第三方工具。所有检测（坏点、摄像头、麦克风、扬声器、键盘、触控板、刷新率）都由 MetriBar 在本机完成，不上传任何数据；硬件信息仅通过本机只读命令读取。"),
        VerifyFAQ(q: "怎么进入 Apple 诊断模式？",
                  a: "先关机并拔掉除电源外的所有外设。Apple 芯片机型按住电源键直到出现启动选项，再按 Command + D；Intel 机型开机后立即按住 D。参考代码 ADP000 表示未发现问题，其他代码即对应硬件故障。"),
    ]
}

// MARK: - 验机 Tab UI（卡片式，与打印机 Tab 统一视觉）

struct InlineTestID: Identifiable { let id: String }

struct VerifyTab: View {
    @StateObject private var model = VerifyModel()
    @State private var inlineSheet: InlineTestID?   // "keyboard" / "trackpad"
    @State private var detailSheet: VerifyItem?
    @State private var keyboardResetToken = 0

    private let cols = [GridItem(.adaptive(minimum: 210, maximum: 260), spacing: 14)]

    var body: some View {
        HSplitView {
            checklistColumn.frame(minWidth: 470, idealWidth: 560, minHeight: 480)
            hardwareColumn.frame(minWidth: 320, idealWidth: 380, minHeight: 480)
        }
        .onAppear { if model.hardware.isEmpty { model.collectHardware() } }
        .sheet(item: $inlineSheet) { s in inlineSheetContent(s.id) }
        .sheet(item: $detailSheet) { item in detailSheetContent(item) }
    }

    private var checklistColumn: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                ProgressView(value: Double(model.requiredDone), total: Double(max(model.requiredTotal, 1)))
                    .frame(maxWidth: 200)
                Text("必查 \(model.requiredDone)/\(model.requiredTotal)")
                    .font(.system(size: 11, weight: .semibold)).foregroundColor(.secondary)
                if model.failCount > 0 {
                    Text("· 不通过 \(model.failCount)").font(.system(size: 11, weight: .semibold)).foregroundColor(.red)
                }
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
                    faqSection
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
                if !item.steps.isEmpty {
                    Button("步骤") { detailSheet = item }.controlSize(.small)
                }
                if let link = item.link, let url = URL(string: link) {
                    Button("打开") { NSWorkspace.shared.open(url) }
                        .controlSize(.small)
                        .help(item.linkTitle ?? link)
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

    private var faqSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("常见问题", systemImage: "questionmark.circle.fill").font(.system(size: 13, weight: .bold))
            VStack(alignment: .leading, spacing: 6) {
                ForEach(VerifyCatalog.faqs) { f in
                    DisclosureGroup {
                        Text(f.a).font(.system(size: 10)).foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 4).padding(.leading, 2)
                    } label: {
                        Text(f.q).font(.system(size: 11, weight: .medium))
                    }
                    .padding(9)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.035)))
                }
            }
        }
    }

    private func badge(_ text: String, _ bg: Color, _ fg: Color) -> some View {
        Text(text).font(.system(size: 9, weight: .medium))
            .padding(.horizontal, 5).padding(.vertical, 1.5)
            .background(Capsule().fill(bg)).foregroundColor(fg)
    }

    private func dotColor(_ id: String) -> Color {
        switch model.state(id) { case .pass: return .green; case .fail: return .red; case .todo: return Color.secondary.opacity(0.4) }
    }

    /// 分步操作详情（对齐网站各检测页说明）
    func detailSheetContent(_ item: VerifyItem) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(item.title).font(.system(size: 18, weight: .bold))
                if item.required { badge("必查", Color.red.opacity(0.12), .red) }
                Spacer()
                Text("操作步骤 \(item.steps.count) 步").font(.system(size: 11)).foregroundColor(.secondary)
            }
            Text(item.guide).font(.system(size: 13)).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(item.steps.enumerated()), id: \.offset) { i, step in
                        HStack(alignment: .top, spacing: 10) {
                            Text("\(i + 1)")
                                .font(.system(size: 12, weight: .bold)).foregroundColor(.white)
                                .frame(width: 22, height: 22)
                                .background(Circle().fill(Color.accentColor))
                            Text(step).font(.system(size: 13.5))
                                .lineSpacing(3)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                    }
                }
                .padding(.trailing, 6)
            }
            HStack {
                if let link = item.link, let url = URL(string: link) {
                    Button(item.linkTitle ?? "打开链接") { NSWorkspace.shared.open(url) }.controlSize(.small)
                }
                Spacer()
                Button("通过") { model.set(item.id, .pass); detailSheet = nil }.controlSize(.small).tint(.green)
                Button("不通过") { model.set(item.id, .fail); detailSheet = nil }.controlSize(.small).tint(.red)
                Button("关闭") { detailSheet = nil }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(22).frame(width: 660, height: 540)
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
                if id == "keyboard" { KeyboardTestView(resetToken: keyboardResetToken).frame(maxWidth: .infinity, minHeight: 280, maxHeight: 320) } else { TrackpadCanvasView() }
            }
            .frame(width: id == "keyboard" ? 880 : 560, height: id == "keyboard" ? 290 : 220)
            HStack(spacing: 10) {
                if id == "keyboard" { Button("重置") { keyboardResetToken += 1 }.controlSize(.small) }
                Spacer()
                Button("完成") { inlineSheet = nil }.keyboardShortcut(.cancelAction)
            }
            .frame(width: id == "keyboard" ? 880 : 560)
        }
        .padding(20).frame(width: id == "keyboard" ? 940 : 620)
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
