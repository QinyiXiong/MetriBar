//
//  HeartRateCollector.swift
//  MetriBar
//
//  用 CoreBluetooth 直连支持「广播心率」的手表（如 Garmin fenix 8），
//  订阅标准心率服务 0x180D 的 Heart Rate Measurement 特征 0x2A37，
//  实时把心率投给采集引擎。离线、不经云端、秒级更新。
//
//  ── 为什么走 BLE 标准心率服务 ─────────────────────────────────
//   · fenix 8 在「广播心率」模式下作为 BLE peripheral 广播标准 HRP（0x180D），
//     Mac 当 central 直接连上订阅即可拿到心率，无需配对、无需 SDK。
//   · macOS 无 ANT+ 无线，且 ANT+ USB 棒不在考虑范围 → BLE HRP 是最干净的路。
//   · App Sandbox 已关闭 + Info.plist 声明 NSBluetoothAlwaysUsageDescription，
//     Central Bluetooth 正常可用（首次会弹「允许访问蓝牙」）。
//
//  ── 线程模型 ───────────────────────────────────────────────────
//   · CBCentralManager 挂在自有串行队列 com.qyx.MetriBar.ble，
//     回调不会回到主线程，也不会占用采集队列。
//   · 可变状态用 NSLock 保护，采集引擎每 tick 只做一次无锁读 → 无阻塞。
//

import Foundation
import CoreBluetooth

/// 心率采集器（单例）。主线程读状态，BLE 回调在自有队列。
final class HeartRateCollector: NSObject, @unchecked Sendable {

    static let shared = HeartRateCollector()

    // MARK: - 状态模型

    enum Status: Sendable, Equatable {
        case unavailable      // 未启用采集（菜单栏没勾「心率」）
        case poweredOff       // 蓝牙关闭
        case unauthorized     // 系统未授予蓝牙权限
        case scanning         // 正在搜索手表
        case connecting       // 已找到，正在连接
        case connected        // 已订阅心率通知
        case disconnected     // 曾连接后断开，等待重连

        var text: String {
            switch self {
            case .unavailable:  return "心率显示已关闭"
            case .poweredOff:   return "蓝牙未开启"
            case .unauthorized: return "请在系统设置允许蓝牙"
            case .scanning:     return "正在搜索手表…"
            case .connecting:   return "连接中…"
            case .connected:    return "已连接"
            case .disconnected: return "已断开，重连中…"
            }
        }

        var isActive: Bool { self == .poweredOff || self == .unauthorized ? false : true }
    }

    struct Reading: Sendable {
        var status: Status = .unavailable
        var bpm: Int?
        var sensorContact: Bool?
        var deviceName: String?
        var updatedAt: Date = .distantPast

        var isConnected: Bool { status == .connected }
    }

    // MARK: - UUID（Bluetooth SIG 标准心率服务）

    static let hrService = CBUUID(string: "180D")
    static let hrChar    = CBUUID(string: "2A37")

    // MARK: - 状态

    // CoreBluetooth 的 delegate 回调需要投递到**带 RunLoop 的队列**；
    // 纯 GCD 串行队列不跑 RunLoop，会导致 didUpdateState 永不触发（实测踩过）。
    // 心率回调极轻量，直接用主队列最稳；可变状态另用 NSLock 跨线程保护。
    private let queue = DispatchQueue.main
    private var central: CBCentralManager?
    private weak var peripheral: CBPeripheral?
    /// 记住最近一次连上的设备，断线重连优先找它。
    private var rememberedID: UUID?

    private let lock = NSLock()
    private var reading = Reading()
    private var reconnectTimer: DispatchSourceTimer?

    private override init() { super.init() }

    // MARK: - 对外只读快照（线程安全，采集引擎每 tick 调用）

    func current() -> Reading {
        lock.withLock { reading }
    }

    /// 供采集器内部更新并广播状态。
    private func mutate(_ body: (inout Reading) -> Void) {
        lock.withLock { body(&reading) }
        NotificationCenter.default.post(name: .metriBarHeartState, object: nil)
    }

    // MARK: - 生命周期

    /// 幂等启动。创建 CBCentralManager 并按当前设置决定是否扫描。
    func start() {
        queue.async {
            // 幂等：已建就直接用（蓝牙可能早已上电/正在扫）。
            if self.central != nil { return }
            Diag.notice(Diag.lifecycle, "心率采集启动：连接支持广播心率的 BLE 手表")
            self.mutate { $0.status = .scanning }   // 乐观置「搜索中」，别误显示"已关闭"
            // allowDuplicates 关闭，标准心率服务过滤，省电且噪声低。
            self.central = CBCentralManager(delegate: self, queue: self.queue)
        }
    }

    func stop() {
        queue.async {
            self.reconnectTimer?.cancel(); self.reconnectTimer = nil
            if let p = self.peripheral { self.central?.cancelPeripheralConnection(p) }
            self.central?.stopScan()
            self.peripheral = nil
            self.mutate { $0.status = .unavailable; $0.bpm = nil }
        }
    }

    /// 重新扫描（换设备 / 改名称过滤后调用）。已连接则断开重扫。
    func rescan() {
        queue.async {
            guard let c = self.central, c.state == .poweredOn else { return }
            if let p = self.peripheral { c.cancelPeripheralConnection(p); self.peripheral = nil }
            self.rememberedID = nil
            self.beginScan()
        }
    }

    /// 当前期望的设备名过滤（小写）。空串=接受任何广播心率服务的设备。
    private func nameFilter() -> String {
        (UserDefaults.standard.string(forKey: AppSettings.Keys.heartDeviceNameFilter) ?? "fenix")
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func beginScan() {
        guard let central, central.state == .poweredOn else { return }
        if central.isScanning { central.stopScan() }
        // 只扫标准心率服务：fenix 8 在「广播心率」时会广播 0x180D。
        central.scanForPeripherals(withServices: [Self.hrService], options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        mutate { $0.status = .scanning }
    }

    private func scheduleReconnect() {
        reconnectTimer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1.5)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            // 优先重连记住的设备（仍在缓存列表里就直接 connect，省一次扫描）。
            if let id = self.rememberedID,
               let known = self.central?.retrievePeripherals(withIdentifiers: [id]).first {
                self.peripheral = known
                self.connect(known)
            } else {
                self.beginScan()
            }
        }
        t.resume()
        reconnectTimer = t
    }

    private func connect(_ p: CBPeripheral) {
        rememberedID = p.identifier
        self.peripheral = p
        mutate { $0.deviceName = p.name ?? $0.deviceName; $0.status = .connecting }
        p.delegate = self
        central?.connect(p, options: nil)
    }

    // MARK: - 心率报文解析（0x2A37）
    //  layout: flags(1) [HR] (uint8 | uint16) [RR intervals…]
    //  flags bit0: 0 = 心率 uint8，1 = 心率 uint16；bit1-2: 传感器接触状态。

    private func parseHeartRate(_ data: Data) {
        guard !data.isEmpty else { return }
        let flags = data[data.startIndex]
        let is16Bit = (flags & 0x01) != 0
        let byte2 = (flags & 0x06) >> 1                 // 接触状态位
        let contact: Bool? = (flags & 0x04) != 0 ? ((byte2 & 0x01) == 1) : nil

        var bpm: Int?
        if is16Bit, data.count >= 3 {
            let b = [UInt8](data)
            bpm = (Int(b[1]) << 8) | Int(b[2])
        } else if data.count >= 2 {
            bpm = Int([UInt8](data)[1])
        }
        guard let value = bpm, (20...260).contains(value) else { return }
        mutate { $0.bpm = value; $0.sensorContact = contact ?? $0.sensorContact; $0.updatedAt = Date() }
    }
}

// MARK: - CBCentralManagerDelegate

extension HeartRateCollector: CBCentralManagerDelegate {

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            Diag.notice(Diag.lifecycle, "蓝牙：已上电，开始搜索手表")
            if let id = rememberedID, let known = central.retrievePeripherals(withIdentifiers: [id]).first {
                peripheral = known
                connect(known)
            } else {
                beginScan()
            }
        case .poweredOff:
            Diag.notice(Diag.lifecycle, "蓝牙：未开启（请在系统设置打开蓝牙）")
            mutate { $0.status = .poweredOff; $0.bpm = nil }
        case .unauthorized:
            Diag.notice(Diag.lifecycle, "蓝牙：未授权（系统设置›隐私与安全›蓝牙 允许 MetriBar）")
            mutate { $0.status = .unauthorized; $0.bpm = nil }
        default:
            Diag.notice(Diag.lifecycle, "蓝牙：状态不可用（central.state=\(central.state.rawValue)）")
            mutate { $0.status = .poweredOff; $0.bpm = nil }
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = peripheral.name ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
        // 名称过滤（默认 fenix）；留空则接受任何广播心率服务的设备。
        let filter = nameFilter()
        if !filter.isEmpty {
            guard let n = name?.lowercased(), n.contains(filter) else { return }
        }
        central.stopScan()
        connect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Diag.notice(Diag.lifecycle, "心率：已连接 \(peripheral.name ?? "未知设备")，发现服务中")
        peripheral.discoverServices([Self.hrService])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        Diag.notice(Diag.lifecycle, "心率：连接失败 \(error?.localizedDescription ?? "")，稍后重连")
        mutate { $0.status = .disconnected }
        scheduleReconnect()
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        Diag.notice(Diag.lifecycle, "心率：连接断开（\(peripheral.name ?? "")），1.5s 后重连")
        mutate { $0.status = .disconnected }
        scheduleReconnect()
    }
}

// MARK: - CBPeripheralDelegate

extension HeartRateCollector: CBPeripheralDelegate {

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let service = peripheral.services?.first(where: { $0.uuid == Self.hrService }) else {
            Diag.notice(Diag.lifecycle, "心率：没找到 0x180D 服务，确认手表已开启「广播心率」")
            mutate { $0.status = .disconnected }
            return
        }
        peripheral.discoverCharacteristics([Self.hrChar], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let ch = service.characteristics?.first(where: { $0.uuid == Self.hrChar }) else {
            Diag.notice(Diag.lifecycle, "心率：没找到 0x2A37 特征")
            return
        }
        peripheral.setNotifyValue(true, for: ch)
        // 有的设备需要 read 兜底拿首帧。
        if ch.properties.contains(.read) { peripheral.readValue(for: ch) }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == Self.hrChar, let data = characteristic.value else { return }
        if reading.status != .connected {
            mutate { $0.status = .connected; $0.deviceName = peripheral.name ?? $0.deviceName }
            Diag.notice(Diag.lifecycle, "心率：已就绪，开始接收 \(peripheral.name ?? "手表") 心率")
        }
        parseHeartRate(data)
    }
}
