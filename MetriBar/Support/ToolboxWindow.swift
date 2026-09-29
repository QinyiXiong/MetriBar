//
//  ToolboxWindow.swift
//  MetriBar
//
//  「工具箱」窗口唯一入口：与 SettingsWindow 同款模式——Agent(LSUIElement) 应用
//  自持 NSWindow + NSHostingController，保持 regular 直到窗口关闭再还原 accessory。
//  三个 Tab：打印机测试 / MacBook 验机 / 视频翻译。
//

import AppKit
import SwiftUI

@MainActor
enum ToolboxWindow {

    private static var controller: NSWindowController?

    static func open() {
        let originalPolicy = NSApp.activationPolicy()
        if originalPolicy != .regular {
            NSApp.setActivationPolicy(.regular)
        }
        closeMenuBarPanels()

        let window = ensureWindow(revertTo: originalPolicy)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        Diag.notice(Diag.lifecycle, "打开工具箱窗口")
    }

    private static func ensureWindow(revertTo originalPolicy: NSApplication.ActivationPolicy) -> NSWindow {
        if let window = controller?.window { return window }

        let hosting = NSHostingController(rootView: ToolboxView())
        let window = NSWindow(contentViewController: hosting)
        window.title = "MetriBar 工具箱"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 960, height: 620))
        window.minSize = NSSize(width: 820, height: 540)
        window.setFrameAutosaveName("MetriBarToolboxWindow")
        if !window.setFrameUsingName("MetriBarToolboxWindow") { window.center() }

        if originalPolicy != .regular {
            NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: window, queue: .main
            ) { _ in
                if NSApp.activationPolicy() == .regular { NSApp.setActivationPolicy(.accessory) }
            }
        }

        let controller = NSWindowController(window: window)
        controller.shouldCascadeWindows = false
        self.controller = controller
        Diag.notice(Diag.lifecycle, "创建工具箱窗口")
        return window
    }

    private static func closeMenuBarPanels() {
        for window in NSApp.windows where window.isVisible {
            let className = String(describing: type(of: window))
            guard window is NSPanel || className.lowercased().contains("menubar") else { continue }
            window.orderOut(nil)
        }
    }
}
