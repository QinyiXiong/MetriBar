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
                Toggle("下载速率 ↓", isOn: .constant(true))
                Toggle("上传速率 ↑", isOn: $showUpload)
                Toggle("CPU 占用率", isOn: $showCPUUsage)
                Toggle("GPU 占用率", isOn: $showGPUUsage)
                Toggle("CPU 温度", isOn: $showTemperature)

                Text(previewText)
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Color.primary.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                Text("↑ 菜单栏排版预览（数值为示意）。只显示数值与单位，不显示应用名称。")
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

    /// 按当前开关拼出菜单栏文案（示意值），和 MenuBarLabelView 的字段顺序保持一致。
    private var previewText: String {
        var parts = ["↓1.2M"]
        if showUpload { parts.append("↑68K") }
        if showCPUUsage { parts.append("12%") }
        if showGPUUsage { parts.append("G8%") }
        if showTemperature { parts.append("59°") }
        return parts.joined(separator: "  ")
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
