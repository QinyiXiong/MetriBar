//
//  SettingsView.swift
//  MetriBar
//
//  设置面板：刷新频率 + 开机自启（+ 菜单栏显示项、单位）。
//

import SwiftUI

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
        .onAppear { settings.refreshLoginItemStatus() }
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
                    temperature: 64
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
                temperature: 64
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
