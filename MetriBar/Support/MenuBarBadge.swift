//
//  MenuBarBadge.swift
//  MetriBar
//
//  菜单栏徽章：用 NSAttributedString/Core Text 把整段排版画成一张**固定尺寸**的
//  高分辨率非模板位图，交给 MenuBarExtra 当 label。
//
//  为什么要绕这一圈（全是实测结论）：
//   1. `MenuBarExtra` 的 label 会被 macOS 状态栏按 **template** 重绘：颜色被抹平，
//      `Text("\(Image(systemName:))")` 里的 SF Symbol 直接不显示（只剩字面字符）。
//      → 必须自己生成位图，并设 `isTemplate = false`。
//   2. 如果直接让 SwiftUI/HStack 随内容变宽，状态项会跟着数字长度左右抖动。
//      → 这里给每段预先分配**固定槽宽**，整图尺寸恒定。
//   3. NSHostingView 的离屏缓存只按窗口倍率、且默认不开字体平滑，文字会发虚。
//      → 这里按主屏 backingScaleFactor 生成像素，并显式开启抗锯齿 + 字体平滑。
//

import AppKit
import CoreText

/// 一段指标：图标 + 数值 + 单位 + 颜色。
struct MenuBarSegment: Equatable {
    let symbol: String
    let value: String
    let unit: String
    let rgb: SIMD3<Double>

    init(symbol: String, value: String, unit: String = "", color: NSColor) {
        self.symbol = symbol
        self.value = value
        self.unit = unit
        let c = color.usingColorSpace(.sRGB) ?? color
        rgb = SIMD3(Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent))
    }

    var color: NSColor {
        NSColor(srgbRed: rgb.x, green: rgb.y, blue: rgb.z, alpha: 1)
    }
}

@MainActor
enum MenuBarBadge {

    /// 背景风格。Rich 默认胶囊底，Compact / 特殊场景可无底。
    enum Background: String, CaseIterable, Identifiable, Sendable {
        case pill
        case none

        var id: String { rawValue }
        var label: String { self == .pill ? "胶囊底" : "无底" }
    }

    // MARK: - 排版规格（所有宽高/字号集中一处）

    private enum Spec {
        static let badgeHeight: CGFloat = 16
        static let pillPadX: CGFloat = 6
        static let pillPadY: CGFloat = 1
        static let gap: CGFloat = 3
        static let segmentGap: CGFloat = 4
        static let dividerWidth: CGFloat = 1

        static let iconPointSize: CGFloat = 10
        static let valueFont: NSFont = monospaced(ofSize: 11.5, weight: .semibold)
        static let unitFont: NSFont = system(ofSize: 8, weight: .medium)

        /// 统一图标槽：用最宽候选（温度计）量一次。
        static let iconSlotWidth: CGFloat = ceil(max(
            symbolWidth("thermometer.medium", pointSize: iconPointSize),
            symbolWidth("cpu", pointSize: iconPointSize),
            symbolWidth("cube", pointSize: iconPointSize),
            symbolWidth("arrow.down", pointSize: iconPointSize),
            symbolWidth("arrow.up", pointSize: iconPointSize)
        ))

        /// 统一「数值 + 单位」槽：整体左对齐紧跟图标，空位在段尾吸收；
        /// 这样 `13K`、`295K`、`1.5M` 之间不会把数字和单位拆开留缝。
        static let textSlotWidth: CGFloat = ceil(max(
            attributedWidth(value: "999", unit: "K", valueColor: .black, unitColor: .gray),
            attributedWidth(value: "88.8", unit: "K", valueColor: .black, unitColor: .gray),
            attributedWidth(value: "999", unit: "M", valueColor: .black, unitColor: .gray),
            attributedWidth(value: "100", unit: "%", valueColor: .black, unitColor: .gray),
            attributedWidth(value: "100", unit: "\u{00B0}F", valueColor: .black, unitColor: .gray),
            attributedWidth(value: "0", unit: "", valueColor: .black, unitColor: .gray)
        ))

        static func system(ofSize size: CGFloat, weight: NSFont.Weight) -> NSFont {
            NSFont.systemFont(ofSize: size, weight: weight)
        }

        static func monospaced(ofSize size: CGFloat, weight: NSFont.Weight) -> NSFont {
            let base = NSFont.systemFont(ofSize: size, weight: weight)
            let descriptor = base.fontDescriptor.addingAttributes([
                .featureSettings: [
                    [
                        NSFontDescriptor.FeatureKey.typeIdentifier: kNumberSpacingType,
                        NSFontDescriptor.FeatureKey.selectorIdentifier: kMonospacedNumbersSelector
                    ]
                ]
            ])
            return NSFont(descriptor: descriptor, size: 0) ?? base
        }

        static func textWidth(_ text: String, _ font: NSFont) -> CGFloat {
            (text as NSString).size(withAttributes: [.font: font]).width
        }

        static func attributedWidth(value: String, unit: String, valueColor: NSColor, unitColor: NSColor) -> CGFloat {
            let text = NSMutableAttributedString()
            if !value.isEmpty {
                text.append(NSAttributedString(string: value, attributes: [.font: valueFont, .foregroundColor: valueColor]))
            }
            if !unit.isEmpty {
                text.append(NSAttributedString(string: unit, attributes: [.font: unitFont, .foregroundColor: unitColor]))
            }
            return text.size().width
        }

        static func symbolWidth(_ name: String, pointSize: CGFloat) -> CGFloat {
            let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .bold)
            guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                    .withSymbolConfiguration(config) else { return 10 }
            return image.size.width
        }
    }

    // MARK: - 缓存

    private static var cache: [(key: String, image: NSImage)] = []
    private static let cacheLimit = 16

    /// SF Symbol 染色缓存：按名称 + 颜色复用，避免每秒重新生成小图标。
    private static var symbolCache: [String: NSImage] = [:]

    // MARK: - 对外入口

    /// 生成或复用菜单栏徽章位图。
    static func image(
        segments: [MenuBarSegment],
        background: Background = .pill,
        dark: Bool = true
    ) -> NSImage {
        let key = cacheKey(segments: segments, background: background, dark: dark)
        if let hit = cache.first(where: { $0.key == key }) { return hit.image }

        let scale = max(2.0, NSScreen.main?.backingScaleFactor ?? 2.0)
        let segmentWidth = Spec.iconSlotWidth + Spec.gap + Spec.textSlotWidth
        var contentWidth: CGFloat = 0
        for index in segments.indices {
            if index > 0 { contentWidth += Spec.segmentGap + Spec.dividerWidth + Spec.segmentGap }
            contentWidth += segmentWidth
        }

        let pill = background == .pill
        let totalSize = NSSize(
            width: ceil(contentWidth + (pill ? Spec.pillPadX * 2 : 4)),
            height: ceil(Spec.badgeHeight + (pill ? Spec.pillPadY * 2 : 0))
        )

        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(ceil(totalSize.width * scale)),
            pixelsHigh: Int(ceil(totalSize.height * scale)),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            Diag.warning(Diag.lifecycle, "徽章渲染失败：无法分配位图")
            return NSImage(size: totalSize)
        }
        bitmap.size = totalSize   // 关键点：这里给的是 point 尺寸，系统按 scale 映射到 pixel

        guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            return NSImage(size: totalSize)
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context

        let cg = context.cgContext
        cg.setShouldAntialias(true)
        cg.setAllowsFontSmoothing(true)
        cg.setShouldSmoothFonts(true)

        let bounds = NSRect(origin: .zero, size: totalSize)
        if pill { drawPill(in: bounds, dark: dark) }

        let leftInset = pill ? Spec.pillPadX : 2
        var x = leftInset
        // Core Text 以 baseline 为锚点：按数值字体的 cap height 垂直居中，单位同基线对齐。
        let baselineY = baselineY(for: Spec.valueFont, in: bounds.height)

        for (index, segment) in segments.enumerated() {
            if index > 0 {
                drawDivider(atX: x + Spec.segmentGap, height: bounds.height, dark: dark)
                x += Spec.segmentGap + Spec.dividerWidth + Spec.segmentGap
            }

            drawSymbol(segment.symbol, tint: segment.color, atX: x, slot: Spec.iconSlotWidth, height: bounds.height, scale: scale)
            x += Spec.iconSlotWidth + Spec.gap

            drawSegmentText(
                value: segment.value,
                unit: segment.unit,
                valueColor: .metricLabel(dark),
                unitColor: .metricSecondary(dark),
                atX: x,
                baselineY: baselineY
            )
            x += Spec.textSlotWidth
        }

        NSGraphicsContext.restoreGraphicsState()

        let image = NSImage(size: totalSize)
        image.addRepresentation(bitmap)
        image.isTemplate = false   // 关键：不让状态栏把它重新抹成单色
        image.accessibilityDescription = accessibilityText(segments: segments)

        cache.append((key, image))
        if cache.count > cacheLimit { cache.removeFirst(cache.count - cacheLimit) }
        return image
    }

    /// 设置页预览，和真实菜单栏走同一渲染。
    static func preview(segments: [MenuBarSegment], background: Background = .pill, dark: Bool) -> NSImage {
        image(segments: segments, background: background, dark: dark)
    }

    /// 自检：用几个宽度差异最大的样本确认固定槽位没有把总宽改掉。
    static func selfTest() {
        let samples: [[MenuBarSegment]] = [
            [
                MenuBarSegment(symbol: "arrow.down", value: "0", unit: "", color: .secondaryLabelColor),
                MenuBarSegment(symbol: "arrow.up", value: "0", unit: "", color: .secondaryLabelColor),
                MenuBarSegment(symbol: "thermometer.low", value: "--", unit: "", color: .secondaryLabelColor)
            ],
            [
                MenuBarSegment(symbol: "arrow.down", value: "295", unit: "K", color: .systemBlue),
                MenuBarSegment(symbol: "arrow.up", value: "13", unit: "K", color: .systemOrange),
                MenuBarSegment(symbol: "thermometer.medium", value: "67", unit: "\u{00B0}", color: .systemYellow)
            ],
            [
                MenuBarSegment(symbol: "arrow.down", value: "888", unit: "MB", color: .systemBlue),
                MenuBarSegment(symbol: "arrow.up", value: "99.9", unit: "M", color: .systemOrange),
                MenuBarSegment(symbol: "cpu", value: "100", unit: "%", color: .systemRed)
            ]
        ]

        let sizes = samples.map { image(segments: $0, background: .pill, dark: true).size }
        let first = sizes.first ?? .zero
        let stable = sizes.allSatisfy { abs($0.width - first.width) < 0.5 && abs($0.height - first.height) < 0.5 }
        if stable {
            Diag.notice(Diag.lifecycle, "徽章宽度自检：稳定 \(Int(first.width))x\(Int(first.height))pt（样本数 \(sizes.count)）")
        } else {
            Diag.warning(Diag.lifecycle, "徽章宽度自检：仍在抖动 \(sizes.map { "\(Int($0.width))x\(Int($0.height))" }.joined(separator: ", "))")
        }
    }

    static var isDark: Bool {
        NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    /// 自检：读取真实状态栏按钮图像属性。
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
                let rep = image.representations.first as? NSBitmapImageRep
                Diag.notice(
                    Diag.lifecycle,
                    "状态栏按钮：image \(Int(image.size.width))x\(Int(image.size.height))pt isTemplate=\(image.isTemplate) 像素 \(rep?.pixelsWide ?? 0)x\(rep?.pixelsHigh ?? 0)"
                )
            }
        }
        if found == 0 {
            Diag.warning(Diag.lifecycle, "状态栏按钮自检：没找到 NSStatusBarButton")
        }
    }

    // MARK: - 绘制细节

    private static func drawPill(in rect: NSRect, dark: Bool) {
        let path = NSBezierPath(
            roundedRect: rect.insetBy(dx: 0.5, dy: 0.5),
            xRadius: rect.height / 2,
            yRadius: rect.height / 2
        )
        (dark ? NSColor(srgbRed: 0.10, green: 0.11, blue: 0.13, alpha: 0.62)
             : NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.72)).setFill()
        path.fill()

        (dark ? NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.14)
             : NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.12)).setStroke()
        path.lineWidth = 0.5
        path.stroke()
    }

    private static func drawDivider(atX x: CGFloat, height: CGFloat, dark: Bool) {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: x, y: height * 0.28))
        path.line(to: NSPoint(x: x, y: height * 0.72))
        (dark ? NSColor.white.withAlphaComponent(0.28) : NSColor.black.withAlphaComponent(0.25)).setStroke()
        path.lineWidth = 0.6
        path.stroke()
    }

    private static func drawSymbol(
        _ name: String,
        tint: NSColor,
        atX x: CGFloat,
        slot: CGFloat,
        height: CGFloat,
        scale: CGFloat
    ) {
        guard let image = tintedSymbol(name: name, tint: tint, scale: scale) else { return }
        let rect = NSRect(
            x: (x + (slot - image.size.width) / 2).rounded(),
            y: ((height - image.size.height) / 2).rounded(),
            width: image.size.width,
            height: image.size.height
        )
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
    }

    /// 在独立透明位图中给 SF Symbol 上色。
    /// 不能直接在外层胶囊位图上 `sourceAtop`：那会把整个已有背景都刷成主题色。
    private static func tintedSymbol(name: String, tint: NSColor, scale: CGFloat) -> NSImage? {
        let key = symbolCacheKey(name: name, tint: tint)
        if let hit = symbolCache[key] { return hit }

        let config = NSImage.SymbolConfiguration(pointSize: Spec.iconPointSize, weight: .bold)
        guard let source = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(config) else { return nil }

        let size = NSSize(
            width: max(1, ceil(source.size.width)),
            height: max(1, ceil(source.size.height))
        )
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(ceil(size.width * scale)),
            pixelsHigh: Int(ceil(size.height * scale)),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }
        bitmap.size = size

        guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        let cg = context.cgContext
        cg.setShouldAntialias(true)

        source.draw(in: NSRect(origin: .zero, size: size), from: .zero, operation: .sourceOver, fraction: 1)
        let rect = NSRect(origin: .zero, size: size)
        cg.setFillColor(tint.cgColor)
        cg.setBlendMode(.sourceAtop)
        cg.fill(rect)
        cg.setBlendMode(.normal)

        NSGraphicsContext.restoreGraphicsState()

        let image = NSImage(size: size)
        image.addRepresentation(bitmap)
        image.isTemplate = false
        symbolCache[key] = image
        return image
    }

    private static func drawSegmentText(
        value: String,
        unit: String,
        valueColor: NSColor,
        unitColor: NSColor,
        atX x: CGFloat,
        baselineY: CGFloat
    ) {
        guard let cg = NSGraphicsContext.current?.cgContext else { return }
        let text = NSMutableAttributedString()
        if !value.isEmpty {
            text.append(NSAttributedString(string: value, attributes: [.font: Spec.valueFont, .foregroundColor: valueColor]))
        }
        if !unit.isEmpty {
            text.append(NSAttributedString(string: unit, attributes: [.font: Spec.unitFont, .foregroundColor: unitColor]))
        }
        guard text.length > 0 else { return }

        let line = CTLineCreateWithAttributedString(text)
        cg.textMatrix = .identity
        cg.textPosition = NSPoint(x: x.rounded(), y: baselineY.rounded())
        CTLineDraw(line, cg)
    }

    /// 数字的视觉中心落在徽章中间：基线放在「底部起 (height - capHeight) / 2」。
    private static func baselineY(for font: NSFont, in height: CGFloat) -> CGFloat {
        ((height - font.capHeight) / 2).rounded(.down)
    }

    // MARK: - Cache key

    private static func symbolCacheKey(name: String, tint: NSColor) -> String {
        guard let c = tint.usingColorSpace(.sRGB) else { return "\(name)|\(tint.hashValue)" }
        let r = Int((c.redComponent * 255).rounded())
        let g = Int((c.greenComponent * 255).rounded())
        let b = Int((c.blueComponent * 255).rounded())
        let a = Int((c.alphaComponent * 100).rounded())
        return "\(name)|\(r)-\(g)-\(b)-\(a)"
    }

    private static func cacheKey(segments: [MenuBarSegment], background: Background, dark: Bool) -> String {
        let body = segments.map { "\($0.symbol):\($0.value)\($0.unit)" }.joined(separator: ",")
        return "\(background.rawValue)|\(dark ? "d" : "l")|\(body)"
    }

    private static func accessibilityText(segments: [MenuBarSegment]) -> String {
        segments.map { "\($0.value)\($0.unit)" }.joined(separator: " ")
    }
}

private extension NSColor {
    static func metricLabel(_ dark: Bool) -> NSColor {
        dark ? NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.96)
             : NSColor(srgbRed: 0.11, green: 0.12, blue: 0.14, alpha: 1)
    }

    static func metricSecondary(_ dark: Bool) -> NSColor {
        dark ? NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.62)
             : NSColor(srgbRed: 0.11, green: 0.12, blue: 0.14, alpha: 0.6)
    }
}
