//
//  MenuBarLabelView.swift
//  MetriBar
//
//  菜单栏文本：只显示数值（下载 / 上传 / CPU 温度），不显示应用名称。
//

import SwiftUI

@MainActor
struct MenuBarLabelView: View {
    let snapshot: MetricsSnapshot
    let settings: AppSettings

    /// 菜单栏可用宽度有限：速率用极简格式，单位后缀极短。
    var body: some View {
        HStack(spacing: 5) {
            Text("↓" + Fmt.compactSpeed(snapshot.network.downBps))

            if settings.showUploadInMenuBar {
                Text("↑" + Fmt.compactSpeed(snapshot.network.upBps))
            }

            if settings.showCPUUsageInMenuBar {
                Text(Fmt.percent(snapshot.cpu.total))
                    .foregroundColor(GaugeColor.forFraction(snapshot.cpu.total))
            }

            if settings.showTemperatureInMenuBar {
                Text(Fmt.temperature(snapshot.hardware.cpuTemperature, unit: settings.temperatureUnit))
                    .foregroundColor(GaugeColor.forTemperature(snapshot.hardware.cpuTemperature))
            }
        }
        .font(.system(size: 11, weight: .medium, design: .default))
        .monospacedDigit()
        .foregroundColor(.primary)
        .fixedSize(horizontal: true, vertical: false)
        .help(hint)
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
        return lines.joined(separator: "\n")
    }
}
