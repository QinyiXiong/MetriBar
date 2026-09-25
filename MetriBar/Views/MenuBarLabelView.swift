//
//  MenuBarLabelView.swift
//  MetriBar
//
//  菜单栏文本：只显示数值与图标，不显示应用名称。
//
//  两套排版：
//   · 丰富（默认） SF Symbols + 分级字号 + 按负载/温度着色
//        ⬇ 1.2M │ ⬆ 68K │ ▦ 12% │ ◻ 8% │ 🌡 64°
//   · 紧凑        纯文本，宽度最省（老样式）
//        ↓1.2M ↑68K 64°
//
//  ⚠️ 两种都是**一个 Text**（`Text` 支持 `+` 串联并各自保留属性）：
//  MenuBarExtra 的 label 放 HStack 时状态项宽度可能按首帧固定，
//  变长的字段会被裁掉，表现为「只能看到下载速度」。
//

import SwiftUI

@MainActor
struct MenuBarLabelView: View {
    let snapshot: MetricsSnapshot
    @ObservedObject var settings: AppSettings

    // 排版常量：一眼能改，方便调手感。
    private enum Metrics {
        /// 箭头细碎，需要加粗才压得住；温度计笔画多，得给更大的字号才看得清。
        static let arrow = Font.system(size: 9.5, weight: .bold)
        static let chip = Font.system(size: 10, weight: .semibold)
        static let thermometer = Font.system(size: 11, weight: .medium)
        static let value = Font.system(size: 11.5, weight: .semibold)
        static let unit = Font.system(size: 8, weight: .medium)
        static let divider = Font.system(size: 9, weight: .regular)
        static let gap = Text(verbatim: "\u{2009}")          // thin space
        static let dividerColor = Color.primary.opacity(0.22)
    }

    var body: some View {
        Self.compose(
            settings: settings,
            down: snapshot.network.downBps,
            up: snapshot.network.upBps,
            cpu: snapshot.cpu.total,
            gpu: snapshot.gpu.utilization,
            temperature: snapshot.hardware.cpuTemperature
        )
        .fixedSize(horizontal: true, vertical: false)
        .padding(.horizontal, 2)
        .help(hint)
    }

    // MARK: - 共用拼装（真实菜单栏 & 设置页预览都走这里，保证所见即所得）

    static func compose(
        settings: AppSettings,
        down: Double,
        up: Double,
        cpu: Double?,
        gpu: Double?,
        temperature: Double?
    ) -> Text {
        if settings.menuBarStyle == .compact {
            return compact(settings: settings, down: down, up: up, cpu: cpu, gpu: gpu, temperature: temperature)
        }

        var parts: [Text] = [speedSegment(symbol: "arrow.down", color: Color(nsColor: .systemBlue), bytes: down)]

        if settings.showUploadInMenuBar {
            parts.append(divider + speedSegment(symbol: "arrow.up", color: Color(nsColor: .systemOrange), bytes: up))
        }
        if settings.showCPUUsageInMenuBar, let cpu {
            parts.append(divider + loadSegment(symbol: "cpu", fraction: cpu))
        }
        if settings.showGPUUsageInMenuBar, let gpu {
            parts.append(divider + loadSegment(symbol: "cube", fraction: gpu))
        }
        if settings.showTemperatureInMenuBar {
            parts.append(divider + temperatureSegment(temperature))
        }

        return join(parts)
    }

    // MARK: - 片段

    private static func glyph(_ symbol: String, _ color: Color, _ font: Font) -> Text {
        Text(Image(systemName: symbol))
            .font(font)
            .foregroundColor(color)
    }

    private static var divider: Text {
        Text(verbatim: "\u{2009}│\u{2009}")
            .font(Metrics.divider)
            .foregroundColor(Metrics.dividerColor)
    }

    /// 速率段：图标 + 数值 + 小号单位；空闲（≈0）整体转灰，避免视觉上"卡在 0"。
    private static func speedSegment(symbol: String, color: Color, bytes: Double) -> Text {
        let parts = Fmt.speedParts(bytes)
        let idle = bytes < 1_000

        if idle {
            return Text(verbatim: "·")
                .font(Metrics.value)
                .foregroundColor(.secondary.opacity(0.75))
        }

        return glyph(symbol, color, Metrics.arrow)
            + Metrics.gap
            + Text(verbatim: parts.value).font(Metrics.value).foregroundColor(.primary)
            + Text(verbatim: parts.unit).font(Metrics.unit).foregroundColor(.secondary)
    }

    /// 占用段（CPU / GPU）：图标 + 百分比，颜色随负载。
    private static func loadSegment(symbol: String, fraction: Double) -> Text {
        let color = GaugeColor.forFraction(fraction)
        return glyph(symbol, color, Metrics.chip)
            + Metrics.gap
            + Text(verbatim: String(format: "%.0f", fraction * 100))
                .font(Metrics.value)
                .foregroundColor(.primary)
            + Text(verbatim: "%").font(Metrics.unit).foregroundColor(.secondary)
    }

    /// 温度段：图标随热度换（低/中/高），数值着色。
    private static func temperatureSegment(_ celsius: Double?) -> Text {
        let parts = Fmt.temperatureParts(celsius)
        let color = GaugeColor.forTemperature(celsius)
        let symbol: String
        switch celsius ?? 0 {
        case ..<50: symbol = "thermometer.low"
        case ..<80: symbol = "thermometer.medium"
        default: symbol = "thermometer.high"
        }

        return glyph(symbol, color, Metrics.thermometer)
            + Metrics.gap
            + Text(verbatim: parts.value).font(Metrics.value).foregroundColor(color)
            + Text(verbatim: parts.unit).font(Metrics.unit).foregroundColor(.secondary)
    }

    /// 紧凑样式：无图标，最短。
    private static func compact(
        settings: AppSettings,
        down: Double,
        up: Double,
        cpu: Double?,
        gpu: Double?,
        temperature: Double?
    ) -> Text {
        var text = Text("↓" + Fmt.compactSpeed(down))
        if settings.showUploadInMenuBar { text = text + Text("  ") + Text("↑" + Fmt.compactSpeed(up)) }
        if settings.showCPUUsageInMenuBar, let cpu { text = text + Text("  ") + Text(Fmt.percent(cpu)) }
        if settings.showGPUUsageInMenuBar, let gpu { text = text + Text("  ") + Text("G" + Fmt.percent(gpu)) }
        if settings.showTemperatureInMenuBar { text = text + Text("  ") + Text(Fmt.temperature(temperature)) }
        return text.font(.system(size: 11, weight: .medium)).foregroundColor(.primary)
    }

    private static func join(_ parts: [Text]) -> Text {
        parts.reduce(Text(verbatim: "")) { $0 + $1 }
    }

    // MARK: - 悬浮提示

    private var hint: String {
        var lines: [String] = []
        lines.append("↓ " + Fmt.speed(snapshot.network.downBps, unit: settings.speedUnit))
        lines.append("↑ " + Fmt.speed(snapshot.network.upBps, unit: settings.speedUnit))
        if let interface = snapshot.network.primaryInterface {
            lines.append("活动网卡：\(interface)")
        }
        if let temperature = snapshot.hardware.cpuTemperature {
            let key = snapshot.hardware.sensorKey.map { "（\($0)）" } ?? ""
            lines.append("CPU：\(Fmt.temperature(temperature, unit: settings.temperatureUnit))\(key)")
        } else {
            lines.append("CPU：温度不可用")
        }
        if let gpu = snapshot.gpu.utilization {
            lines.append("GPU：\(Fmt.percent(gpu))（\(snapshot.gpu.deviceName ?? "未知设备")）")
        }
        return lines.joined(separator: "\n")
    }
}
