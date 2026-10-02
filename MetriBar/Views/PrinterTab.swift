//
//  PrinterTab.swift
//  MetriBar
//
//  打印机测试：直接使用打包内置的 9 张原始测试模板 PDF（与参考项目逐字一致），
//  CUPS 枚举 → 卡片网格 + PDFKit 首页预览 → lp 原样打印。无服务器、不联网。
//

import SwiftUI
import AppKit
import PDFKit
import Combine

// MARK: - 模板定义（文件名 = 内置资源名）

struct TestPattern: Identifiable, Equatable {
    let id: String            // 与 TestPages/<id>.pdf 同名
    let title: String
    let blurb: String
    let colorLabel: String

    var url: URL? { Bundle.main.url(forResource: id, withExtension: "pdf", subdirectory: "TestPages")
                    ?? Bundle.main.url(forResource: id, withExtension: "pdf") }

    static let all: [TestPattern] = [
        TestPattern(id: "basic-bw",           title: "黑白基础页",   blurb: "文字、线条、几何与对比度总检。", colorLabel: "黑白"),
        TestPattern(id: "basic-color",        title: "彩色基础页",   blurb: "CMYK+RGB 色块与饱和总检。",     colorLabel: "彩色"),
        TestPattern(id: "nozzle-check",       title: "喷头堵塞检测", blurb: "四色细线阵：断线=堵头。",       colorLabel: "彩色"),
        TestPattern(id: "color-gradient",     title: "彩色渐变",     blurb: "彩虹横向渐变过渡测试。",       colorLabel: "彩色"),
        TestPattern(id: "grayscale-gradient", title: "灰度渐变",     blurb: "白→黑多级灰阶过渡。",           colorLabel: "黑白"),
        TestPattern(id: "fine-lines",         title: "精细线条",     blurb: "递减线宽分辨率测试。",           colorLabel: "黑白"),
        TestPattern(id: "text-clarity",       title: "文字清晰度",   blurb: "多字号中英混排阶梯。",           colorLabel: "黑白"),
        TestPattern(id: "color-accuracy",     title: "色彩还原",     blurb: "肤色/天空/植被参照色卡。",       colorLabel: "彩色"),
        TestPattern(id: "alignment-grid",     title: "对齐与套准",   blurb: "角标/十字/斜线检查进纸歪斜。",   colorLabel: "黑白"),
    ]

    /// 首页预览图（PDFKit 渲染，矢量原件所见即所得）。
    func previewImage(width: CGFloat = 236) -> NSImage? {
        guard let url, let doc = PDFDocument(url: url), let page = doc.page(at: 0) else { return nil }
        let bounds = page.bounds(for: .mediaBox)
        let scale = (width * 2) / max(bounds.width, 1)
        let pxW = Int(bounds.width * scale), pxH = Int(bounds.height * scale)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pxW, pixelsHigh: pxH,
                                          bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                          colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        guard let g = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = g
        let ctx = g.cgContext
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: CGFloat(pxW), height: CGFloat(pxH)))
        ctx.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: ctx)
        NSGraphicsContext.restoreGraphicsState()
        let img = NSImage(size: NSSize(width: width, height: width * bounds.height / max(bounds.width, 1)))
        img.addRepresentation(rep)
        return img
    }
}

// MARK: - 模型（CUPS）

@MainActor
final class PrinterModel: ObservableObject {
    @Published var printers: [String] = []
    @Published var selectedPrinter: String?
    @Published var statusText: String = ""
    @Published var busy: Bool = false
    @Published var toast: String?

    init() {
        // init 处于 HostingController 事务内：延后一拍、后台跑 lpstat、回主线程更新。
        DispatchQueue.main.async { [weak self] in self?.refresh() }
    }

    func refresh() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            // 中文 locale 输出「用于X的设备：uri」，英文「device for X: uri」——
            // 按 URI scheme 反向切分，语言无关。
            let (_, outV) = Shell.run("/usr/bin/lpstat", ["-v"])
            var names: [String] = []
            for raw in outV.split(separator: "\n") {
                let line = String(raw)
                guard let uriRange = line.range(of: "://") else { continue }
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
                self.statusText = list.isEmpty
                    ? L10n.t("未检测到打印机")
                    : L10n.t("检测到 %ld 台 · 默认 %@", list.count, def ?? L10n.t("系统默认"))
                Diag.notice(Diag.lifecycle, "工具箱·打印机：\(list) 默认=\(def ?? "-")")
            }
        }
    }

    func print(_ pattern: TestPattern) {
        if busy { return }
        guard let url = pattern.url else { toast = L10n.t("模板缺失：%@.pdf", pattern.id); return }
        busy = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var args = ["-t", "MetriBar · \(L10n.t(pattern.title))"]
            if let p = self?.selectedPrinter, !p.isEmpty { args += ["-d", p] }
            args.append(url.path)
            let (rc, out) = Shell.run("/usr/bin/lp", args)
            DispatchQueue.main.async {
                self?.busy = false
                self?.toast = rc == 0 ? L10n.t("已发送到打印队列 ✓")
                                      : L10n.t("打印失败：%@", out.trimmingCharacters(in: .whitespaces))
            }
            Diag.notice(Diag.lifecycle, "工具箱·打印 \(pattern.id) rc=\(rc)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) { self?.toast = nil }
        }
    }

    func printAll() {
        if busy { return }
        let items = TestPattern.all.compactMap { p -> (TestPattern, URL)? in
            guard let url = p.url else { return nil }
            return (p, url)
        }
        guard !items.isEmpty else { toast = L10n.t("模板缺失"); return }
        busy = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var failed: [String] = []
            for (p, url) in items {
                var args = ["-t", "MetriBar · \(p.title)"]
                if let printer = self?.selectedPrinter, !printer.isEmpty { args += ["-d", printer] }
                args.append(url.path)
                let (rc, _) = Shell.run("/usr/bin/lp", args)
                if rc != 0 { failed.append(p.title) }
                Diag.notice(Diag.lifecycle, "工具箱·打印 \(p.id) rc=\(rc)")
            }
            DispatchQueue.main.async {
                self?.busy = false
                self?.toast = failed.isEmpty ? L10n.t("全部 %ld 张已发送到打印队列 ✓", items.count)
                                             : L10n.t("已发送，%ld 张失败：%@", failed.count,
                                                      failed.joined(separator: L10n.t("、")))
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.2) { self?.toast = nil }
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
                    ForEach(TestPattern.all) { p in card(p) }
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
            Button { model.printAll() } label: { Label("全部打印", systemImage: "printer.fill") }
                .disabled(model.selectedPrinter == nil)
            Spacer()
            Text(model.statusText).font(.system(size: 11)).foregroundColor(.secondary)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private func card(_ p: TestPattern) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let img = p.previewImage() {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
            }
            HStack(spacing: 6) {
                Text(L10n.t(p.title)).font(.system(size: 13, weight: .semibold))
                Text(L10n.t(p.colorLabel))
                    .font(.system(size: 9, weight: .medium))
                    .padding(.horizontal, 5).padding(.vertical, 1.5)
                    .background(Capsule().fill(p.colorLabel == "彩色" ? Color.pink.opacity(0.15) : Color.secondary.opacity(0.12)))
                    .foregroundColor(p.colorLabel == "彩色" ? .pink : .secondary)
                Spacer()
            }
            Text(L10n.t(p.blurb)).font(.system(size: 11)).foregroundColor(.secondary).lineLimit(2)
            HStack {
                Button("打印") { model.print(p) }
                    .disabled(model.busy || (model.selectedPrinter == nil && model.printers.isEmpty))
                Spacer()
                Button("预览") { previewPattern = p }.buttonStyle(.link)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.045)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
        .contentShape(Rectangle())
    }

    private func previewSheet(_ p: TestPattern) -> some View {
        VStack(spacing: 12) {
            Text(L10n.t(p.title)).font(.system(size: 16, weight: .bold))
            Text(L10n.t(p.blurb)).font(.system(size: 12)).foregroundColor(.secondary)
            if let img = p.previewImage(width: 430) {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5))
            }
            HStack(spacing: 16) {
                Button("关闭") { previewPattern = nil }.keyboardShortcut(.cancelAction)
                Button("打印此页") { model.print(p); previewPattern = nil }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.selectedPrinter == nil)
            }
        }
        .padding(20).frame(width: 480)
    }

    private func toastView(_ text: String) -> some View {
        Text(text).font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(Capsule().fill(.ultraThinMaterial)).overlay(Capsule().strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
            .padding(.bottom, 14)
    }
}
