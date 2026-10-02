//
//  ToolboxView.swift
//  MetriBar
//
//  工具箱容器：三个原生 Tab，延续系统原生观感。
//

import SwiftUI

struct ToolboxView: View {
    @State private var tab: ToolTab = .printer
    /// 首次进入过的 Tab 常驻保留：切回来零重建（消除切换卡顿）
    @State private var visited: Set<ToolTab> = [.printer]

    enum ToolTab: Hashable { case printer, verify, translate }

    var body: some View {
        VStack(spacing: 0) {
            // 顶部 Tab 条（分段控件，原生手感）
            Picker("", selection: $tab) {
                Label("打印机测试", systemImage: "printer.fill").tag(ToolTab.printer)
                Label("MacBook 验机", systemImage: "laptopcomputer").tag(ToolTab.verify)
                Label("视频翻译", systemImage: "captions.bubble.fill").tag(ToolTab.translate)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()

            // 用 ZStack + 隐藏而非 switch：访问过的 Tab 常驻，切回瞬间呈现（不再重建视图树）
            ZStack {
                if visited.contains(.printer) { tabLayer(.printer) { PrinterTab() } }
                if visited.contains(.verify) { tabLayer(.verify) { VerifyTab() } }
                if visited.contains(.translate) { tabLayer(.translate) { TranslateTab() } }
            }
        }
        .frame(minWidth: 820, minHeight: 540)
        .onChange(of: tab) { visited.insert($0) }
    }

    @ViewBuilder
    private func tabLayer<V: View>(_ t: ToolTab, @ViewBuilder _ content: () -> V) -> some View {
        content()
            .opacity(tab == t ? 1 : 0)
            .allowsHitTesting(tab == t)
            .accessibilityHidden(tab != t)
    }
}
