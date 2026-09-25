//
//  MenuBarLabelView.swift
//  MetriBar
//
//  菜单栏文本：只显示数值（下载 / 上传 / CPU / GPU / 温度），不显示应用名称。
//
//  ⚠️ 这里刻意把各段拼成**一个 Text**（Text 支持 `+` 串联，可分段着色）：
//  MenuBarExtra 的 label 里放 HStack 时，状态项宽度有时按首帧固定，
//  后面变长会被裁掉，表现为「只能看到下载速度」。
//

import SwiftUI

@MainActor
struct MenuBarLabelView: View {
    let snapshot: MetricsSnapshot
    @ObservedObject var settings: AppSettings

    /// 分隔符：两个空格在菜单栏里宽度稳定，又不会挤在一起。
    private static let separator = "  "

    var body: some View {
        composed
            .font(.system(size: 11, weight: .medium, design: .default))
            .monospacedDigit()
            .foregroundColor(.primary)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 2)
            .help(hint)
    }

    /// 按设置拼出菜单栏文案。
    private var composed: Text {
        var text = Text("↓" + Fmt.compactSpeed(snapshot.network.downBps))

        if settings.showUploadInMenuBar {
            text = text + Text(Self.separator) + Text("↑" + Fmt.compactSpeed(snapshot.network.upBps))
        }

        if settings.showCPUUsageInMenuBar {
            text = text + Text(Self.separator)
                + Text(Fmt.percent(snapshot.cpu.total))
                    .foregroundColor(GaugeColor.forFraction(snapshot.cpu.total))
        }

        if settings.showGPUUsageInMenuBar, let gpu = snapshot.gpu.utilization {
            text = text + Text(Self.separator)
                + Text("G" + Fmt.percent(gpu))
                    .foregroundColor(GaugeColor.forFraction(gpu))
        }

        if settings.showTemperatureInMenuBar {
            text = text + Text(Self.separator)
                + Text(Fmt.temperature(snapshot.hardware.cpuTemperature, unit: settings.temperatureUnit))
                    .foregroundColor(GaugeColor.forTemperature(snapshot.hardware.cpuTemperature))
        }

        return text
    }

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
