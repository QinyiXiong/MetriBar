//
//  PopoverView.swift
//  MetriBar
//
//  点击菜单栏图标弹出的监控面板。
//  原生观感：ultraThinMaterial 背景 + 圆角卡片 + 深浅色自适应。
//

import SwiftUI

@MainActor
struct PopoverView: View {
    @EnvironmentObject private var store: MetricsStore
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            networkSection

            // SMC 与 GPU 任一可用就显示硬件区（虚拟机里可能只有 GPU）。
            if store.snapshot.hardware.available || store.snapshot.gpu.available {
                hardwareSection
            }

            memorySection
            diskSection
            footer
        }
        .padding(12)
        .frame(width: 286)
        .background(.ultraThinMaterial)
    }

    private var snapshot: MetricsSnapshot { store.snapshot }

    // MARK: - 头部

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Circle()
                .fill(store.isNetworkReady ? Color(nsColor: .systemGreen) : Color.secondary.opacity(0.6))
                .frame(width: 6, height: 6)

            Text("MetriBar")
                .font(.system(size: 13, weight: .semibold))

            Spacer()

            Text(store.isNetworkReady ? "实时" : "建立基线…")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.secondary)
        }
        .padding(.bottom, 2)
    }

    // MARK: - 网络

    private var networkSection: some View {
        PanelSection(title: "网络") {
            MetricRow(
                systemImage: "arrow.down",
                title: "下载",
                value: Fmt.speed(snapshot.network.downBps, unit: settings.speedUnit)
            )
            SlimGauge(fraction: store.fraction(of: snapshot.network.downBps), color: Color(nsColor: .controlAccentColor))

            MetricRow(
                systemImage: "arrow.up",
                title: "上传",
                value: Fmt.speed(snapshot.network.upBps, unit: settings.speedUnit)
            )
            SlimGauge(fraction: store.fraction(of: snapshot.network.upBps), color: Color(nsColor: .controlAccentColor).opacity(0.6))

            HStack(spacing: 4) {
                Image(systemName: "network")
                    .font(.system(size: 10))
                Text(interfaceSummary)
                    .font(.system(size: 10))
            }
            .foregroundColor(.secondary)
            .lineLimit(1)
        }
    }

    private var interfaceSummary: String {
        guard let primary = snapshot.network.primaryInterface else {
            return "活动网卡：—"
        }
        let rest = snapshot.network.activeInterfaces
            .filter { $0.id != primary && !$0.isIdle }
            .count
        return rest > 0 ? "活动网卡：\(primary)（另有 \(rest) 块在传输）" : "活动网卡：\(primary)"
    }

    // MARK: - 硬件（SMC）

    private var hardwareSection: some View {
        PanelSection(title: "硬件 · SMC") {
            MetricRow(
                systemImage: "thermometer.medium",
                title: "CPU 温度",
                value: Fmt.temperature(snapshot.hardware.cpuTemperature, unit: settings.temperatureUnit),
                detail: snapshot.hardware.sensorKey
            )
            MetricRow(
                systemImage: "cpu",
                title: "CPU 占用",
                value: Fmt.percent(snapshot.cpu.total),
                detail: "用户 \(Fmt.percent(snapshot.cpu.user)) · 系统 \(Fmt.percent(snapshot.cpu.system))"
            )
            SlimGauge(fraction: snapshot.cpu.total, color: GaugeColor.forFraction(snapshot.cpu.total))

            // GPU 占用：IORegistry 的 GPU accelerator 节点（Apple Silicon 为 AGXAccelerator…）
            MetricRow(
                systemImage: "cpu.fill",
                title: "GPU 占用",
                value: snapshot.gpu.utilization.map { Fmt.percent($0) } ?? "--",
                detail: gpuDetail
            )
            SlimGauge(
                fraction: snapshot.gpu.utilization ?? 0,
                color: GaugeColor.forFraction(snapshot.gpu.utilization ?? 0)
            )

            if snapshot.hardware.hasFan {
                ForEach(snapshot.hardware.fans) { fan in
                    MetricRow(
                        systemImage: "fanblades",
                        title: fan.displayName,
                        value: Fmt.rpm(fan.rpm),
                        detail: fanRange(fan)
                    )
                    SlimGauge(fraction: fan.fraction, color: Color(nsColor: .controlAccentColor).opacity(0.75))
                }
            } else {
                Text("未检测到风扇（被动散热机型正常）")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
        }
    }

    /// GPU 明细：渲染 / 光栅占用 + IORegistry 节点名。
    private var gpuDetail: String? {
        let gpu = snapshot.gpu
        guard gpu.available else { return "未检测到 GPU 加速器" }
        var parts: [String] = []
        if let renderer = gpu.renderer { parts.append("渲染 \(Fmt.percent(renderer))") }
        if let tiler = gpu.tiler { parts.append("光栅 \(Fmt.percent(tiler))") }
        if let name = gpu.deviceName { parts.append(name) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func fanRange(_ fan: FanReading) -> String? {
        guard let minRPM = fan.minRPM, let maxRPM = fan.maxRPM else { return nil }
        return "\(Fmt.rpm(minRPM)) – \(Fmt.rpm(maxRPM))"
    }

    // MARK: - 内存

    private var memorySection: some View {
        PanelSection(title: "内存") {
            MetricRow(
                systemImage: "memorychip",
                title: "已用",
                value: "\(Fmt.volume(snapshot.memory.usedBytes)) / \(Fmt.volume(snapshot.memory.totalBytes))",
                detail: Fmt.percent(snapshot.memory.usedFraction)
            )
            SlimGauge(fraction: snapshot.memory.usedFraction, color: GaugeColor.forFraction(snapshot.memory.usedFraction))

            HStack(spacing: 8) {
                legendItem("App", Fmt.volume(snapshot.memory.appBytes))
                legendItem("联动", Fmt.volume(snapshot.memory.wiredBytes))
                legendItem("已压缩", Fmt.volume(snapshot.memory.compressedBytes))
                Spacer()
            }
        }
    }

    private func legendItem(_ name: String, _ value: String) -> some View {
        HStack(spacing: 3) {
            Text(name)
            Text(value).monospacedDigit()
        }
        .font(.system(size: 10))
        .foregroundColor(.secondary)
    }

    // MARK: - 磁盘

    private var diskSection: some View {
        PanelSection(title: "磁盘") {
            MetricRow(
                systemImage: "internaldrive",
                title: snapshot.disk.volumeName,
                value: Fmt.percent(snapshot.disk.usedFraction),
                detail: "可用 \(Fmt.volume(snapshot.disk.freeBytes)) / \(Fmt.volume(snapshot.disk.totalBytes))"
            )
            SlimGauge(fraction: snapshot.disk.usedFraction, color: GaugeColor.forFraction(snapshot.disk.usedFraction))
        }
    }

    // MARK: - 底部

    private var footer: some View {
        HStack(spacing: 8) {
            Label("\(settings.intervalText) 刷新", systemImage: "arrow.triangle.2.circlepath")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .labelStyle(.titleAndIcon)

            Spacer()

            SettingsGearButton()

            Button {
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "power")
            }
            .buttonStyle(.plain)
            .help("退出 MetriBar")
        }
        .foregroundColor(.secondary)
        .padding(.top, 2)
    }
}
