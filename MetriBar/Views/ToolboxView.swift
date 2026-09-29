//
//  ToolboxView.swift
//  MetriBar
//
//  工具箱容器：三个原生 Tab，延续系统原生观感。
//

import SwiftUI

struct ToolboxView: View {
    @State private var tab: ToolTab = .printer

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

            switch tab {
            case .printer:   PrinterTab()
            case .verify:    VerifyTab()
            case .translate: TranslateTab()
            }
        }
        .frame(minWidth: 820, minHeight: 540)
    }
}
