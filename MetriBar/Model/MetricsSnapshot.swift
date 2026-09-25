//
//  MetricsSnapshot.swift
//  MetriBar
//
//  采集数据的不可变快照（值类型）。采集端在工作线程生成，主线程只读渲染。
//

import Foundation

// MARK: - 网络

/// 单个网卡的实时速率。
struct InterfaceRate: Identifiable, Sendable {
    let id: String          // 网卡名，如 en0
    let downBps: Double     // Byte/s
    let upBps: Double       // Byte/s

    var isIdle: Bool { downBps < 1 && upBps < 1 }
}

/// 网络快照：主网卡 + 合计速率。
struct NetworkSnapshot: Sendable {
    static let empty = NetworkSnapshot(downBps: 0, upBps: 0, activeInterfaces: [], ready: false)

    let downBps: Double
    let upBps: Double
    let activeInterfaces: [InterfaceRate]
    /// false 表示刚启动/刚从睡眠唤醒，仍在建立基线。
    let ready: Bool

    /// 当前主要活动网卡名（流量最大的那块）。
    var primaryInterface: String? {
        activeInterfaces.filter { !$0.isIdle }.max { $0.downBps + $0.upBps < $1.downBps + $1.upBps }?.id
    }

    var peakBps: Double { max(downBps, upBps) }
}

// MARK: - 硬件（SMC）

/// 单个风扇读数。
struct FanReading: Identifiable, Sendable {
    let id: Int             // 风扇序号 0-based
    let rpm: Double
    let minRPM: Double?
    let maxRPM: Double?
    let displayName: String
    /// 实际命中的 SMC key，便于排障。
    let sensorKey: String

    /// 用于画进度条的占比（无上下限时退化为 0.5，仅表示"在转"）。
    var fraction: Double {
        guard let minRPM, let maxRPM, maxRPM > minRPM else { return 0 }
        return min(max((rpm - minRPM) / (maxRPM - minRPM), 0), 1)
    }
}

/// SMC 硬件快照。温度取所有 CPU 封装传感器中的最高值（最保守读数）。
struct HardwareSnapshot: Sendable {
    static let empty = HardwareSnapshot(available: false, cpuTemperature: nil, sensorKey: nil, fans: [])

    /// SMC 是否可用（沙盒已关但设备无 AppleSMC / 权限异常时为 false）。
    let available: Bool
    let cpuTemperature: Double?
    /// 实际命中的 SMC key，便于排查机型适配问题。
    let sensorKey: String?
    let fans: [FanReading]

    var hasFan: Bool { !fans.isEmpty }
}

// MARK: - 内存

struct MemorySnapshot: Sendable {
    static let empty = MemorySnapshot(totalBytes: 0, usedBytes: 0, appBytes: 0, wiredBytes: 0, compressedBytes: 0)

    let totalBytes: UInt64
    let usedBytes: UInt64
    let appBytes: UInt64
    let wiredBytes: UInt64
    let compressedBytes: UInt64

    var freeBytes: UInt64 { totalBytes > usedBytes ? totalBytes - usedBytes : 0 }
    var usedFraction: Double { totalBytes > 0 ? Double(usedBytes) / Double(totalBytes) : 0 }
}

// MARK: - 磁盘

struct DiskSnapshot: Sendable {
    static let empty = DiskSnapshot(volumeName: "—", totalBytes: 0, freeBytes: 0, ready: false)

    let volumeName: String
    let totalBytes: UInt64
    let freeBytes: UInt64
    let ready: Bool

    var usedBytes: UInt64 { totalBytes > freeBytes ? totalBytes - freeBytes : 0 }
    var usedFraction: Double { totalBytes > 0 ? Double(usedBytes) / Double(totalBytes) : 0 }
}

// MARK: - CPU 负载（host_statistics，非 SMC）

struct CPUSnapshot: Sendable {
    static let empty = CPUSnapshot(total: 0, user: 0, system: 0)

    let total: Double     // 0...1
    let user: Double
    let system: Double
}

// MARK: - GPU 负载（IORegistry PerformanceStatistics）

struct GPUSnapshot: Sendable {
    static let empty = GPUSnapshot(available: false, utilization: nil, renderer: nil, tiler: nil, deviceName: nil)

    /// 是否读到 GPU 加速器节点（虚拟机 / 无 Metal 设备时为 false）。
    let available: Bool
    /// 设备总占用，0...1（已平滑）。
    let utilization: Double?
    /// 渲染核心占用 0...1，部分机型不提供。
    let renderer: Double?
    /// 光栅化（Tiler）占用 0...1。
    let tiler: Double?
    /// IORegistry 节点名，例如 AGXAcceleratorG17X，便于排障。
    let deviceName: String?
}

// MARK: - 聚合快照

/// 一次完整采集的结果。整棵树只读，可安全跨越线程传递。
struct MetricsSnapshot: Sendable {
    static let empty = MetricsSnapshot(
        network: .empty,
        hardware: .empty,
        memory: .empty,
        disk: .empty,
        cpu: .empty,
        gpu: .empty,
        timestamp: .distantPast
    )

    let network: NetworkSnapshot
    let hardware: HardwareSnapshot
    let memory: MemorySnapshot
    let disk: DiskSnapshot
    let cpu: CPUSnapshot
    let gpu: GPUSnapshot
    let timestamp: Date

    var isValid: Bool { timestamp != .distantPast }
}
