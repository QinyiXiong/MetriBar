//
//  L10n.swift
//  MetriBar
//
//  本地化基础设施（中 / 英）。
//
//  设计要点：
//   · **中文原文即 key**：SwiftUI 的 `Text("中文")` 本身就走 `LocalizedStringKey`，
//     只要 String Catalog（Localizable.xcstrings）里有该条目，无需改动调用点即可本地化；
//     非 SwiftUI 场景（AppKit 标题、NSAlert、模型层状态串）用 `L10n.t("中文")` 包一层即可。
//   · **内部状态不做本地化**：`task.status == "完成"` 这类比较继续用中文常量，
//     只在**显示边界**（赋值给 Text / NSTextField 时）翻译，避免动到业务逻辑与自测断言。
//   · 语言切换：写入 `AppleLanguages` 并由用户点「立即重启」生效（SwiftUI 与 Bundle 解析都吃这个键，
//     重启后全量一致，不会出现"一半英文一半中文"的中间态）。
//

import Foundation

// MARK: - 语言选项

enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case system
    case zhHans = "zh-Hans"
    case en

    var id: String { rawValue }

    /// 设置界面里的显示名（用各自语言自称，不随当前语言变化）
    var label: String {
        switch self {
        case .system: return "跟随系统 / System"
        case .zhHans: return "简体中文"
        case .en:     return "English"
        }
    }

    /// 写入 AppleLanguages 的值；system 返回 nil（删除键，交还系统决定）
    var appleLanguageCode: String? {
        switch self {
        case .system: return nil
        case .zhHans: return "zh-Hans"
        case .en:     return "en"
        }
    }

    static let defaultsKey = "appLanguage"
}

// MARK: - 查表

enum L10n {

    /// 当前生效语言（按 AppleLanguages 实际解析结果，而非设置项，便于自检与调试）
    static var effectiveLanguageCode: String {
        let langs = UserDefaults.standard.array(forKey: "AppleLanguages") as? [String]
        if let first = langs?.first, !first.isEmpty { return first }
        return Locale.preferredLanguages.first ?? "en"
    }

    static var isEnglish: Bool { effectiveLanguageCode.lowercased().hasPrefix("en") }

    /// 查表：找到译文返回译文，找不到返回 key 本身（= 中文原文），永不返回空串。
    static func t(_ key: String) -> String {
        let v = Bundle.main.localizedString(forKey: key, value: nil, table: nil)
        return v.isEmpty ? key : v
    }

    /// 带参数的查表：key 为含 %@ / %d 的原文格式串
    static func t(_ key: String, _ args: CVarArg...) -> String {
        String(format: t(key), arguments: args)
    }

    /// 供自测/测试台用：强制指定语言查表（不改全局状态）
    static func t(_ key: String, language: String) -> String {
        guard let path = Bundle.main.path(forResource: language, ofType: "lproj"),
              let bundle = Bundle(path: path) else { return key }
        let v = bundle.localizedString(forKey: key, value: nil, table: nil)
        return v.isEmpty ? key : v
    }
}
