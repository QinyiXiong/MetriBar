//
//  SettingsView.swift
//  MetriBar
//
//  设置面板：刷新频率 + 开机自启（+ 菜单栏显示项、单位）。
//

import SwiftUI
import AppKit

@MainActor
struct SettingsView: View {
    /// 设置窗口**自带**一份 AppSettings：它和主面板共用同一批 UserDefaults key，
    /// 所以状态天然一致；这样就不再依赖 `Scene.environmentObject`
    /// （macOS 13 的 Settings 场景不会继承 App 级注入，取不到就直接崩溃）。
    @StateObject private var settings = AppSettings()

    /// 与 AppSettings 共用同一批 UserDefaults key，直接绑定即可自动持久化。
    @AppStorage(AppSettings.Keys.showUploadInMenuBar) private var showUpload = true
    @AppStorage(AppSettings.Keys.showTemperatureInMenuBar) private var showTemperature = true
    @AppStorage(AppSettings.Keys.showCPUUsageInMenuBar) private var showCPUUsage = false
    @AppStorage(AppSettings.Keys.showGPUUsageInMenuBar) private var showGPUUsage = false
    @AppStorage(AppSettings.Keys.showHeartRateInMenuBar) private var showHeartRate = true
    @AppStorage(AppSettings.Keys.heartDeviceNameFilter) private var heartNameFilter = "fenix"

    /// 蓝牙/心率实时状态（每分钟不必，1s 轮询采集器缓存即可）。
    @State private var heartStatus: HeartRateCollector.Reading = HeartRateCollector.shared.current()
    @State private var heartTimer: Timer?
    @AppStorage(AppSettings.Keys.menuBarStyle) private var menuBarStyleRaw = AppSettings.MenuBarStyle.rich.rawValue
    @AppStorage(AppSettings.Keys.speedUnit) private var speedUnitRaw = SpeedUnit.auto.rawValue
    @AppStorage(AppSettings.Keys.temperatureUnit) private var temperatureUnitRaw = TemperatureUnit.celsius.rawValue

    var body: some View {
        Form {
            Section("采集") {
                Picker("刷新间隔", selection: refreshIntervalBinding) {
                    ForEach(AppSettings.allowedIntervals, id: \.self) { seconds in
                        Text(seconds < 1.5 ? "1 秒（推荐）" : String(format: "%.0f 秒", seconds))
                            .tag(seconds)
                    }
                }
                Text("1–2 秒最实时；间隔越长越省电。SMC 读取在后台线程执行，不影响界面流畅度。")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }

            Section("菜单栏显示") {
                Picker("排版样式", selection: $menuBarStyleRaw) {
                    ForEach(AppSettings.MenuBarStyle.allCases) { style in
                        Text(style.label).tag(style.rawValue)
                    }
                }

                Toggle("下载速率 ↓", isOn: .constant(true))
                Toggle("上传速率 ↑", isOn: $showUpload)
                Toggle("CPU 占用率", isOn: $showCPUUsage)
                Toggle("GPU 占用率", isOn: $showGPUUsage)
                Toggle("CPU 温度", isOn: $showTemperature)
                Toggle("心率 ♥（蓝牙手表）", isOn: heartToggleBinding)

                // 预览直接显示真实提交给状态栏的位图，切样式当场见效。
                menuBarPreview
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color(nsColor: .quaternaryLabelColor).opacity(0.35))
                    )

                Text("↑ 菜单栏实时预览（数值为示意，样式与顶部状态栏完全一致）。")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }

            Section("心率 · 蓝牙") {
                Toggle("在菜单栏显示心率", isOn: heartToggleBinding)

                LabeledContent("连接状态") {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(heartStatus.isConnected ? Color(nsColor: .systemGreen)
                                                         : Color(nsColor: .systemOrange).opacity(0.8))
                            .frame(width: 6, height: 6)
                        Text(heartStatus.status.text)
                            .foregroundColor(.secondary)
                    }
                }
                if let name = heartStatus.deviceName, heartStatus.isConnected {
                    LabeledContent("设备", value: name)
                }
                if let bpm = heartStatus.bpm {
                    LabeledContent("当前心率", value: "\(bpm) BPM")
                }

                TextField("设备名过滤（留空=任意心率设备）", text: heartFilterBinding)

                HStack {
                    Button("重新搜索手表") { settings.setHeartDeviceNameFilter(heartNameFilter) }
                    Button("打开「蓝牙」设置") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.Bluetooth") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }

                Text("在手表上打开「广播心率」（活动 · 设置里，或下拉快捷面板的心率广播）。首次会弹出「允许 MetriBar 使用蓝牙」。macOS 无 ANT+，走 BLE 标准心率服务。")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }

            Section("单位") {
                Picker("网速", selection: $speedUnitRaw) {
                    ForEach(SpeedUnit.allCases) { unit in
                        Text(unit.label).tag(unit.rawValue)
                    }
                }
                Picker("温度", selection: $temperatureUnitRaw) {
                    ForEach(TemperatureUnit.allCases) { unit in
                        Text(unit.label).tag(unit.rawValue)
                    }
                }
            }

            Section("启动") {
                Toggle("登录时自动启动", isOn: launchAtLoginBinding)
                Text(settings.loginItemStatus.hintText)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)

                HStack {
                    Button("重新检测状态") { settings.refreshLoginItemStatus() }
                    Button("打开「登录项」设置") { settings.openLoginItemsSettings() }
                }
            }

            Section("关于") {
                LabeledContent("Bundle ID", value: "com.qyx.MetriBar")
                LabeledContent("最低系统", value: "macOS 13 Ventura")
                LabeledContent("SMC 访问", value: "已关闭 App Sandbox（外部 dmg 分发）")
                LabeledContent("传感器库", value: "SMCKit (MIT)")
            }
        }
        .formStyle(.grouped)
        .frame(width: 400)
        .frame(minHeight: 380)
        .onAppear {
            settings.refreshLoginItemStatus()
            heartStatus = HeartRateCollector.shared.current()
            heartTimer?.invalidate()
            heartTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
                heartStatus = HeartRateCollector.shared.current()
            }
        }
        .onDisappear { heartTimer?.invalidate(); heartTimer = nil }
    }

    /// 心率开关：写 @AppStorage（菜单栏会立即反映），并广播让采集器起停蓝牙。
    private var heartToggleBinding: Binding<Bool> {
        Binding(
            get: { showHeartRate },
            set: { settings.setShowHeartRate($0) }
        )
    }

    /// 设备名过滤：改完立即重扫（换手表不用重启 App）。
    private var heartFilterBinding: Binding<String> {
        Binding(
            get: { heartNameFilter },
            set: { settings.setHeartDeviceNameFilter($0) }
        )
    }

    /// 设置页里的菜单栏预览：Rich 直接渲染最终位图，Compact 沿用纯文本。
    @ViewBuilder private var menuBarPreview: some View {
        let style = AppSettings.MenuBarStyle(rawValue: menuBarStyleRaw) ?? .rich
        if style == .rich {
            Image(nsImage: MenuBarBadge.image(
                segments: MenuBarLabelView.badgeSegments(
                    settings: settings,
                    down: 1_250_000,
                    up: 68_000,
                    cpu: 0.12,
                    gpu: 0.34,
                    temperature: 64,
                    heart: 72
                ),
                background: .pill,
                dark: MenuBarBadge.isDark
            ))
            .renderingMode(.original)
            .fixedSize()
        } else {
            MenuBarLabelView.compose(
                settings: settings,
                down: 1_250_000,
                up: 68_000,
                cpu: 0.12,
                gpu: 0.34,
                temperature: 64,
                heart: 72
            )
            .fixedSize()
        }
    }

    /// 间隔修改要广播通知，让采集 Timer 立即重建。
    private var refreshIntervalBinding: Binding<Double> {
        Binding(
            get: { settings.refreshInterval },
            set: { settings.setRefreshInterval($0) }
        )
    }

    /// 登录项以 SMAppService 的真实状态为准，写入时同步注册/注销。
    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { settings.launchAtLoginEnabled },
            set: { settings.setLaunchAtLogin($0) }
        )
    }
}
