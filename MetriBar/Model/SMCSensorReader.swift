//
//  SMCSensorReader.swift
//  MetriBar
//
//  SMC（System Management Controller）读取封装，基于开源库 SMCKit：
//  https://github.com/srimanachanta/SMCKit  (MIT)
//
//  职责：
//   1. 校验 AppleSMC 服务是否可用（App Sandbox 必须关闭，否则打不开 IOService）；
//   2. 启动时探测本机可用的 CPU 温度键与风扇键（Intel / Apple Silicon 键名不同）；
//   3. 每个采集 tick 读取温度与转速，按 SMC 数据类型正确解码。
//
//  全部工作都在后台执行（actor + 由 MetricsEngine 的工作队列驱动），不占用主线程。
//

import Foundation
import IOKit
import SMC      // SMCBytes_t 定义在这个 C target 里
import SMCKit

/// SMC 传感器读取器。actor 保证跨线程访问安全（SMCKit 本身也是 actor）。
actor SMCSensorReader {

    // MARK: - 键名候选表

    /// Intel Mac 常见 CPU 封装温度键（多为 sp78，8.8 定点）。
    static let intelTemperatureKeys: [String] = [
        "TC0P", "TC0D", "TC0E", "TC0F", "TCAD", "TCXC",
        "TCFH", "TCFR", "TCPP", "TCPR", "TCHP", "TCDX",
    ]

    /// Apple Silicon（M 系列）常见 CPU 温度键（多为 flt，IEEE-754）。
    /// 在 MacBook Pro (M5 Max) 上实测可读：Tp0C / Tp0R / Tp04 / Tp08 / Tp1E。
    static let appleSiliconTemperatureKeys: [String] = [
        "Tp0C", "Tp0R", "Tp04", "Tp08", "Tp1E", "Tp0T",
        "Tp09", "Tp01", "Tp05", "Tp0B", "Tp0H", "Tp0Q",
        "Tp0S", "Tp0O", "Tp0K", "Tp0G", "Tc0C", "Tc0D",
    ]

    /// 合理温度区间；超出即认为该键无效（空载传感器常返回 0 或乱码）。
    static let plausibleTemperature: ClosedRange<Double> = 5...125

    private struct ResolvedKey {
        let name: String
        let code: FourCharCode
    }

    private struct FanKeys {
        let index: Int
        let actual: ResolvedKey
        /// 上下限在启动时读一次即可（运行期不变），避免每 tick 多打两次 SMC。
        let minimumRPM: Double?
        let maximumRPM: Double?
    }

    // MARK: - 运行时状态

    private(set) var isAvailable = false
    private(set) var isPrepared = false
    private var temperatureKeys: [ResolvedKey] = []
    private var fanKeys: [FanKeys] = []

    private var prefersAppleSiliconKeys: Bool {
        #if arch(arm64) || arch(arm)
        return true
        #else
        return false
        #endif
    }

    // MARK: - 可用性检查

    /// 在触碰 `SMCKit.shared`（内部用 `try!`，失败即崩溃）之前，先确认 AppleSMC 服务存在。
    static func isSMCAvailable() -> Bool {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        if service != 0 {
            IOObjectRelease(service)
            return true
        }
        return false
    }

    // MARK: - 启动探测（只跑一次）

    func prepareIfNeeded() async {
        guard !isPrepared else { return }

        guard Self.isSMCAvailable() else {
            isAvailable = false
            isPrepared = true
            Diag.warning(Diag.smc, "AppleSMC 服务不可用：温度与风扇将显示 --（沙箱未关闭或虚拟机环境）")
            return
        }
        isAvailable = true

        let candidates = prefersAppleSiliconKeys
            ? Self.appleSiliconTemperatureKeys + Self.intelTemperatureKeys
            : Self.intelTemperatureKeys + Self.appleSiliconTemperatureKeys

        for name in candidates {
            guard temperatureKeys.count < 8, let code = Self.fourCharCode(name) else { continue }
            if let value = await readValue(code), Self.plausibleTemperature.contains(value) {
                temperatureKeys.append(ResolvedKey(name: name, code: code))
            }
        }

        // 候选表全部落空时，做一次全量枚举兜底（约 3~4k 键，仅启动执行一次）。
        if temperatureKeys.isEmpty {
            await discoverTemperatureKeysByScan()
        }

        await discoverFans()
        isPrepared = true

        Diag.notice(
            Diag.smc,
            "传感器解析完成：温度键 [\(temperatureKeys.map(\.name).joined(separator: " "))]"
                + " 风扇 \(fanKeys.count) 个"
        )
        if temperatureKeys.isEmpty {
            Diag.warning(Diag.smc, "未找到可读的 CPU 温度键")
        }
    }

    private func discoverTemperatureKeysByScan() async {
        guard let all = try? await SMCKit.shared.allKeys() else { return }
        for code in all {
            guard temperatureKeys.count < 8 else { break }
            let name = code.toString()
            // 只看 CPU 封装族：Tp*（Apple Silicon）、TC*/Tc*（Intel），避免混入 SSD / 电池温度。
            guard name.hasPrefix("Tp") || name.hasPrefix("TC") || name.hasPrefix("Tc") else { continue }
            if let value = await readValue(code), Self.plausibleTemperature.contains(value) {
                temperatureKeys.append(ResolvedKey(name: name, code: code))
            }
        }
    }

    private func discoverFans() async {
        guard let countValue = await readValue(Self.code("FNum")) else { return }
        let fanCount = Int(countValue.rounded())
        guard fanCount > 0, fanCount <= 8 else { return }

        for index in 0..<fanCount {
            guard let actualName = Self.name("F\(index)Ac"),
                  let actualCode = Self.fourCharCode(actualName) else { continue }
            guard await readValue(actualCode) != nil else { continue }

            let minimum = await Self.readOnceIfPresent(Self.name("F\(index)Mn"))
            let maximum = await Self.readOnceIfPresent(Self.name("F\(index)Mx"))

            fanKeys.append(FanKeys(
                index: index,
                actual: ResolvedKey(name: actualName, code: actualCode),
                minimumRPM: minimum,
                maximumRPM: maximum
            ))
        }
    }

    private static func readOnceIfPresent(_ name: String?) async -> Double? {
        guard let name, let code = fourCharCode(name) else { return nil }
        // 上下限偶尔不可读，失败时返回 nil 即可。
        guard let info = try? await SMCKit.shared.getKeyInformation(code) else { return nil }
        let raw: RawBytes? = try? await SMCKit.shared.read(code)
        return Self.decode(type: info.type, bytes: raw?.bytes)
    }

    // MARK: - 采样

    /// 采集一次硬件快照。CPU 温度取所有可用封装传感器的最高值（最保守读数）。
    func sample() async -> HardwareSnapshot {
        // 必须先探测：isAvailable 是在 prepareIfNeeded() 里才置位的，
        // 提前 guard 会让硬件区永远显示 --。
        await prepareIfNeeded()
        guard isAvailable else { return .empty }

        var peak: Double?
        var peakKey: String?

        for key in temperatureKeys {
            guard let value = await readValue(key.code),
                  Self.plausibleTemperature.contains(value) else { continue }
            if peak == nil || value > peak! {
                peak = value
                peakKey = key.name
            }
        }

        var fans: [FanReading] = []
        for fan in fanKeys {
            guard let rpm = await readValue(fan.actual.code) else { continue }
            fans.append(FanReading(
                id: fan.index,
                rpm: rpm,
                minRPM: fan.minimumRPM,
                maxRPM: fan.maximumRPM,
                displayName: "风扇 \(fan.index + 1)",
                sensorKey: fan.actual.name
            ))
        }

        return HardwareSnapshot(
            available: true,
            cpuTemperature: peak,
            sensorKey: peakKey,
            fans: fans
        )
    }

    /// 备用：读取指定键的当前值（设置页自检用）。
    func readKeyValue(_ name: String) async -> Double? {
        guard isAvailable, let code = Self.fourCharCode(name) else { return nil }
        return await readValue(code)
    }

    // MARK: - 解码

    /// SMC 不同类型编码不同，必须按 keyInfo.type 解码：
    /// - `flt ` Apple Silicon：IEEE-754 单精度（小端，原生 load）
    /// - `sp78` Intel CPU 温度：8.8 有定点，大端，除数 256
    /// - `fpe6` Intel 风扇转速：定点，大端，除数 64
    /// - `ui8 ` / `ui16`：无符号整数（SMCKit 已按大端解析）
    private func readValue(_ key: FourCharCode) async -> Double? {
        guard let info = try? await SMCKit.shared.getKeyInformation(key) else { return nil }
        let raw: RawBytes? = try? await SMCKit.shared.read(key)
        return Self.decode(type: info.type, bytes: raw?.bytes)
    }

    static func decode(type: FourCharCode, bytes raw: [UInt8]?) -> Double? {
        guard let bytes = raw, !bytes.isEmpty else { return nil }
        switch type.toString() {
        case "flt ":
            guard bytes.count >= 4 else { return nil }
            let raw = UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
            return Double(Float(bitPattern: raw))
        case "sp78":
            guard bytes.count >= 2 else { return nil }
            let signed = Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1]))
            return Double(signed) / 256.0
        case "fpe6":
            guard bytes.count >= 2 else { return nil }
            return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1])) / 64.0
        case "ui8 ":
            return Double(bytes[0])
        case "si16":
            guard bytes.count >= 2 else { return nil }
            return Double(Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1])))
        case "ui16":
            guard bytes.count >= 2 else { return nil }
            return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1]))
        default:
            return nil
        }
    }

    // MARK: - 工具

    static func code(_ string: String) -> FourCharCode {
        fourCharCode(string) ?? 0
    }

    static func name(_ string: String) -> String? {
        string.utf8.count == 4 ? string : nil
    }

    static func fourCharCode(_ string: String) -> FourCharCode? {
        let bytes = Array(string.utf8)
        guard bytes.count == 4 else { return nil }
        return UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3])
    }
}

/// 不做类型假设的原始字节载体。
///
/// SMCKit 的 `read<V: SMCCodable>(_:)` 要求一个遵循 `SMCCodable` 的类型，
/// 而我们需要按 `getKeyInformation` 返回的真实类型自行解码，
/// 因此用这个壳把 SMC 的 32 字节缓冲区原样取回来。
struct RawBytes: SMCCodable, Sendable {

    /// SMC 一次返回的原始字节（32 字节缓冲区，实际有效长度由 keyInfo.size 决定）。
    let bytes: [UInt8]

    /// 仅写路径需要；本 App 只读，占位为 `flt `。
    static var smcDataType: DataType { Float.smcDataType }

    init(_ raw: SMCBytes_t) throws {
        bytes = withUnsafeBytes(of: raw) { Array($0) }
    }

    func encode() throws -> SMCBytes_t {
        var buffer = [UInt8](repeating: 0, count: 32)
        buffer.replaceSubrange(0..<min(bytes.count, 32), with: bytes)
        return buffer.withUnsafeBytes { $0.load(as: SMCBytes_t.self) }
    }
}
