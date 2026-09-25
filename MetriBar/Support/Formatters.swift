//
//  Formatters.swift
//  MetriBar
//
//  集中管理数值格式化：网速用十进制（网络惯例），内存/磁盘用二进制（Finder 惯例）。
//

import Foundation

/// 网速单位（十进制，1 KB/s = 1000 B/s，符合网络行业惯例）。
enum SpeedUnit: String, CaseIterable, Identifiable, Sendable {
    case auto
    case kilobytesPerSecond
    case megabytesPerSecond

    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto: return "自动"
        case .kilobytesPerSecond: return "KB/s"
        case .megabytesPerSecond: return "MB/s"
        }
    }

    var shortLabel: String {
        switch self {
        case .auto: return ""
        case .kilobytesPerSecond: return "K"
        case .megabytesPerSecond: return "M"
        }
    }
}

enum TemperatureUnit: String, CaseIterable, Identifiable, Sendable {
    case celsius
    case fahrenheit

    var id: String { rawValue }
    var symbol: String { self == .celsius ? "°C" : "°F" }
    var shortSymbol: String { self == .celsius ? "°" : "°F" }
    var label: String { self == .celsius ? "摄氏度 (°C)" : "华氏度 (°F)" }
}

enum Fmt {
    /// 菜单栏用的极简速率：`12.4M`、`980K`、`0`。
    static func compactSpeed(_ bytesPerSecond: Double) -> String {
        let v = max(bytesPerSecond, 0)
        switch v {
        case ..<1_000: return "0"
        case ..<999_500: return oneDecimal(v / 1_000) + "K"
        case ..<999_500_000: return oneDecimal(v / 1_000_000) + "M"
        default: return oneDecimal(v / 1_000_000_000) + "G"
        }
    }

    /// 面板用的完整速率：`12.4 MB/s`。
    static func speed(_ bytesPerSecond: Double, unit: SpeedUnit = .auto) -> String {
        let v = max(bytesPerSecond, 0)
        switch unit {
        case .kilobytesPerSecond:
            return String(format: "%.0f KB/s", v / 1_000)
        case .megabytesPerSecond:
            return String(format: "%.2f MB/s", v / 1_000_000)
        case .auto:
            switch v {
            case ..<1: return "0 B/s"
            case ..<1_000: return String(format: "%.0f B/s", v)
            case ..<1_000_000: return oneDecimal(v / 1_000) + " KB/s"
            case ..<1_000_000_000: return oneDecimal(v / 1_000_000) + " MB/s"
            default: return oneDecimal(v / 1_000_000_000) + " GB/s"
            }
        }
    }

    /// 二进制容量：`1.8 TB`、`742 GB`。
    static func volume(_ bytes: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .memory
        formatter.allowedUnits = [.useTB, .useGB, .useMB]
        formatter.includesUnit = true
        formatter.isAdaptive = true
        return formatter.string(fromByteCount: Int64(truncatingIfNeeded: bytes))
    }

    static func temperature(_ celsius: Double?, unit: TemperatureUnit = .celsius, showSymbol: Bool = true) -> String {
        guard let celsius else { return "--" }
        let value = unit == .celsius ? celsius : celsius * 9.0 / 5.0 + 32.0
        return String(format: "%.0f%@", value, showSymbol ? unit.shortSymbol : "")
    }

    static func percent(_ fraction: Double, digits: Int = 0) -> String {
        String(format: "%.\(digits)f%%", min(max(fraction, 0), 1) * 100)
    }

    static func rpm(_ value: Double) -> String {
        String(format: "%.0f RPM", value)
    }

    static func time(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }

    private static func oneDecimal(_ v: Double) -> String {
        // <10 保留一位小数，更大数值收紧宽度，保证菜单栏宽度稳定。
        String(format: v < 10 ? "%.1f" : "%.0f", v)
    }
}
