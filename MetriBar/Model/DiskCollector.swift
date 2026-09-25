//
//  DiskCollector.swift
//  MetriBar
//
//  磁盘状态采集：优先系统启动盘，其次第一块内置卷。
//  用 URLResourceValues（底层 statfs），开销极小。
//

import Foundation

/// 磁盘采集器。纯值类型，无状态；由 MetricsEngine 的工作队列调用。
struct DiskCollector {

    func sample() -> DiskSnapshot {
        let keys: Set<URLResourceKey> = [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey,
            .volumeNameKey,
            .volumeIsInternalKey,
            .volumeIsBrowsableKey,
        ]

        guard let urls = mountedVolumes(keys) else { return .empty }

        var fallback: DiskSnapshot?

        for url in urls {
            guard let values = try? url.resourceValues(forKeys: keys),
                  let total = values.volumeTotalCapacity,
                  total > 0 else { continue }

            // 跳过只读系统快照卷、网络卷与不可浏览卷。
            if values.volumeIsBrowsable == false { continue }

            let free = values.volumeAvailableCapacity ?? 0
            let name = values.volumeName ?? url.lastPathComponent

            let snapshot = DiskSnapshot(
                volumeName: name,
                totalBytes: UInt64(total),
                freeBytes: UInt64(max(free, 0)),
                ready: true
            )

            // 启动盘优先；否则取第一块内置盘。
            if url.path == "/" { return snapshot }
            if values.volumeIsInternal == true { return snapshot }
            if fallback == nil { fallback = snapshot }
        }

        return fallback ?? .empty
    }

    /// 不使用 `try?`：新 SDK 上该 API 非 throwing（旧 SDK 仍兼容）。
    private func mountedVolumes(_ keys: Set<URLResourceKey>) -> [URL]? {
        FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: Array(keys),
            options: [.skipHiddenVolumes]
        )
    }
}
