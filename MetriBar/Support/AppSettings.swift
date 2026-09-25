//
//  AppSettings.swift
//  MetriBar
//
//  设置存储（UserDefaults / @AppStorage）+ 登录项管理（SMAppService）。
//

import AppKit
import Combine
import Foundation
import ServiceManagement
import SwiftUI

/// 应用设置。仅主线程访问（SwiftUI 环境对象）。
@MainActor
final class AppSettings: ObservableObject {

    enum Keys {
        static let refreshInterval = "refreshInterval"
        static let launchAtLogin = "launchAtLoginEnabled"
        static let speedUnit = "speedUnit"
        static let temperatureUnit = "temperatureUnit"
        static let showUploadInMenuBar = "showUploadInMenuBar"
        static let showTemperatureInMenuBar = "showTemperatureInMenuBar"
        static let showCPUUsageInMenuBar = "showCPUUsageInMenuBar"
        static let showGPUUsageInMenuBar = "showGPUUsageInMenuBar"
        static let menuBarStyle = "menuBarStyle"
    }

    /// 菜单栏排版风格。
    enum MenuBarStyle: String, CaseIterable, Identifiable, Sendable {
        case rich
        case compact

        var id: String { rawValue }
        var label: String {
            switch self {
            case .rich: return "丰富（图标 + 配色）"
            case .compact: return "紧凑（纯文本）"
            }
        }
    }

    /// 允许的刷新间隔（秒）。需求：1~2 秒为主，另放宽到 3/5/10 省电。
    static let allowedIntervals: [Double] = [1, 2, 3, 5, 10]

    // MARK: - 存储项

    /// 采集/刷新间隔（秒）。修改后会广播通知，由 MetricsEngine 重建 Timer。
    @AppStorage(Keys.refreshInterval) var refreshInterval: Double = 2

    /// 菜单栏是否显示上传速率。
    @AppStorage(Keys.showUploadInMenuBar) var showUploadInMenuBar: Bool = true

    /// 菜单栏是否显示 CPU 温度。
    @AppStorage(Keys.showTemperatureInMenuBar) var showTemperatureInMenuBar: Bool = true

    /// 菜单栏是否显示 CPU 占用率。
    @AppStorage(Keys.showCPUUsageInMenuBar) var showCPUUsageInMenuBar: Bool = false

    /// 菜单栏是否显示 GPU 占用率。
    @AppStorage(Keys.showGPUUsageInMenuBar) var showGPUUsageInMenuBar: Bool = false

    /// 菜单栏排版：rich = 图标 + 配色 + 分级字号；compact = 纯文本最省宽度。
    @AppStorage(Keys.menuBarStyle) private var menuBarStyleRaw: String = MenuBarStyle.rich.rawValue

    /// 网速单位。
    @AppStorage(Keys.speedUnit) private var speedUnitRaw: String = SpeedUnit.auto.rawValue

    /// 温度单位。
    @AppStorage(Keys.temperatureUnit) private var temperatureUnitRaw: String = TemperatureUnit.celsius.rawValue

    /// 登录项开关的存储值（真实状态以 SMAppService 为准）。
    @AppStorage(Keys.launchAtLogin) private var launchAtLoginStored: Bool = false

    // MARK: - 状态

    /// SMAppService 真实注册状态，展示在设置页。
    @Published private(set) var loginItemStatus: LoginItemStatus = .unsupported

    enum LoginItemStatus: Equatable {
        case unsupported
        case enabled
        case requiresApproval
        case notRegistered
        case failed(String)

        var hintText: String {
            switch self {
            case .unsupported: return "当前系统不支持 SMAppService（需 macOS 13+）"
            case .enabled: return "已注册，登录时自动启动"
            case .requiresApproval: return "已提交，需在「系统设置 › 通用 › 登录项」中允许"
            case .notRegistered: return "未注册"
            case .failed(let message): return "注册失败：\(message)"
            }
        }
    }

    init() {
        refreshLoginItemStatus()
    }

    // MARK: - 派生值

    var speedUnit: SpeedUnit {
        get { SpeedUnit(rawValue: speedUnitRaw) ?? .auto }
        set { speedUnitRaw = newValue.rawValue }
    }

    var temperatureUnit: TemperatureUnit {
        get { TemperatureUnit(rawValue: temperatureUnitRaw) ?? .celsius }
        set { temperatureUnitRaw = newValue.rawValue }
    }

    var menuBarStyle: MenuBarStyle {
        get { MenuBarStyle(rawValue: menuBarStyleRaw) ?? .rich }
        set { menuBarStyleRaw = newValue.rawValue }
    }

    /// 菜单栏当前会显示哪些字段（顺序即显示顺序），写进日志便于排查"少了什么"。
    var menuBarFields: [String] {
        var fields: [String] = ["↓下载"]
        if showUploadInMenuBar { fields.append("↑上传") }
        if showCPUUsageInMenuBar { fields.append("CPU") }
        if showGPUUsageInMenuBar { fields.append("GPU") }
        if showTemperatureInMenuBar { fields.append("温度") }
        fields.append(menuBarStyle == .rich ? "样式=丰富" : "样式=紧凑")
        return fields
    }

    var intervalText: String {
        refreshInterval < 1.5 ? "1 秒" : String(format: "%.0f 秒", refreshInterval)
    }

    // MARK: - 写操作

    func setRefreshInterval(_ seconds: Double) {
        let value = min(max(seconds, 1), 10)
        guard value != refreshInterval else { return }
        refreshInterval = value
        NotificationCenter.default.post(
            name: .metriBarRefreshIntervalChanged,
            object: value
        )
    }

    // MARK: - 登录项（SMAppService, macOS 13+）

    var launchAtLoginEnabled: Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled || launchAtLoginStored
        }
        return false
    }

    /// 注册 / 注销登录项。打包到 /Applications 后行为最稳定；
    /// 从 DerivedData 直接运行时也能注册，但换路径后需重新开关一次。
    func setLaunchAtLogin(_ enabled: Bool) {
        guard #available(macOS 13.0, *) else {
            loginItemStatus = .unsupported
            return
        }

        do {
            if enabled {
                if #available(macOS 14.0, *) {
                    // macOS 14：重复 register 可能抛错，先按当前状态判断。
                    if SMAppService.mainApp.status != .enabled {
                        try SMAppService.mainApp.register()
                    }
                } else {
                    try SMAppService.mainApp.register()
                }
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLoginStored = enabled
        } catch {
            // 取消勾选一个本来就未注册的服务，不算错误。
            if enabled == false, (error as NSError).domain == NSPOSIXErrorDomain,
               (error as NSError).code == ENOENT {
                launchAtLoginStored = false
            } else {
                loginItemStatus = .failed(error.localizedDescription)
                return
            }
        }

        refreshLoginItemStatus()
    }

    func refreshLoginItemStatus() {
        guard #available(macOS 13.0, *) else {
            loginItemStatus = .unsupported
            return
        }
        switch SMAppService.mainApp.status {
        case .enabled: loginItemStatus = .enabled
        case .requiresApproval: loginItemStatus = .requiresApproval
        default: loginItemStatus = launchAtLoginStored ? .enabled : .notRegistered
        }
    }

    /// 登录项自愈：仅当"从 /Applications 运行 + 此前已开启自启"时，按 bundle 路径强制盖章。
    /// 记录上次注册路径；只要当前路径变化（如从 DerivedData 迁到 /Applications），
    /// 就 unregister→register，把登录项重新指向正确副本。路径未变则完全 no-op。幂等、安静。
    func ensureLaunchAtLoginSelfHeal() {
        guard #available(macOS 13.0, *) else { return }
        guard launchAtLoginStored else { return }
        let currentPath = Bundle.main.bundlePath
        guard currentPath.hasPrefix("/Applications/") else { return }

        let regKey = "loginItemRegisteredPath"
        let lastPath = UserDefaults.standard.string(forKey: regKey)
        guard SMAppService.mainApp.status != .enabled || lastPath != currentPath else {
            Diag.notice(Diag.lifecycle, "开机自启已启用：\(currentPath)")
            return
        }

        do {
            try? SMAppService.mainApp.unregister()   // 清掉可能指向旧路径的登记
            try SMAppService.mainApp.register()        // 重新登记 = 当前 /Applications 副本
            UserDefaults.standard.set(currentPath, forKey: regKey)
            Diag.notice(Diag.lifecycle, "登录项自愈：已把开机自启重新指向 \(currentPath)")
        } catch {
            Diag.notice(Diag.lifecycle, "登录项自愈失败：\(error.localizedDescription)")
        }
        refreshLoginItemStatus()
    }

    /// 打开「系统设置 › 登录项」，方便用户批准（macOS 13 无稳定 API，走 URL scheme）。
    func openLoginItemsSettings() {
        let urlString = "x-apple.systempreferences:com.apple.LoginItems-Settings.extension"
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }
}
