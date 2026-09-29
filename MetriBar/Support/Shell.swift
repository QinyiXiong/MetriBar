//
//  Shell.swift
//  MetriBar
//
//  工具箱共用：轻量执行外部命令（阻塞式，调用方自行放后台线程）。
//

import Foundation

enum Shell {
    @discardableResult
    static func run(_ launchPath: String, _ args: [String], env: [String: String]? = nil) -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = args
        if let env { p.environment = env }
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (-1, "启动失败：\(error.localizedDescription)") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
}
