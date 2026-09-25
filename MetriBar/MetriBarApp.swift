//
//  MetriBarApp.swift
//  MetriBar
//
//  菜单栏监控工具入口。
//
//  · MenuBarExtra(.window)：纯 SwiftUI 状态栏 + 弹出面板，不使用 AppKit NSStatusItem。
//  · LSUIElement = YES：无 Dock 图标（见 target 的 INFOPLIST_KEY_LSUIElement）。
//  · Settings 场景：⌘, 打开设置（刷新频率 / 开机自启 / 菜单栏显示项 / 单位）。
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
    }

    var body: some Scene {
        // 状态栏图标：仅数值（↓下载 ↑上传 温度）。
        MenuBarExtra {
            PopoverView()
                .environmentObject(store)
                .environmentObject(settings)
        } label: {
            MenuBarLabelView(snapshot: store.snapshot, settings: settings)
        }
        .menuBarExtraStyle(.window)

        // 设置面板。
        Settings {
            SettingsView()
                .environmentObject(settings)
                .environmentObject(store)
        }
        .defaultSize(width: 400, height: 420)
    }
}
