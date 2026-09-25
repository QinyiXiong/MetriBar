//
//  Diagnostics.swift
//  MetriBar
//
//  统一日志入口。用 Console.app 或命令行排查：
//
//    log stream --predicate 'subsystem == "com.qyx.MetriBar"' --level debug
//
//  逐 tick 明细默认关闭（避免长期占用日志空间），排查时打开：
//
//    defaults write com.qyx.MetriBar MetriBarVerboseLogging -bool YES
//    # 然后重新启动 MetriBar
//

import Foundation
import os.log

enum Diag {

    static let subsystem = "com.qyx.MetriBar"

    /// 采集节拍与数值。
    static let metrics = Logger(subsystem: subsystem, category: "metrics")
    /// SMC 可用性、传感器键解析、风扇枚举。
    static let smc = Logger(subsystem: subsystem, category: "smc")
    /// 引擎启停、刷新间隔变更、登录项。
    static let lifecycle = Logger(subsystem: subsystem, category: "lifecycle")

    /// 是否输出逐 tick 明细。
    static let verbose: Bool = UserDefaults.standard.bool(forKey: Keys.verboseLogging)

    enum Keys {
        static let verboseLogging = "MetriBarVerboseLogging"
    }

    /// 普通信息（会被持久化，便于用户提交日志排查）。
    static func notice(_ log: Logger, _ message: String) {
        log.notice("\(message, privacy: .public)")
    }

    /// 调试信息（默认不落盘，`--level debug` 才可见）。
    static func debug(_ log: Logger, _ message: String) {
        log.debug("\(message, privacy: .public)")
    }

    /// 异常/降级（例如 SMC 不可用、快照未就绪）。
    static func warning(_ log: Logger, _ message: String) {
        log.warning("\(message, privacy: .public)")
    }
}
