//
//  MenuBarBadge.swift
//  MetriBar
//
//  把 SwiftUI 排版离屏渲染成「非模板」位图，交给 MenuBarExtra 当 label。
//
//  为什么要绕这一圈（实测结论，别再改回纯 Text/图标方案）：
//  `MenuBarExtra` 的 label 会被状态栏按 **template** 重绘：
//    · `foregroundColor` 全部被抹平成单色（蓝底白字那种系统反色）；
//    · `Text("\(Image(systemName: …))")` 里插的 SF Symbol **直接不显示**，
//      只剩字面字符 —— 用户截图里的 `2.3K│3.5K│54°` 就是这个现象。
//  解法：自己用 NSHostingView 把排版画成位图，标记 `isTemplate = false`，
//  在 SwiftUI 侧再叠一个 `.renderingMode(.original)`，颜色与图标即可原样保留。
//

import AppKit
import SwiftUI

@MainActor
enum MenuBarBadge {

    /// 缓存：菜单栏每 1–2 秒刷新一次，同内容（同一分钟/同一整数百分比）直接复用位图。
    private static var cache: [(key: String, image: NSImage)] = []
    private static let cacheLimit = 24

    /// - Parameters:
    ///   - content: 要渲染的视图（通常是拼好的单个 `Text`）。
    ///   - signature: 内容签名（用于缓存命中），一般传紧凑纯文本形式。
    ///   - dark: 期望的明暗外观，跟随系统 `effectiveAppearance`。
    static func image<Content: View>(
        _ content: Content,
        signature: String,
        dark: Bool,
        verticalPadding: CGFloat = 2.0
    ) -> NSImage {
        let key = "\(dark ? "d" : "l")|\(signature)"
        if let hit = cache.first(where: { $0.key == key }) { return hit.image }

        let wrapped = AnyView(content.padding(.vertical, verticalPadding))
        let hosting = NSHostingView(rootView: wrapped)
        hosting.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)

        var size = hosting.fittingSize
        // 状态栏可视高度约 22pt，内容再高会被裁；这里兜底一个合理尺寸。
        size.width = max(24, ceil(size.width))
        size.height = min(max(18, ceil(size.height)), 22)
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.layoutSubtreeIfNeeded()

        let rect = NSRect(origin: .zero, size: size)
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: rect) else {
            return NSImage(size: size)
        }
        hosting.cacheDisplay(in: rect, to: bitmap)

        let image = NSImage(size: size)
        image.addRepresentation(bitmap)
        image.isTemplate = false          // ← 关键：禁止状态栏把它抹成单色
        image.accessibilityDescription = signature

        cache.append((key, image))
        if cache.count > cacheLimit { cache.removeFirst(cache.count - cacheLimit) }
        return image
    }

    /// 自检：直接读取真实状态栏按钮上的图像属性。
    /// `isTemplate` 若被打回 true，说明系统又把 label 抹成单色（图标/颜色都会丢）。
    static func logStatusItem() {
        var found = 0
        for window in NSApp.windows {
            guard let content = window.contentView else { continue }
            var stack: [NSView] = [content]
            while !stack.isEmpty {
                let view = stack.removeLast()
                stack.append(contentsOf: view.subviews)
                guard let button = view as? NSStatusBarButton, let image = button.image else { continue }
                found += 1
                Diag.notice(
                    Diag.lifecycle,
                    "状态栏按钮：image \(Int(image.size.width))x\(Int(image.size.height))pt isTemplate=\(image.isTemplate) 像素 \(image.representations.first?.pixelsWide ?? 0)x\(image.representations.first?.pixelsHigh ?? 0) title=\u{201C}\(button.title)\u{201D}"
                )
            }
        }
        if found == 0 {
            Diag.warning(Diag.lifecycle, "状态栏按钮自检：没找到 NSStatusBarButton（label 可能未挂载）")
        }
    }

    /// 当前系统是否处于深色外观。
    static var isDark: Bool {
        NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }
}
