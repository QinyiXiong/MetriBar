//
//  CPULoadCollector.swift
//  MetriBar
//
//  CPU 总占用率：host_statistics(HOST_CPU_LOAD_INFO) 的 ticks 做差。
//  （CPU 温度走 SMC，见 SMCSensorReader；这里只是面板里补充的占用率。）
//

import Foundation
import Darwin

/// CPU 负载采集器。非线程安全：只允许被 MetricsEngine 的串行队列访问。
struct CPULoadCollector {

    private struct Ticks {
        var user: UInt32
        var system: UInt32
        var idle: UInt32
        var nice: UInt32

        var total: UInt64 {
            UInt64(user) + UInt64(system) + UInt64(idle) + UInt64(nice)
        }
    }

    private var previous: Ticks?

    mutating func reset() { previous = nil }

    mutating func sample() -> CPUSnapshot {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.stride
        )

        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return .empty }

        let current = Ticks(
            user: info.cpu_ticks.0,
            system: info.cpu_ticks.1,
            idle: info.cpu_ticks.2,
            nice: info.cpu_ticks.3
        )
        defer { previous = current }

        guard let old = previous else { return .empty }
        let totalDelta = Double(current.total - old.total)
        guard totalDelta > 0 else { return .empty }

        let idleDelta = Double(current.idle - old.idle)
        let userDelta = Double(current.user - old.user + current.nice - old.nice)
        let systemDelta = Double(current.system - old.system)

        return CPUSnapshot(
            total: min(max(1.0 - idleDelta / totalDelta, 0), 1),
            user: min(max(userDelta / totalDelta, 0), 1),
            system: min(max(systemDelta / totalDelta, 0), 1)
        )
    }
}
