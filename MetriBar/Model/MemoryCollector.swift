//
//  MemoryCollector.swift
//  MetriBar
//
//  通过 host_statistics64(HOST_VM_INFO64) 读取 VM 统计，
//  按「活动监视器」口径计算已用内存：App + Wired + Compressed。
//

import Darwin
import Foundation

/// 内存采集器。无状态，只允许被 MetricsEngine 的串行队列访问。
struct MemoryCollector {

    func sample() -> MemorySnapshot {
        let total = UInt64(ProcessInfo.processInfo.physicalMemory)

        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride
        )

        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else {
            return MemorySnapshot(
                totalBytes: total,
                usedBytes: 0,
                appBytes: 0,
                wiredBytes: 0,
                compressedBytes: 0
            )
        }

        // 活动监视器口径：
        //   App Memory  = internal_page_count（匿名内存）− purgeable_count
        //   Memory Used = App + Wired + Compressed
        // 注意：不能把 inactive / speculative 算进 App Memory——那绝大部分是可回收的
        // 文件缓存，会把占用率顶到 100%。
        let pageSize = UInt64(vm_kernel_page_size)
        let wired = UInt64(stats.wire_count) * pageSize
        let compressed = UInt64(stats.compressor_page_count) * pageSize
        let purgeable = UInt64(stats.purgeable_count) * pageSize
        let anonymous = UInt64(stats.internal_page_count) * pageSize

        let app = anonymous > purgeable ? anonymous - purgeable : 0
        let used = app + wired + compressed

        return MemorySnapshot(
            totalBytes: total,
            usedBytes: min(used, total),
            appBytes: app,
            wiredBytes: wired,
            compressedBytes: compressed
        )
    }
}
