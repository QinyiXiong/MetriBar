//
//  VerifyTab.swift
//  MetriBar
//
//  MacBook 验机：原生复刻「必查清单 + 交互检测 + 硬件快照」的完整工作流，
//  文案原创。清单进度持久化在 UserDefaults；硬件快照全部本机只读命令采集，
//  不联网。交互测试由本文件与 VerifyTests.swift 承载。
//

import SwiftUI
import Combine

// MARK: - 数据模型

struct VerifyItem: Identifiable, Equatable {
    enum State: Int { case todo = 0, pass = 1, fail = 2 }
    let id: String
    var required: Bool = false
    var interactive: Bool = false   // 有 App 内交互测试可一键启动
    let title: String
    let guide: String          // 原创操作指引
}

@MainActor
final class VerifyModel: ObservableObject {
    @Published var states: [String: Int] = [:]
    @Published var hardware: [String: String] = [:]
    @Published var collecting = false

    private let defaultsKey = "verify.checklist.v1"

    init() {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let saved = try? JSONDecoder().decode([String: Int].self, from: data) { states = saved }
    }

    func state(_ id: String) -> VerifyItem.State {
        VerifyItem.State(rawValue: states[id] ?? 0) ?? .todo
    }

    func set(_ id: String, _ st: VerifyItem.State) {
        states[id] = st.rawValue
        persist()
    }

    func reset() { states.removeAll(); persist() }

    private func persist() {
        if let data = try? JSONEncoder().encode(states) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }

    var requiredTotal: Int { VerifyCatalog.items.filter(\.required).count }
    var requiredDone: Int { VerifyCatalog.items.filter { $0.required && state($0.id) != .todo }.count }

    // MARK: 硬件快照（全部本机只读，不联网）

    func collectHardware() {
        // 同 PrinterModel：onAppear 事务内不要直接改 @Published
        DispatchQueue.main.async { [weak self] in self?.collecting = true }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var info: [String: String] = [:]
            func grab(_ path: String, _ args: [String]) -> String {
                Shell.run(path, args).1.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            func reGroup(_ s: String, _ key: String) -> String? {
                guard let r = s.range(of: "\"\(key)\" = \"?([^\",]+)\"?", options: .regularExpression) else { return nil }
                return s[r].components(separatedBy: " = ").last?.replacingOccurrences(of: "\"", with: "")
            }
            info["型号"] = grab("/usr/sbin/sysctl", ["-n", "hw.model"])
            let cores = grab("/usr/sbin/sysctl", ["-n", "hw.ncpu"])
            let memBytes = Int(grab("/usr/sbin/sysctl", ["-n", "hw.memsize"])) ?? 0
            info["CPU · 内存"] = "\(cores) 核 · \(memBytes / 1_073_741_824) GB"
            let plat = grab("/usr/sbin/ioreg", ["-c", "IOPlatformExpertDevice", "-d", "2"])
            info["序列号"] = reGroup(plat, "IOPlatformSerialNumber") ?? "读取失败"
            info["系统版本"] = grab("/usr/bin/sw_vers", ["-productVersion"])
            let batt = grab("/usr/sbin/ioreg", ["-rn", "-d", "1", "-c", "AppleSmartBattery"])
            if let cycle = reGroup(batt, "CycleCount") {
                let design = Int(reGroup(batt, "DesignCapacity") ?? "") ?? 0
                let cur = Int(reGroup(batt, "AppleRawCurrentCapacity") ?? reGroup(batt, "MaxCapacity") ?? "") ?? design
                let health = design > 0 ? Int((Double(cur) / Double(design) * 100).rounded()) : 0
                info["电池"] = health > 0 ? "循环 \(cycle) 次 · 健康 ≈\(health)%" : "循环 \(cycle) 次"
            } else {
                info["电池"] = "未检测到内置电池（台式机/新结构）"
            }
            if let attrs = try? FileManager.default.attributesOfFileSystem(forPath: "/"),
               let totalN = attrs[FileAttributeKey("NSFileSystemSize")] as? NSNumber,
               let freeN = attrs[FileAttributeKey("NSFileSystemFreeSpace")] as? NSNumber {
                let total = totalN.int64Value, free = freeN.int64Value
                info["磁盘"] = String(format: "%.0f%% 已用 · 可用 %.0f GB / %.2f TB",
                                      Double(total - free) / Double(total) * 100, Double(free) / 1e9, Double(total) / 1e12)
            }
            let (rc, prof) = Shell.run("/usr/bin/profiles", ["status", "-type", "enrollment"])
            if rc == 0, prof.localizedCaseInsensitiveContains("not enrolled") { info["MDM 监管"] = "未注册 ✓" }
            else if rc == 0 { info["MDM 监管"] = prof.replacingOccurrences(of: "\n", with: " / ") }
            else { info["MDM 监管"] = "权限不足（终端：sudo profiles status -type enrollment）" }

            DispatchQueue.main.async {
                self?.hardware = info
                self?.collecting = false
            }
        }
    }
}

// MARK: - 验机项目表（原创文案，复刻完整流程）

enum VerifyCatalog {
    struct Section: Identifiable { let id = UUID(); let title: String; let icon: String; let items: [VerifyItem] }

    static let sections: [Section] = [
        Section(title: "安全与身份", icon: "lock.shield.fill", items: [
            VerifyItem(id: "activation-lock", required: true, title: "激活锁已解除",
                       guide: "系统设置 › Apple 账户 › iCloud › 查找：确认「查找我的 Mac」已关闭；让卖家当面执行「抹掉所有内容和设置」，重启后设置助理不再索要前机主密码才算真正解锁。带激活锁的机器绝对不能付款。"),
            VerifyItem(id: "mdm", required: true, title: "无 MDM 企业监管",
                       guide: "右侧硬件快照已自动读取注册状态；也可终端执行 `profiles status -type enrollment`，两行都应为未注册。抹机后首联网出现「远程管理」页 = 企业监管机，不要购买。"),
            VerifyItem(id: "serial-match", required: true, title: "序列号三处一致",
                       guide: "比对 系统设置›关于本机、机身底壳刻印、包装盒标签 三处序列号完全一致（部分新机型无底壳刻印属正常）。"),
            VerifyItem(id: "service-history", required: true, title: "维修历史核验",
                       guide: "系统设置 › 通用 › 关于本机 › 部件与维修：查看是否更换过屏幕/电池、配件是否为正品 Apple 部件；没有该入口一般代表无维修记录。"),
            VerifyItem(id: "diagnostics", required: true, title: "Apple 诊断（ADP000）",
                       guide: "关机并拔掉全部外设：Apple Silicon 长按电源进启动选项后按 ⌘D；Intel 开机按住 D。结束出现 ADP000 = 未发现问题，其他代码逐条向卖家追问。"),
        ]),
        Section(title: "屏幕", icon: "display", items: [
            VerifyItem(id: "dead-pixel", required: true, interactive: true, title: "全屏坏点检测",
                       guide: "点「开始」进入全屏纯色循环（黑/白/红/绿/蓝），逐色找固定亮点、暗点与色斑；空格换色，Esc 退出。"),
            VerifyItem(id: "screen-original", required: true, title: "原装屏核验",
                       guide: "先看「部件与维修」；旧机型检查 True Tone 与自动亮度是否可用——应支持却没有基本是换过非原装屏，再看四周边框有无撬压痕迹。"),
            VerifyItem(id: "backlight", title: "漏光检测",
                       guide: "暗环境、纯黑壁纸、亮度拉满，观察四边四角；轻微均匀边缘泛光正常，局部喷溅状亮斑异常。"),
            VerifyItem(id: "coating", title: "镀膜检查",
                       guide: "斜角光照下轻擦屏幕，查看防反射膜有无脱落起皮/彩虹纹（多见于 2012–2019 款）。"),
            VerifyItem(id: "brightness", title: "亮度与感光",
                       guide: "F1/F2 拉满到最暗测试全行程；遮挡光感应区自动亮度应明显变化。"),
        ]),
        Section(title: "输入设备", icon: "keyboard.fill", items: [
            VerifyItem(id: "keyboard", required: true, interactive: true, title: "键盘全键测试",
                       guide: "展开后在按键区按下每个键（含功能键），键帽实时点亮并计数；任何不触发或串键都是故障。"),
            VerifyItem(id: "trackpad", required: true, interactive: true, title: "触控板全域画布",
                       guide: "展开后在画布上用单指连续画圈与四角直线：应跟手、无断线；再试双指滚动与用力点按。"),
            VerifyItem(id: "touchid", title: "Touch ID 指纹",
                       guide: "系统设置 › Touch ID 录入一枚新指纹并实际解锁验证，应一次成功。"),
        ]),
        Section(title: "音频与影像", icon: "waveform", items: [
            VerifyItem(id: "speakers", required: true, interactive: true, title: "扬声器左右声道",
                       guide: "点「开始」依次播放 左→中→右 扫频音：定位清晰、无破音异响。"),
            VerifyItem(id: "mic", required: true, interactive: true, title: "麦克风录放",
                       guide: "点「录制」对内置麦克风说话 5 秒，随后自动回放；首次使用会请求麦克风权限。"),
            VerifyItem(id: "camera", required: true, interactive: true, title: "摄像头预览",
                       guide: "点「开摄像头」查看实时画面：清晰、无横纹黑块；首次使用会请求摄像头权限。"),
        ]),
        Section(title: "端口与无线", icon: "cable.connector", items: [
            VerifyItem(id: "usb-c", required: true, title: "USB-C / 雷电端口",
                       guide: "每个口分别：插 U 盘读一次文件 + 外接显示器点亮 + 接入充电，三口全测；需调整角度才通电 = 端口松旷。"),
            VerifyItem(id: "magsafe", title: "MagSafe 充电",
                       guide: "磁吸自动吸附并稳定充电，轻碰不中断供电。"),
            VerifyItem(id: "wifi-bt", required: true, title: "Wi-Fi 与蓝牙",
                       guide: "连 Wi-Fi 看信号满格并测速；用 MetriBar 心率链路即现成的蓝牙连通性验证。"),
        ]),
        Section(title: "机身与散热", icon: "checkmark.seal.fill", items: [
            VerifyItem(id: "hinge", required: true, title: "转轴开合",
                       guide: "反复开合 10 次：阻尼均匀无异响，任意角度可悬停不点头。"),
            VerifyItem(id: "liquid", required: true, title: "进液痕迹",
                       guide: "手电检查各端口内部触点有无绿锈/白渍与变色指示；进液机坚决不买。部分新机型指示剂在机内，需售后拆检确认。"),
            VerifyItem(id: "chassis", title: "外观结构",
                       guide: "侧光检查 C 面平整度、屏幕无压痕亮斑、四角无磕碰、壳缝均匀。"),
            VerifyItem(id: "fan-load", title: "满载散热",
                       guide: "跑 2 分钟编译/导出负载：风扇平稳起转无金属摩擦声；实时转速可回 MetriBar 主面板观察。"),
        ]),
    ]

    static var items: [VerifyItem] { sections.flatMap(\.items) }
}

// MARK: - 验机 Tab UI

struct VerifyTab: View {
    @StateObject private var model = VerifyModel()
    @State private var expanded: Set<String> = []

    var body: some View {
        HSplitView {
            checklistColumn.frame(minWidth: 430, idealWidth: 500, minHeight: 480)
            hardwareColumn.frame(minWidth: 320, idealWidth: 380, minHeight: 480)
        }
        .onAppear { if model.hardware.isEmpty { model.collectHardware() } }
    }

    private var checklistColumn: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                ProgressView(value: Double(model.requiredDone), total: Double(max(model.requiredTotal, 1)))
                    .frame(maxWidth: 260)
                Text("必查 \(model.requiredDone)/\(model.requiredTotal)")
                    .font(.system(size: 11, weight: .semibold)).foregroundColor(.secondary)
                Spacer()
                Button("重置清单") { model.reset() }.controlSize(.small)
            }
            .padding(.horizontal, 14).padding(.vertical, 9)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(VerifyCatalog.sections) { section in
                        VStack(alignment: .leading, spacing: 7) {
                            Label(section.title, systemImage: section.icon).font(.system(size: 13, weight: .bold))
                            ForEach(section.items) { itemView($0) }
                        }
                    }
                }
                .padding(14)
            }
        }
    }

    private func itemView(_ item: VerifyItem) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Circle().fill(dotColor(item.id)).frame(width: 7, height: 7)
                Text(item.title).font(.system(size: 12, weight: .medium))
                if item.required {
                    Text("必查").font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(Color.red.opacity(0.12))).foregroundColor(.red)
                }
                Spacer()
                if item.interactive {
                    Button("开始") { VerifyTests.launch(item.id) }.controlSize(.small)
                }
                Button { model.set(item.id, .pass) } label: {
                    Image(systemName: model.state(item.id) == .pass ? "checkmark.circle.fill" : "checkmark.circle")
                }.buttonStyle(.plain).foregroundColor(model.state(item.id) == .pass ? .green : .secondary)
                Button { model.set(item.id, .fail) } label: {
                    Image(systemName: model.state(item.id) == .fail ? "xmark.circle.fill" : "xmark.circle")
                }.buttonStyle(.plain).foregroundColor(model.state(item.id) == .fail ? .red : .secondary)
            }
            DisclosureGroup {
                Text(item.guide).font(.system(size: 11)).foregroundColor(.secondary)
                    .textSelection(.enabled).padding(.vertical, 4)
                if item.id == "keyboard" { KeyboardTestView().frame(height: 150).padding(.top, 4) }
                if item.id == "trackpad" { TrackpadCanvasView().frame(height: 150).padding(.top, 4) }
            } label: {
                Text("怎么做").font(.system(size: 10)).foregroundColor(.secondary)
            }
        }
        .padding(9)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.045)))
    }

    private func dotColor(_ id: String) -> Color {
        switch model.state(id) { case .pass: return .green; case .fail: return .red; case .todo: return Color.secondary.opacity(0.4) }
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
                VStack(spacing: 0) {
                    ForEach(Array(model.hardware.keys.sorted()), id: \.self) { key in
                        VStack(spacing: 0) {
                            HStack(alignment: .top) {
                                Text(key).font(.system(size: 11)).foregroundColor(.secondary)
                                    .frame(width: 96, alignment: .leading)
                                Text(model.hardware[key] ?? "—").font(.system(size: 11, weight: .medium))
                                    .textSelection(.enabled)
                                Spacer()
                            }.padding(.vertical, 8)
                            Divider().opacity(0.4)
                        }
                    }
                }
            }
            Spacer()
            Text("仅执行本机只读命令 · 不联网").font(.system(size: 10)).foregroundColor(.secondary)
        }
        .padding(14)
    }
}
