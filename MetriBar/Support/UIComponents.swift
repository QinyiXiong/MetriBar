//
//  UIComponents.swift
//  MetriBar
//
//  面板复用的原生风小组件：分组标题、指标行、细进度条。
//

import AppKit
import SwiftUI

/// 设置窗口唯一入口：自持一个 NSWindow + NSHostingController(SettingsView)。
///
/// 为什么不继续用 `Settings` 场景 + `sendAction(showSettingsWindow:)`：
/// MetriBar 是 LSUIElement Agent 应用，实测（macOS 27 beta / Xcode 27）该选择子
/// **返回 true 但窗口根本没被创建** —— 自检日志里可见窗口只有 NSStatusBarWindow，
/// 这正是「点齿轮没反应」的根因（`openSettings` / `showPreferencesWindow:` 同病）。
/// AppKit 自建窗口行为确定、能自检、macOS 13 起可用，且不违背「不使用 NSStatusItem」。
@MainActor
enum SettingsWindow {

    private static var controller: NSWindowController?

    static func open() {
        // Agent 应用平时不是激活态，先提策略，否则窗口会被别的 App 压住。
        let originalPolicy = NSApp.activationPolicy()
        if originalPolicy != .regular {
            NSApp.setActivationPolicy(.regular)
        }
        closeMenuBarPanels()

        let window = ensureWindow()
        window.makeKeyAndOrderFront(nil)
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }

        Diag.notice(Diag.lifecycle, "打开设置窗口：\(window.title)，策略=\(policyName(NSApp.activationPolicy()))")
        restorePolicy(originalPolicy)
        verifyOpened(after: 0.4)
    }

    // MARK: - 窗口构建

    private static func ensureWindow() -> NSWindow {
        if let window = controller?.window {
            return window
        }

        let hosting = NSHostingController(rootView: SettingsView())
        let window = NSWindow(contentViewController: hosting)
        window.title = "MetriBar 设置"
        window.styleMask = [.titled, .closable, .miniaturizable]
        // 关闭时不销毁：复用同一个窗口，反复开关不会重建。
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 400, height: 430))
        window.setFrameAutosaveName("MetriBarSettingsWindow")
        if !window.setFrameUsingName("MetriBarSettingsWindow") {
            window.center()
        }

        let controller = NSWindowController(window: window)
        controller.shouldCascadeWindows = false
        self.controller = controller

        Diag.notice(Diag.lifecycle, "创建设置窗口（NSHostingController）")
        return window
    }

    // MARK: - 自检与收尾

    /// 确认窗口真的可见并写进日志：Agent 应用最容易在这一步静默失败。
    private static func verifyOpened(after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            let names = NSApp.windows
                .filter(\.isVisible)
                .map { String(describing: type(of: $0)) + ":" + ($0.title.isEmpty ? "‹无标题›" : $0.title) }
            let opened = controller?.window?.isVisible == true
            Diag.notice(
                Diag.lifecycle,
                "设置窗口自检：\(opened ? "已打开" : "未出现")｜可见窗口 [\(names.joined(separator: ", "))]"
            )
        }
    }

    /// 收起 MenuBarExtra 面板（nonactivating panel），否则它会压住设置窗口。
    private static func closeMenuBarPanels() {
        for window in NSApp.windows where window.isVisible {
            let className = String(describing: type(of: window))
            guard window is NSPanel || className.lowercased().contains("menubar") else { continue }
            window.orderOut(nil)
        }
    }

    /// 恢复 Agent 形态（不占 Dock）。设置窗口开着时切回 accessory 是安全的。
    private static func restorePolicy(_ original: NSApplication.ActivationPolicy) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            guard original != .regular else { return }
            NSApp.setActivationPolicy(original)
        }
    }

    private static func policyName(_ policy: NSApplication.ActivationPolicy) -> String {
        switch policy {
        case .regular: return "regular"
        case .accessory: return "accessory"
        case .prohibited: return "prohibited"
        @unknown default: return "unknown"
        }
    }
}

/// 齿轮按钮：统一走 SettingsWindow.open()。
@MainActor
struct SettingsGearButton: View {
    var body: some View {
        Button {
            SettingsWindow.open()
        } label: {
            Image(systemName: "gearshape")
        }
        .buttonStyle(.plain)
        .keyboardShortcut(",", modifiers: .command)
        .help("设置（⌘,）")
    }
}

/// 分组容器：小标题 + 内容，卡片式圆角，与系统面板一致。
@MainActor
struct PanelSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
                .textCase(nil)

            VStack(alignment: .leading, spacing: 6) {
                content
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.5)
            )
        }
    }
}

/// 指标行：图标 + 名称 + 数值（数值右对齐、等宽数字，避免刷新时抖动）。
@MainActor
struct MetricRow: View {
    let systemImage: String
    let title: String
    let value: String
    var detail: String? = nil
    var tertiary: String? = nil

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
                .frame(width: 14, alignment: .center)

            Text(title)
                .font(.system(size: 12))
                .foregroundColor(.primary)

            if let tertiary {
                Text(tertiary)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 6)

            VStack(alignment: .trailing, spacing: 1) {
                Text(value)
                    .font(.system(size: 12, weight: .medium))
                    .monospacedDigit()
                    .foregroundColor(.primary)
                    .fixedSize()

                if let detail {
                    Text(detail)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .monospacedDigit()
                }
            }
        }
    }
}

/// 细进度条（内存 / 磁盘 / 风扇占比）。
@MainActor
struct SlimGauge: View {
    var fraction: Double
    var color: Color = .accentColor

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.10))
                Capsule()
                    .fill(color)
                    .frame(width: max(2, proxy.size.width * min(max(fraction, 0), 1)))
            }
        }
        .frame(height: 4)
    }
}

@MainActor
enum GaugeColor {
    /// 按占用比例由绿到红，接近系统监视器的观感。
    static func forFraction(_ fraction: Double) -> Color {
        switch fraction {
        case ..<0.60: return Color(nsColor: .systemGreen)
        case ..<0.85: return Color(nsColor: .systemYellow)
        default: return Color(nsColor: .systemRed)
        }
    }

    /// 温度色阶（以 60 / 85 °C 为界）。
    static func forTemperature(_ celsius: Double?) -> Color {
        guard let celsius else { return Color.secondary }
        switch celsius {
        case ..<60: return Color(nsColor: .systemGreen)
        case ..<85: return Color(nsColor: .systemYellow)
        default: return Color(nsColor: .systemRed)
        }
    }
}
