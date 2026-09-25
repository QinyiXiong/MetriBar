//
//  NetworkCollector.swift
//  MetriBar
//
//  通过 getifaddrs() 读取 AF_LINK 地址上的 if_data 字节计数器，
//  两次采样做差求实时速率。全部在工作线程执行，不涉及主线程。
//

import Foundation
import Darwin

/// 网卡实时速率采集器。非线程安全：只允许被 MetricsEngine 的串行队列访问。
final class NetworkCollector {

    /// 白名单前缀：只统计真实物理出口，天然过滤 lo0 回环。
    /// en* = Wi-Fi / 有线 / 雷雳网桥端口，pdp_ip* = 蜂窝网络。
    ///
    /// 有意排除的接口：
    /// - lo0            本地回环（需求明确要求过滤）
    /// - utun*/ipsec*   VPN 隧道，其流量已由物理网卡计入，重复统计会翻倍
    /// - awdl0/llw0/nan0/ap1  Handoff、Nearby、热点等内部通道
    /// - bridge0        与成员 en* 重复计费
    /// - gif0/stf0      6to4 / IPv6 隧道
    /// - anpi*          无线裸接口（无用户流量）
    /// - vmnet*/vmen*   虚拟机虚拟网卡
    static let monitoredPrefixes: [String] = ["en", "pdp_ip"]

    private struct Counters {
        var inBytes: UInt64
        var outBytes: UInt64
    }

    private var previous: [String: Counters] = [:]
    private var previousTime: CFTimeInterval = 0

    /// 睡眠唤醒、网卡插拔或修改采集间隔后调用，避免把空闲时间算成流量。
    func resetBaseline() {
        previous.removeAll()
        previousTime = 0
    }

    static func isMonitored(_ interface: String) -> Bool {
        monitoredPrefixes.contains { interface.hasPrefix($0) }
    }

    /// 读取当前所有被监控网卡的累计字节数。
    private func readCounters() -> [String: Counters] {
        var result: [String: Counters] = [:]

        var apiPointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&apiPointer) == 0, let first = apiPointer else { return result }
        defer { freeifaddrs(apiPointer) }

        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let item = cursor {
            defer { cursor = item.pointee.ifa_next }

            guard let address = item.pointee.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_LINK) else { continue }

            let name = String(cString: item.pointee.ifa_name)
            guard Self.isMonitored(name) else { continue }

            // 计数器在 ifa_data（不是 ifa_addr！）。
            // macOS 上 AF_LINK 的 ifa_addr 是 sockaddr_dl，它的头部偏移上
            // 恰好能读到一些看着"像"字节数的数字（比如 ifi_baudrate），
            // 会让下行速率恒定不动，必须从 ifa_data 取。
            guard let counterPointer = item.pointee.ifa_data else { continue }

            let data = UnsafeRawPointer(counterPointer)
                .assumingMemoryBound(to: if_data.self)
                .pointee

            result[name] = Counters(
                // truncatingIfNeeded 同时兼容 Int32 / UInt32 两种 SDK 声明
                inBytes: UInt64(truncatingIfNeeded: data.ifi_ibytes),
                outBytes: UInt64(truncatingIfNeeded: data.ifi_obytes)
            )
        }
        return result
    }

    /// if_data 计数器是 UInt32（约 4 GiB 回绕一次），跨 tick 求差时补正一次回绕。
    static func delta(from oldValue: UInt64, to newValue: UInt64) -> UInt64 {
        if newValue >= oldValue {
            return newValue - oldValue
        }
        let wrapped = (UInt64(UInt32.max) &- oldValue) &+ newValue
        // 补正后仍不合理（例如网卡驱动重置计数器）时按 0 处理，避免读数爆表。
        return wrapped > 8 * 1_024 * 1_024 * 1_024 ? 0 : wrapped
    }

    /// 采样一次并返回速率。`now` 由调用方提供（建议 CACurrentMediaTime()， monotonic）。
    func sample(now: CFTimeInterval) -> NetworkSnapshot {
        let current = readCounters()

        guard previousTime > 0, !previous.isEmpty else {
            previous = current
            previousTime = now
            // 首次采样只建立基线，速率未知。
            return NetworkSnapshot(downBps: 0, upBps: 0, activeInterfaces: [], ready: false)
        }

        let elapsed = now - previousTime
        // 间隔异常（睡眠、时钟跳变）视为基线失效。
        guard elapsed > 0.05, elapsed < 30 else {
            previous = current
            previousTime = now
            return NetworkSnapshot(downBps: 0, upBps: 0, activeInterfaces: [], ready: false)
        }

        var interfaces: [InterfaceRate] = []
        var totalDown: Double = 0
        var totalUp: Double = 0

        for (name, counters) in current {
            guard let old = previous[name] else { continue }   // 新出现的网卡本 tick 只建基线

            let inDelta = Self.delta(from: old.inBytes, to: counters.inBytes)
            let outDelta = Self.delta(from: old.outBytes, to: counters.outBytes)
            if Diag.verbose {
                Diag.notice(Diag.metrics, "\(name) in \(old.inBytes)->\(counters.inBytes) Δ\(inDelta)"
                    + " | out \(old.outBytes)->\(counters.outBytes) Δ\(outDelta)"
                    + " | elapsed=\(String(format: "%.3f", elapsed))")
            }

            let down = Double(inDelta) / elapsed
            let up = Double(outDelta) / elapsed

            totalDown += down
            totalUp += up
            interfaces.append(InterfaceRate(id: name, downBps: down, upBps: up))
        }

        previous = current
        previousTime = now

        interfaces.sort { $0.downBps + $0.upBps > $1.downBps + $1.upBps }

        return NetworkSnapshot(
            downBps: totalDown,
            upBps: totalUp,
            activeInterfaces: interfaces,
            ready: true
        )
    }
}
