import Combine
//
//  PrinterTab.swift
//  MetriBar
//
//  打印机测试（复刻参考项目的完整能力，纯原生实现，零服务器）：
//   · CUPS 枚举打印机（lpstat）+ 默认机标记；
//   · 9 张测试图全部用 Core Graphics **现场自绘**为 A4 PDF（非打包资源，干净室）；
//   · 卡片网格预览、点开大图、单张/批量打印（lp -d）。
//

import SwiftUI
import AppKit

// MARK: - 执行外部命令的小工具（工具箱内共用）

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

// MARK: - 测试图自绘

/// A4 页面（pt）。图案按页面尺寸相对坐标绘制，预览/打印同一套代码。
enum PrintPage {
    static let w: CGFloat = 595.28
    static let h: CGFloat = 841.89
}

struct TestPattern: Identifiable {
    let id: String
    let title: String
    let blurb: String
    let colorLabel: String        // 「黑白」/「彩色」角标
    let draw: (CGSize, CGContext) -> Void

    // ---- 绘图小工具 -------------------------------------------------
    fileprivate static func col(_ hex: String, _ alpha: CGFloat = 1) -> CGColor {
        var s = hex; if s.hasPrefix("#") { s.removeFirst() }
        var v: UInt64 = 0; Scanner(string: s).scanHexInt64(&v)
        return CGColor(red: CGFloat((v >> 16) & 0xFF) / 255,
                       green: CGFloat((v >> 8) & 0xFF) / 255,
                       blue: CGFloat(v & 0xFF) / 255, alpha: alpha)
    }
    fileprivate static func text(_ s: String, _ x: CGFloat, _ y: CGFloat, _ size: CGFloat,
                                _ color: CGColor, ctx: CGContext, bold: Bool = false) {
        let font = NSFont.systemFont(ofSize: size, weight: bold ? .bold : .regular)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor(cgColor: color) as Any]
        (s as NSString).draw(at: CGPoint(x: x, y: y), withAttributes: attrs)
    }
}

enum PrinterPatterns {
    static let all: [TestPattern] = [
        TestPattern(id: "basic-bw", title: "黑白基础页", blurb: "文字、线条、几何与对比度总检。", colorLabel: "黑白") { size, ctx in
            let w = size.width, h = size.height
            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1)); ctx.fill(CGRect(origin: .zero, size: size))
            TestPattern.text("MetriBar 黑白基础测试", 40, h - 70, 24, .black, ctx: ctx, bold: true)
            TestPattern.text("打印质量总览 · 中文 / English / 1234567890", 40, h - 96, 12, PrinterPatterns.deepGray, ctx: ctx)
            // 形状行：描边→填充渐变圆
            for i in 0..<5 {
                let x = 40 + CGFloat(i) * 100
                ctx.setStrokeColor(.black); ctx.setLineWidth(2); ctx.strokeEllipse(in: CGRect(x: x, y: h - 240, width: 70, height: 70))
                ctx.setFillColor(PrinterPatterns.inkOn(i % 2 == 0)); ctx.fillEllipse(in: CGRect(x: x + 15, y: h - 225, width: 40, height: 40))
            }
            // 灰阶梯度带
            for i in 0..<10 {
                let g = CGFloat(i) / 9.0
                ctx.setFillColor(NSColor(white: g, alpha: 1).cgColor)
                ctx.fill(CGRect(x: 40, y: h - 320 - CGFloat(i) * 26, width: w - 80, height: 24))
            }
            // 复选框网格 + 小字段落
            var text = "细小文字清晰度校验段落 The quick brown fox jumps over the lazy dog. 0123456789 "
            for row in 0..<4 {
                for c in 0..<12 {
                    let x = 40 + CGFloat(c) * 42, y = h - 560 + CGFloat(row) * 42
                    ctx.setStrokeColor(.black); ctx.setLineWidth(1.5)
                    ctx.stroke(CGRect(x: x, y: y, width: 26, height: 26))
                    if (row * 12 + c) % 3 == 0 {
                        ctx.setLineWidth(3); ctx.beginPath()
                        ctx.move(to: CGPoint(x: x + 5, y: y + 13)); ctx.addLine(to: CGPoint(x: x + 11, y: y + 6)); ctx.addLine(to: CGPoint(x: x + 21, y: y + 20)); ctx.strokePath()
                    }
                }
            }
            TestPattern.text(text, 40, h - 620, 7, .black, ctx: ctx)
            TestPattern.text(text, 40, h - 640, 5, PrinterPatterns.deepGray, ctx: ctx)
            TestPattern.text("打印完成请对照检查：黑度饱满、无条纹、无偏斜。", 40, 40, 10, PrinterPatterns.midGray, ctx: ctx)
        },

        TestPattern(id: "basic-color", title: "彩色基础页", blurb: "CMYK+RGB 色块与饱和总检。", colorLabel: "彩色") { size, ctx in
            let w = size.width, h = size.height
            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1)); ctx.fill(CGRect(origin: .zero, size: size))
            TestPattern.text("MetriBar 彩色基础测试", 40, h - 70, 24, PrinterPatterns.ink, ctx: ctx, bold: true)
            let swatches: [(String, String)] = [("C 青", "00AEEF"), ("M 品红", "EC008C"), ("Y 黄", "FFF200"), ("K 黑", "231F20"),
                                                ("R 红", "FF3B30"), ("G 绿", "34C759"), ("B 蓝", "007AFF"), ("O 橙", "FF9500")]
            for (i, it) in swatches.enumerated() {
                let x = 40 + CGFloat(i % 4) * ((w - 80) / 4), y = h - 320 - CGFloat(i / 4) * 170
                let blk = CGRect(x: x, y: y, width: (w - 100) / 4, height: 120)
                ctx.setFillColor(TestPattern.col(it.1)); ctx.fill(blk)
                TestPattern.text(it.0, x, y - 24, 12, PrinterPatterns.ink, ctx: ctx)
            }
            TestPattern.text("色块应边界锐利、无串色；饱和不足说明墨路异常。", 40, 40, 10, PrinterPatterns.midGray, ctx: ctx)
        },

        TestPattern(id: "nozzle-check", title: "喷头堵塞检测", blurb: "四色细线阵：断线=堵头。", colorLabel: "彩色") { size, ctx in
            let w = size.width, h = size.height
            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1)); ctx.fill(CGRect(origin: .zero, size: size))
            TestPattern.text("喷头堵塞检测", 40, h - 70, 24, PrinterPatterns.ink, ctx: ctx, bold: true)
            let inks: [(String, CGColor)] = [("C", TestPattern.col("00AEEF")), ("M", TestPattern.col("EC008C")), ("Y", TestPattern.col("D4A800")), ("K", .black)]
            for (ci, ink) in inks.enumerated() {
                let x = 40 + CGFloat(ci) * ((w - 80) / 4)
                let bw = (w - 100) / 4
                TestPattern.text(ink.0, x, h - 120, 14, ink.1, ctx: ctx, bold: true)
                ctx.setStrokeColor(ink.1); ctx.setLineWidth(0.75)
                for i in 0..<60 {
                    let y = h - 140 - CGFloat(i) * ((h - 220) / 60)
                    ctx.beginPath(); ctx.move(to: CGPoint(x: x, y: y)); ctx.addLine(to: CGPoint(x: x + bw, y: y)); ctx.strokePath()
                }
            }
            TestPattern.text("任何一条线中断/变淡 → 对应颜色喷嘴堵塞，请清洗喷头。", 40, 40, 10, PrinterPatterns.midGray, ctx: ctx)
        },

        TestPattern(id: "color-gradient", title: "彩色渐变", blurb: "彩虹横向渐变过渡测试。", colorLabel: "彩色") { size, ctx in
            let w = size.width, h = size.height
            let steps = 360
            for i in 0..<steps {
                ctx.setFillColor(PrinterPatterns.hue(CGFloat(i) / CGFloat(steps)))
                ctx.fill(CGRect(x: 40 + CGFloat(i) * ((w - 80) / CGFloat(steps)), y: h - 420, width: (w - 80) / CGFloat(steps) + 1, height: 300))
            }
            for i in 0..<steps {
                ctx.setFillColor(PrinterPatterns.hue(CGFloat(i) / CGFloat(steps)))
                ctx.fill(CGRect(x: 40 + CGFloat(i) * ((w - 80) / CGFloat(steps)), y: h - 740, width: (w - 80) / CGFloat(steps) + 1, height: 300))
            }
            TestPattern.text("彩色渐变", 40, h - 70, 24, PrinterPatterns.ink, ctx: ctx, bold: true)
            TestPattern.text("渐变应平滑无台阶；明显断层=墨量或抖动异常。", 40, 40, 10, PrinterPatterns.midGray, ctx: ctx)
        },

        TestPattern(id: "grayscale-gradient", title: "灰度渐变", blurb: "白→黑 20 级灰阶过渡。", colorLabel: "黑白") { size, ctx in
            let w = size.width, h = size.height
            TestPattern.text("灰度渐变", 40, h - 70, 24, PrinterPatterns.ink, ctx: ctx, bold: true)
            let steps = 20
            for i in 0..<steps {
                let g = 1 - CGFloat(i) / CGFloat(steps - 1)
                ctx.setFillColor(NSColor(white: g, alpha: 1).cgColor)
                ctx.fill(CGRect(x: 40 + CGFloat(i) * ((w - 80) / CGFloat(steps)), y: h - 420, width: (w - 80) / CGFloat(steps) + 1, height: 300))
            }
            for i in 0..<steps {
                let g = CGFloat(i) / CGFloat(steps - 1)
                ctx.setFillColor(NSColor(white: g, alpha: 1).cgColor)
                ctx.fill(CGRect(x: 40 + CGFloat(i) * ((w - 80) / CGFloat(steps)), y: h - 740, width: (w - 80) / CGFloat(steps) + 1, height: 300))
            }
            TestPattern.text("深黑区应仍有可辨层次（下段）。", 40, 40, 10, PrinterPatterns.midGray, ctx: ctx)
        },

        TestPattern(id: "fine-lines", title: "精细线条", blurb: "线宽 2→0.25pt 分辨率测试。", colorLabel: "黑白") { size, ctx in
            let w = size.width, h = size.height
            TestPattern.text("精细线条", 40, h - 70, 24, PrinterPatterns.ink, ctx: ctx, bold: true)
            let widths: [CGFloat] = [2, 1.5, 1, 0.75, 0.5, 0.35, 0.25]
            for (gi, lw) in widths.enumerated() {
                let x = 40 + CGFloat(gi) * ((w - 80) / 7)
                TestPattern.text("\(lw)pt", x, h - 110, 9, PrinterPatterns.deepGray, ctx: ctx)
                ctx.setStrokeColor(.black); ctx.setLineWidth(lw)
                for i in 0..<40 {
                    let y = h - 130 - CGFloat(i) * 9
                    ctx.beginPath(); ctx.move(to: CGPoint(x: x, y: y)); ctx.addLine(to: CGPoint(x: x + (w - 90) / 7, y: y)); ctx.strokePath()
                }
                for i in 0..<12 {
                    let xx = x + CGFloat(i) * ((w - 90) / 7 / 12)
                    ctx.beginPath(); ctx.move(to: CGPoint(x: xx, y: h - 130)); ctx.addLine(to: CGPoint(x: xx, y: h - 490)); ctx.strokePath()
                }
            }
            TestPattern.text("最细组仍应可分辨、无粘连。", 40, 40, 10, PrinterPatterns.midGray, ctx: ctx)
        },

        TestPattern(id: "text-clarity", title: "文字清晰度", blurb: "4pt→36pt 中英字号阶梯。", colorLabel: "黑白") { size, ctx in
            let h = size.height
            TestPattern.text("文字清晰度", 40, h - 70, 24, PrinterPatterns.ink, ctx: ctx, bold: true)
            let ladder: [CGFloat] = [36, 24, 18, 14, 12, 10, 8, 6, 4]
            var y = h - 130
            for pt in ladder {
                TestPattern.text("字号 \(Int(pt))pt 混排 MetriBar 0123456789 打印质量", 40, y - pt, pt, .black, ctx: ctx)
                y -= pt + 34
            }
            TestPattern.text("最小两行应无缺笔断画。", 40, 40, 10, PrinterPatterns.midGray, ctx: ctx)
        },

        TestPattern(id: "color-accuracy", title: "色彩还原", blurb: "肤色/天空/植被参照色卡。", colorLabel: "彩色") { size, ctx in
            let w = size.width, h = size.height
            TestPattern.text("色彩还原参照卡", 40, h - 70, 24, PrinterPatterns.ink, ctx: ctx, bold: true)
            let patches: [(String, String)] = [("肤色-浅","F6D7C1"),("肤色-深","8C5A3C"),("天空","7EC8E3"),("云白","FAFAF8"),
                                               ("叶绿","4C8B2B"),("秋叶","D9A038"),("砖红","B4472E"),("海水","1B6F9C"),
                                               ("石墨","3C3C41"),("木色","A67B5B"),("薰衣草","9C8AC4"),("金","C9A227")]
            for (i, it) in patches.enumerated() {
                let x = 40 + CGFloat(i % 4) * ((w - 80) / 4), y = h - 130 - CGFloat(i / 4) * 210
                let blk = CGRect(x: x, y: y - 150, width: (w - 110) / 4, height: 150)
                ctx.setFillColor(TestPattern.col(it.1)); ctx.fill(blk)
                TestPattern.text(it.0, x, y - 16, 11, PrinterPatterns.ink, ctx: ctx)
            }
            TestPattern.text("与屏幕同色系对比接近即还原良好。", 40, 40, 10, PrinterPatterns.midGray, ctx: ctx)
        },

        TestPattern(id: "alignment-grid", title: "对齐与套准", blurb: "角标/十字/斜线检查进纸歪斜。", colorLabel: "黑白") { size, ctx in
            let w = size.width, h = size.height
            TestPattern.text("对齐 · 套准", 40, h - 70, 24, PrinterPatterns.ink, ctx: ctx, bold: true)
            ctx.setStrokeColor(.black); ctx.setLineWidth(1)
            let m: CGFloat = 36
            let corners = [CGPoint(x: m, y: h - m), CGPoint(x: w - m, y: h - m), CGPoint(x: m, y: m), CGPoint(x: w - m, y: m)]
            for c in corners {
                ctx.stroke(CGRect(x: c.x - 14, y: c.y - 14, width: 28, height: 28))
                ctx.beginPath(); ctx.move(to: CGPoint(x: c.x - 22, y: c.y)); ctx.addLine(to: CGPoint(x: c.x + 22, y: c.y))
                ctx.move(to: CGPoint(x: c.x, y: c.y - 22)); ctx.addLine(to: CGPoint(x: c.x, y: c.y + 22)); ctx.strokePath()
            }
            ctx.setLineWidth(0.5)
            ctx.beginPath(); ctx.move(to: CGPoint(x: m, y: h - 110)); ctx.addLine(to: CGPoint(x: w / 2, y: h / 2)); ctx.addLine(to: CGPoint(x: m, y: 110)); ctx.strokePath()
            ctx.beginPath(); ctx.move(to: CGPoint(x: w - m, y: h - 110)); ctx.addLine(to: CGPoint(x: w / 2, y: h / 2)); ctx.addLine(to: CGPoint(x: w - m, y: 110)); ctx.strokePath()
            // 中央靶心 + 方格
            let cx = w / 2, cy = h / 2
            for r: CGFloat in [120, 90, 60, 30] {
                ctx.strokeEllipse(in: CGRect(x: cx - r, y: cy - r, width: 2 * r, height: 2 * r))
            }
            ctx.setLineWidth(0.5)
            for i in 0...10 {
                let g = CGFloat(i) * ((w - 80) / 10)
                ctx.beginPath(); ctx.move(to: CGPoint(x: 40 + g, y: 120)); ctx.addLine(to: CGPoint(x: 40 + g, y: 360)); ctx.strokePath()
            }
            for i in 0...8 {
                let g = CGFloat(i) * (240 / 8)
                ctx.beginPath(); ctx.move(to: CGPoint(x: 40, y: 120 + g)); ctx.addLine(to: CGPoint(x: w - 40, y: 120 + g)); ctx.strokePath()
            }
            TestPattern.text("四角方框到页边等距、斜线对称 = 进纸无歪斜。", 40, 52, 10, PrinterPatterns.midGray, ctx: ctx)
        },
    ]

    static let ink = CGColor(red: 0.12, green: 0.14, blue: 0.2, alpha: 1)
    static func hue(_ t: CGFloat) -> CGColor { NSColor(hue: t, saturation: 0.95, brightness: 0.95, alpha: 1).cgColor }
    static let deepGray = NSColor(white: 0.35, alpha: 1).cgColor
    static let midGray = NSColor(white: 0.5, alpha: 1).cgColor
    static func inkOn(_ even: Bool) -> CGColor { even ? NSColor(white: 0, alpha: 1).cgColor : NSColor(white: 0.72, alpha: 1).cgColor }

    /// A4 PDF 数据（打印用）。
    static func pdf(_ pattern: TestPattern) -> Data? {
        var box = CGRect(origin: .zero, size: CGSize(width: PrintPage.w, height: PrintPage.h))
        let out = NSMutableData()
        guard let consumer = CGDataConsumer(data: out as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else { return nil }
        ctx.beginPDFPage(nil)
        setCtxTextContext(ctx, size: CGSize(width: PrintPage.w, height: PrintPage.h)) { pattern.draw(CGSize(width: PrintPage.w, height: PrintPage.h), ctx) }
        ctx.endPDFPage(); ctx.closePDF()
        return out as Data
    }

    /// 预览图：统一在 A4 虚拟坐标系绘制（与 PDF 完全同一比例），再等比缩放到卡片。
    static func preview(_ pattern: TestPattern, width: CGFloat = 236) -> NSImage? {
        let scale: CGFloat = 2
        let pxW = Int(width * scale), pxH = Int(width * scale * (PrintPage.h / PrintPage.w))
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pxW, pixelsHigh: pxH,
                                          bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                          colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        guard let g = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = g
        let ctx = g.cgContext
        ctx.scaleBy(x: CGFloat(pxW) / PrintPage.w, y: CGFloat(pxH) / PrintPage.h)
        pattern.draw(CGSize(width: PrintPage.w, height: PrintPage.h), ctx)
        NSGraphicsContext.restoreGraphicsState()
        let img = NSImage(size: NSSize(width: width, height: width * (PrintPage.h / PrintPage.w)))
        img.addRepresentation(rep)
        return img
    }

    private static func setCtxTextContext(_ ctx: CGContext, size: CGSize, _ body: () -> Void) {
        let g = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = g
        body(); NSGraphicsContext.restoreGraphicsState()
    }
}

// MARK: - CUPS 模型

@MainActor
final class PrinterModel: ObservableObject {
    @Published var printers: [String] = []
    @Published var selectedPrinter: String?
    @Published var statusText: String = ""
    @Published var busy: Bool = false
    @Published var toast: String?

    init() {
        // 关键：绝不能在 init（窗口 HostingController 事务中）同步跑 lpstat 并改 @Published，
        // 否则 SwiftUI AttributeGraph precondition 崩溃。延后一拍、后台执行、回主线程更新。
        DispatchQueue.main.async { [weak self] in self?.refresh() }
    }

    func refresh() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            // locale 不可信（中文系统输出「打印机X闲置」「用于X的设备」），
            // 改为结构化解析：lpstat -v 行内定位 URI（含 ://），URI 前的文字去掉
            // 「device for / 用于 …的设备」等本地化前后缀即为队列名。
            let (_, outV) = Shell.run("/usr/bin/lpstat", ["-v"])
            var names: [String] = []
            for raw in outV.split(separator: "\n") {
                let line = String(raw)
                guard let uriRange = line.range(of: "://") else { continue }
                // 反向扫描 URI scheme 头（ipp/ipps/dnssd/http…），scheme 之前即本地化包装文字
                var schemeStart = uriRange.lowerBound
                while schemeStart > line.startIndex {
                    let prev = line.index(before: schemeStart)
                    let c = line[prev]
                    if c.isLetter || c.isNumber || c == "+" || c == "-" || c == "." { schemeStart = prev } else { break }
                }
                var prefix = String(line[line.startIndex..<schemeStart])
                for junk in ["device for ", "用于", "的设备"] { prefix = prefix.replacingOccurrences(of: junk, with: "") }
                prefix = prefix.trimmingCharacters(in: CharacterSet(charactersIn: " :："))
                if !prefix.isEmpty { names.append(prefix) }
            }
            var def: String?
            let (_, outD) = Shell.run("/usr/bin/lpstat", ["-d"])
            if let r = outD.range(of: "[:：]\\s*(.+)$", options: .regularExpression) {
                let v = outD[r].dropFirst().trimmingCharacters(in: .whitespacesAndNewlines)
                if !v.isEmpty && !v.localizedCaseInsensitiveContains("unknown") { def = v }
            }
            let list = Array(Set(names)).sorted()
            DispatchQueue.main.async {
                self.printers = list
                if self.selectedPrinter == nil || !list.contains(self.selectedPrinter ?? "") {
                    self.selectedPrinter = def ?? list.first
                }
                self.statusText = list.isEmpty ? "未检测到打印机" : "检测到 \(list.count) 台打印机"
                Diag.notice(Diag.lifecycle, "工具箱·打印机：\(list) 默认=\(def ?? "-")")
            }
        }
    }

    func print(_ pattern: TestPattern) {
        if busy { return }
        guard let data = PrinterPatterns.pdf(pattern) else { toast = "生成测试页失败"; return }
        busy = true
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("metribar-\(pattern.id).pdf")
        do { try data.write(to: tmp) } catch { busy = false; toast = "写入临时文件失败"; return }
        var args = ["-t", "MetriBar · \(pattern.title)"]
        if let p = selectedPrinter { args += ["-d", p] }
        args.append(tmp.path)
        let (rc, out) = Shell.run("/usr/bin/lp", args)
        busy = false
        toast = rc == 0 ? "已发送到打印队列 ✓" : "打印失败：\(out.trimmingCharacters(in: .whitespaces))"
        Diag.notice(Diag.lifecycle, "工具箱·打印 \(pattern.id) rc=\(rc)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) { self.toast = nil }
    }

    func printEssentials() {
        for id in ["basic-bw", "basic-color", "nozzle-check"] {
            if let p = PrinterPatterns.all.first(where: { $0.id == id }) { print(p) }
        }
    }
}

// MARK: - 视图

struct PrinterTab: View {
    @StateObject private var model = PrinterModel()
    @State private var previewPattern: TestPattern?

    private let cols = [GridItem(.adaptive(minimum: 210, maximum: 260), spacing: 14)]

    var body: some View {
        VStack(spacing: 0) {
            bar
            Divider()
            ScrollView {
                LazyVGrid(columns: cols, spacing: 14) {
                    ForEach(PrinterPatterns.all) { p in card(p) }
                }
                .padding(16)
            }
        }
        .overlay(alignment: .bottom) { if let t = model.toast { toastView(t) } }
        .sheet(item: $previewPattern) { p in previewSheet(p) }
    }

    private var bar: some View {
        HStack(spacing: 10) {
            Text("打印机").font(.system(size: 12, weight: .semibold))
            Picker("", selection: $model.selectedPrinter) {
                Text("系统默认").tag(String?.none)
                ForEach(model.printers, id: \.self) { Text($0).tag(String?.some($0)) }
            }
            .labelsHidden().frame(width: 240)
            Button { model.refresh() } label: { Image(systemName: "arrow.clockwise") }.help("刷新打印机列表")
            Button { model.printEssentials() } label: { Label("打印常用 3 张", systemImage: "printer") }
                .disabled(model.printers.isEmpty)
            Spacer()
            Text(model.statusText).font(.system(size: 11)).foregroundColor(.secondary)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private func card(_ p: TestPattern) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let img = PrinterPatterns.preview(p) {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
            }
            HStack(spacing: 6) {
                Text(p.title).font(.system(size: 13, weight: .semibold))
                Text(p.colorLabel)
                    .font(.system(size: 9, weight: .medium))
                    .padding(.horizontal, 5).padding(.vertical, 1.5)
                    .background(Capsule().fill(p.colorLabel == "彩色" ? Color.pink.opacity(0.15) : Color.secondary.opacity(0.12)))
                    .foregroundColor(p.colorLabel == "彩色" ? .pink : .secondary)
                Spacer()
            }
            Text(p.blurb).font(.system(size: 11)).foregroundColor(.secondary).lineLimit(2)
            HStack {
                Button("打印") { model.print(p) }
                    .disabled(model.busy || (model.selectedPrinter == nil && model.printers.isEmpty))
                Spacer()
                Button("预览") { previewPattern = p }.buttonStyle(.link)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.045)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
        .contentShape(Rectangle())
    }

    private func previewSheet(_ p: TestPattern) -> some View {
        VStack(spacing: 12) {
            Text(p.title).font(.system(size: 16, weight: .bold))
            Text(p.blurb).font(.system(size: 12)).foregroundColor(.secondary)
            if let img = PrinterPatterns.preview(p, width: 420) {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5))
            }
            HStack(spacing: 16) {
                Button("关闭") { previewPattern = nil }.keyboardShortcut(.cancelAction)
                Button("打印此页") { model.print(p); previewPattern = nil }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.printers.isEmpty)
            }
        }
        .padding(20).frame(width: 480)
    }

    private func toastView(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(Capsule().fill(.ultraThinMaterial)).overlay(Capsule().strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
            .padding(.bottom, 14)
    }
}
