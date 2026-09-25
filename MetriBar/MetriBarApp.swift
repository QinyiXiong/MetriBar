//
//  MetriBarApp.swift
//  MetriBar
//
//  菜单栏监控工具入口。
//
//  · MenuBarExtra(.window)：纯 SwiftUI 状态栏 + 弹出面板，不使用 AppKit NSStatusItem。
//  · LSUIElement = YES：无 Dock 图标（见 target 的 INFOPLIST_KEY_LSUIElement）。
//  · 设置窗口：⌘, 或面板齿轮 → SettingsWindow.open()（刷新频率 / 自启 / 菜单栏显示项 / 单位）。
//

import SwiftUI

@main
@MainActor
struct MetriBarApp: App {

    @StateObject private var settings: AppSettings
    @StateObject private var store: MetricsStore

    init() {
        let defaults = UserDefaults.standard
        let storedInterval = (defaults.object(forKey: AppSettings.Keys.refreshInterval) as? Double) ?? 2
        let appSettings = AppSettings()

        _settings = StateObject(wrappedValue: appSettings)
        _store = StateObject(wrappedValue: MetricsStore(interval: storedInterval))

        // 启动即把菜单栏字段写进日志：若菜单栏"少了东西"，先看这行确认是开关问题还是排版问题。
        Diag.notice(Diag.lifecycle, "启动：间隔 \(String(format: "%.1f", storedInterval))s，菜单栏字段 [\(appSettings.menuBarFields.joined(separator: " "))]")

        // 自检开关：`defaults write com.qyx.MetriBar MetriBarDebugOpenSettings -bool YES`
        // 启动后自动弹出设置窗口，用于验证 Agent 应用的开窗链路（正常使用时保持关闭）。
        if UserDefaults.standard.bool(forKey: "MetriBarDebugOpenSettings") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                SettingsWindow.open()
            }
        }
    }

    var body: some Scene {
        // 状态栏图标：仅数值（↓下载 ↑上传 CPU GPU 温度），拼成单个 Text。
        MenuBarExtra {
            PopoverView()
                .environmentObject(store)
                .environmentObject(settings)
        } label: {
            MenuBarLabelView(snapshot: store.snapshot, settings: settings)
        }
        .menuBarExtraStyle(.window)

        // 设置面板不再用 `Settings` 场景：实测 LSUIElement Agent 应用里
        // showSettingsWindow: / openSettings 都只"响应"不建窗（见 UIComponents 说明），
        // 改由 SettingsWindow.open() 自己托管 NSWindow + NSHostingController。
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("MetriBar 设置…") {
                    SettingsWindow.open()
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}
