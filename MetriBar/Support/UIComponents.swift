//
//  UIComponents.swift
//  MetriBar
//
//  面板复用的原生风小组件：分组标题、指标行、细进度条。
//

import AppKit
import SwiftUI

/// 打开 SwiftUI Settings 窗口（macOS 13/14 选择子不同，逐个尝试）。
@MainActor
enum SettingsWindow {
    static func open() {
        NSApp.activate(ignoringOtherApps: true)
        if #available(macOS 14.0, *) {
            if !NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) {
                NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
            }
        } else {
            NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
        }
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
