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

import AppKit
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
        // 紧凑模式：纯文本最稳（状态栏 template 渲染下也不会出问题）。
        if settings.menuBarStyle == .compact {
            Self.compact(
                settings: settings,
                down: snapshot.network.downBps,
                up: snapshot.network.upBps,
                cpu: snapshot.cpu.total,
                gpu: snapshot.gpu.utilization,
                temperature: snapshot.hardware.cpuTemperature,
                heart: snapshot.heart.bpm
            )
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 2)
            .help(hint)
        } else {
            // 丰富模式：状态栏会把 label 当 template 重绘（颜色抹平、SF Symbol 消失），
            // 所以这里传**非模板位图**，图标与配色才能保住。
            Image(nsImage: badge)
                .renderingMode(.original)
                .padding(.horizontal, 2)
                .help(hint)
        }
    }

    private var badge: NSImage {
        Self.badge(
            settings: settings,
            down: snapshot.network.downBps,
            up: snapshot.network.upBps,
            cpu: snapshot.cpu.total,
            gpu: snapshot.gpu.utilization,
            temperature: snapshot.hardware.cpuTemperature,
            heart: snapshot.heart.bpm,
            dark: MenuBarBadge.isDark
        )
    }

    /// 真实菜单栏与设置页预览共用：同一套 segments + 同一个 Core Text 绘制器。
    static func badge(
        settings: AppSettings,
        down: Double,
        up: Double,
        cpu: Double?,
        gpu: Double?,
        temperature: Double?,
        heart: Int? = nil,
        dark: Bool
    ) -> NSImage {
        MenuBarBadge.image(
            segments: badgeSegments(settings: settings, down: down, up: up, cpu: cpu, gpu: gpu, temperature: temperature, heart: heart),
            background: .pill,
            dark: dark
        )
    }

    static func badgeSegments(
        settings: AppSettings,
        down: Double,
        up: Double,
        cpu: Double?,
        gpu: Double?,
        temperature: Double?,
        heart: Int? = nil
    ) -> [MenuBarSegment] {
        var segments: [MenuBarSegment] = []
        let idleLabel: NSColor = .secondaryLabelColor

        if true { // 下载常驻显示
            let parts = Fmt.speedParts(down)
            let idle = down < 1_000
            segments.append(MenuBarSegment(
                symbol: "arrow.down",
                value: idle ? "0" : parts.value,
                unit: idle ? "" : parts.unit,
                color: idle ? idleLabel : .systemBlue
            ))
        }

        if settings.showUploadInMenuBar {
            let parts = Fmt.speedParts(up)
            let idle = up < 1_000
            segments.append(MenuBarSegment(
                symbol: "arrow.up",
                value: idle ? "0" : parts.value,
                unit: idle ? "" : parts.unit,
                color: idle ? idleLabel : .systemOrange
            ))
        }

        if settings.showCPUUsageInMenuBar, let cpu {
            segments.append(MenuBarSegment(
                symbol: "cpu",
                value: String(format: "%.0f", min(max(cpu, 0), 1) * 100),
                unit: "%",
                color: NSColor(GaugeColor.forFraction(cpu))
            ))
        }

        if settings.showGPUUsageInMenuBar, let gpu {
            segments.append(MenuBarSegment(
                symbol: "cube",
                value: String(format: "%.0f", min(max(gpu, 0), 1) * 100),
                unit: "%",
                color: NSColor(GaugeColor.forFraction(gpu))
            ))
        }

        if settings.showTemperatureInMenuBar {
            let parts = Fmt.temperatureParts(temperature, unit: settings.temperatureUnit)
            let color = NSColor(GaugeColor.forTemperature(temperature))
            let symbol: String
            switch temperature ?? 0 {
            case ..<50: symbol = "thermometer.low"
            case ..<80: symbol = "thermometer.medium"
            default: symbol = "thermometer.high"
            }
            segments.append(MenuBarSegment(
                symbol: symbol,
                value: parts.value,
                unit: settings.temperatureUnit == .celsius ? "\u{00B0}" : "\u{00B0}F",
                color: color
            ))
        }

        // 心率段：❤ + bpm。没信号时保留槽位显示 "--"（转灰），避免图标跳来跳去。
        if settings.showHeartRateInMenuBar {
            let hasBeat = heart != nil
            segments.append(MenuBarSegment(
                symbol: "heart.fill",
                value: heart.map { String($0) } ?? "--",
                unit: "",
                color: hasBeat ? .systemPink : idleLabel
            ))
        }

        return segments
    }

    /// 缓存签名：数值取整到与显示一致的精度，内容不变就不必重画位图。
    static func signature(settings: AppSettings, snapshot: MetricsSnapshot) -> String {
        var parts = [Fmt.compactSpeed(snapshot.network.downBps)]
        if settings.showUploadInMenuBar { parts.append(Fmt.compactSpeed(snapshot.network.upBps)) }
        if settings.showCPUUsageInMenuBar { parts.append(Fmt.percent(snapshot.cpu.total)) }
        if settings.showGPUUsageInMenuBar, let gpu = snapshot.gpu.utilization { parts.append(Fmt.percent(gpu)) }
        if settings.showTemperatureInMenuBar { parts.append(Fmt.temperature(snapshot.hardware.cpuTemperature, unit: settings.temperatureUnit)) }
        if settings.showHeartRateInMenuBar { parts.append("♥" + (snapshot.heart.bpm.map(String.init) ?? "--")) }
        return parts.joined(separator: ",")
    }

    // MARK: - 共用拼装（真实菜单栏 & 设置页预览都走这里，保证所见即所得）

    static func compose(
        settings: AppSettings,
        down: Double,
        up: Double,
        cpu: Double?,
        gpu: Double?,
        temperature: Double?,
        heart: Int? = nil
    ) -> Text {
        if settings.menuBarStyle == .compact {
            return compact(settings: settings, down: down, up: up, cpu: cpu, gpu: gpu, temperature: temperature, heart: heart)
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
        if settings.showHeartRateInMenuBar {
            parts.append(divider + heartSegment(heart))
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
            // 空闲也要保留图标与位置节奏，只把整段转成暗色，
            // 否则会出现孤零零一个点、字段宽度跳来跳去。
            let dim = Color.secondary.opacity(0.7)
            return glyph(symbol, dim, Metrics.arrow)
                + Metrics.gap
                + Text(verbatim: "0").font(Metrics.value).foregroundColor(dim)
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

    /// 心率段：❤ + bpm；无信号转灰显示 "--"。
    private static func heartSegment(_ bpm: Int?) -> Text {
        let color: Color = bpm == nil ? Color.secondary.opacity(0.7) : Color(nsColor: .systemPink)
        return glyph("heart.fill", color, Metrics.chip)
            + Metrics.gap
            + Text(verbatim: bpm.map(String.init) ?? "--").font(Metrics.value).foregroundColor(bpm == nil ? .secondary : color)
    }

    /// 紧凑样式：无图标，最短。
    private static func compact(
        settings: AppSettings,
        down: Double,
        up: Double,
        cpu: Double?,
        gpu: Double?,
        temperature: Double?,
        heart: Int? = nil
    ) -> Text {
        var text = Text("↓" + Fmt.compactSpeed(down))
        if settings.showUploadInMenuBar { text = text + Text("  ") + Text("↑" + Fmt.compactSpeed(up)) }
        if settings.showCPUUsageInMenuBar, let cpu { text = text + Text("  ") + Text(Fmt.percent(cpu)) }
        if settings.showGPUUsageInMenuBar, let gpu { text = text + Text("  ") + Text("G" + Fmt.percent(gpu)) }
        if settings.showTemperatureInMenuBar { text = text + Text("  ") + Text(Fmt.temperature(temperature)) }
        if settings.showHeartRateInMenuBar { text = text + Text("  ") + Text("\u{2665}" + (heart.map(String.init) ?? "--")) }
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
