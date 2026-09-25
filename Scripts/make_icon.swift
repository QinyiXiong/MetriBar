import AppKit
import CoreGraphics

// ── 调色板（明亮卡通）───────────────────────────────────────────
let bgTop    = NSColor(srgbRed: 0.46, green: 0.78, blue: 1.00, alpha: 1)   // 天空蓝
let bgBottom = NSColor(srgbRed: 0.18, green: 0.54, blue: 0.96, alpha: 1)
let heartTop = NSColor(srgbRed: 1.00, green: 0.50, blue: 0.62, alpha: 1)   // 珊瑚粉
let heartBot = NSColor(srgbRed: 0.91, green: 0.22, blue: 0.40, alpha: 1)   // 玫红
let ink      = NSColor(srgbRed: 0.16, green: 0.20, blue: 0.34, alpha: 1)   // 卡通描边/眼睛
let blush    = NSColor(srgbRed: 1.00, green: 0.62, blue: 0.72, alpha: 0.55)

func grad(_ a: NSColor, _ b: NSColor) -> NSGradient { NSGradient(starting: a, ending: b)! }

func squircle(_ rect: CGRect, _ r: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil)
}

// 心脏轮廓（参数方程采样，16·sin³t / 13cos t −5cos2t −4cos3t −cos4t）
func heartPath(center cx: CGFloat, cy: CGFloat, w HW: CGFloat, h HH: CGFloat) -> CGPath {
    let N = 240
    var raw: [(CGFloat, CGFloat)] = []
    var minX = CGFloat.infinity, maxX = -CGFloat.infinity, minY = CGFloat.infinity, maxY = -CGFloat.infinity
    for i in 0..<N {
        let t = CGFloat(i) / CGFloat(N) * 2 * .pi
        let x = 16 * pow(sin(t), 3)
        let y = 13*cos(t) - 5*cos(2*t) - 4*cos(3*t) - cos(4*t)
        raw.append((x, y))
        minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
    }
    let p = CGMutablePath()
    for (i, pt) in raw.enumerated() {
        let px = cx + (pt.0 - 0) / ((maxX - minX)/2) * (HW/2)
        let py = (cy - HH/2) + (pt.1 - minY) / (maxY - minY) * HH
        if i == 0 { p.move(to: CGPoint(x: px, y: py)) } else { p.addLine(to: CGPoint(x: px, y: py)) }
    }
    p.closeSubpath()
    return p
}

// 四角闪光星
func star(_ c: CGPoint, _ r: CGFloat) -> CGPath {
    let p = CGMutablePath(); let inn = r * 0.34
    let angs: [CGFloat] = [.pi/2, .pi, 1.5 * .pi, 0]
    for k in 0..<4 {
        let a1 = angs[k]; let a2 = angs[k] - .pi/4; let a3 = angs[k] + .pi/4
        p.addLine(to: CGPoint(x: c.x + cos(a1)*r, y: c.y + sin(a1)*r))
        p.addLine(to: CGPoint(x: c.x + cos(a2)*inn, y: c.y + sin(a2)*inn))
        _ = a3
    }
    p.closeSubpath(); return p
}

func fill(_ ctx: CGContext, _ path: CGPath, rect: CGRect, _ g: NSGradient) {
    ctx.saveGState(); ctx.addPath(path); ctx.clip(); g.draw(in: rect, angle: -90); ctx.restoreGState()
}

func renderPNG(_ px: Int) -> Data {
    let S = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let nsgc = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = nsgc
    let ctx = nsgc.cgContext
    ctx.clear(CGRect(x: 0, y: 0, width: S, height: S))

    // 背景 squircle + 顶部高光 + 内描边
    let m = S * 0.02, corner = S * 0.2237
    let bgRect = CGRect(x: m, y: m, width: S - 2*m, height: S - 2*m)
    let bgPath = squircle(bgRect, corner)
    fill(ctx, bgPath, rect: bgRect, grad(bgTop, bgBottom))
    ctx.saveGState(); ctx.addPath(bgPath); ctx.clip()
    let gloss = NSGradient(colors: [NSColor(white: 1, alpha: 0.22), NSColor(white: 1, alpha: 0)],
                           atLocations: [0.0, 0.5], colorSpace: .sRGB)!
    gloss.draw(in: bgRect, angle: -90)
    // 远景柔光点（卡通气泡）
    ctx.setFillColor(NSColor(white: 1, alpha: 0.10).cgColor)
    ctx.fillEllipse(in: CGRect(x: S*0.68, y: S*0.14, width: S*0.30, height: S*0.30))
    ctx.restoreGState()
    ctx.saveGState(); ctx.addPath(squircle(bgRect.insetBy(dx: S*0.006, dy: S*0.006), corner*0.98))
    ctx.setStrokeColor(NSColor(white: 1, alpha: 0.35).cgColor); ctx.setLineWidth(max(1, S*0.01)); ctx.strokePath(); ctx.restoreGState()

    // 心脏几何
    let cx = S * 0.5, HW = S * 0.64, HH = S * 0.56, cy = S * 0.5
    let heart = heartPath(center: cx, cy: cy, w: HW, h: HH)

    // ① 贴纸白描边 + 投影（让心脏像贴纸浮起）
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -S*0.02), blur: S*0.06, color: NSColor(white: 0, alpha: 0.32).cgColor)
    ctx.addPath(heart); ctx.setStrokeColor(NSColor.white.cgColor); ctx.setLineWidth(S*0.075)
    ctx.setLineJoin(.round); ctx.strokePath()
    ctx.restoreGState()

    // ② 心脏本体红色渐变
    fill(ctx, heart, rect: CGRect(x: cx-HW/2, y: cy-HH/2, width: HW, height: HH), grad(heartTop, heartBot))

    // ③ 卡通深色轮廓线
    ctx.saveGState(); ctx.addPath(heart); ctx.setStrokeColor(ink.cgColor)
    ctx.setLineWidth(S*0.022); ctx.setLineJoin(.round); ctx.strokePath(); ctx.restoreGState()

    // ④ 大高光（左上瓣，贴纸光泽）
    ctx.saveGState()
    ctx.translateBy(x: cx - HW*0.22, y: cy + HH*0.34); ctx.rotate(by: -0.5)
    ctx.setFillColor(NSColor(white: 1, alpha: 0.55).cgColor)
    ctx.fillEllipse(in: CGRect(x: -HW*0.13, y: -HH*0.065, width: HW*0.26, height: HH*0.13))
    ctx.restoreGState()

    // ⑤ kawaii 表情：眼睛 + 高光点 + 微笑 + 腮红
    func ellipse(_ c: CGPoint, _ rx: CGFloat, _ ry: CGFloat, _ color: CGColor) {
        ctx.setFillColor(color); ctx.fillEllipse(in: CGRect(x: c.x-rx, y: c.y-ry, width: 2*rx, height: 2*ry))
    }
    let eyeY = cy + HH*0.14, eyeDX = HW*0.17
    ellipse(CGPoint(x: cx - eyeDX, y: eyeY), S*0.050, S*0.068, ink.cgColor)
    ellipse(CGPoint(x: cx + eyeDX, y: eyeY), S*0.050, S*0.068, ink.cgColor)
    ellipse(CGPoint(x: cx - eyeDX - S*0.014, y: eyeY + S*0.024), S*0.016, S*0.020, NSColor.white.cgColor)
    ellipse(CGPoint(x: cx + eyeDX - S*0.014, y: eyeY + S*0.024), S*0.016, S*0.020, NSColor.white.cgColor)
    // 腮红
    ctx.setFillColor(blush.cgColor)
    ctx.fillEllipse(in: CGRect(x: cx - HW*0.30 - S*0.045, y: cy - HH*0.06 - S*0.028, width: S*0.09, height: S*0.056))
    ctx.fillEllipse(in: CGRect(x: cx + HW*0.30 - S*0.045, y: cy - HH*0.06 - S*0.028, width: S*0.09, height: S*0.056))
    // 微笑（U 形二次曲线）
    ctx.saveGState()
    ctx.setStrokeColor(ink.cgColor); ctx.setLineWidth(S*0.024); ctx.setLineCap(.round)
    ctx.move(to: CGPoint(x: cx - HW*0.14, y: cy - HH*0.02))
    ctx.addQuadCurve(to: CGPoint(x: cx + HW*0.14, y: cy - HH*0.02), control: CGPoint(x: cx, y: cy - HH*0.18))
    ctx.strokePath(); ctx.restoreGState()

    // ⑥ 闪光星星（白）
    ctx.setFillColor(NSColor.white.cgColor)
    ctx.addPath(star(CGPoint(x: S*0.17, y: S*0.80), S*0.055)); ctx.fillPath()
    ctx.addPath(star(CGPoint(x: S*0.85, y: S*0.74), S*0.045)); ctx.fillPath()
    ctx.addPath(star(CGPoint(x: S*0.83, y: S*0.28), S*0.035)); ctx.fillPath()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

// ── 写入 AppIcon.appiconset + Contents.json + 预览 ─────────────
let appiconset = CommandLine.arguments.dropFirst().first
    ?? "/Users/qinyixiong/Programer/CodeManager/MetriBar/MetriBar/MetriBar/Assets.xcassets/AppIcon.appiconset"
let fm = FileManager.default
try? fm.createDirectory(atPath: appiconset, withIntermediateDirectories: true)

let order: [(size: String, scale: String, px: Int, name: String)] = [
    ("16x16","1x",16,"icon_16x16.png"),("16x16","2x",32,"icon_16x16@2x.png"),
    ("32x32","1x",32,"icon_32x32.png"),("32x32","2x",64,"icon_32x32@2x.png"),
    ("128x128","1x",128,"icon_128x128.png"),("128x128","2x",256,"icon_128x128@2x.png"),
    ("256x256","1x",256,"icon_256x256.png"),("256x256","2x",512,"icon_256x256@2x.png"),
    ("512x512","1x",512,"icon_512x512.png"),("512x512","2x",1024,"icon_512x512@2x.png"),
]
let cache = Dictionary(uniqueKeysWithValues: Set(order.map{$0.px}).map { ($0, renderPNG($0)) })
var images: [[String:String]] = []
for e in order {
    fm.createFile(atPath: appiconset + "/" + e.name, contents: cache[e.px])
    images.append(["size": e.size, "scale": e.scale, "filename": e.name])
}
try! JSONSerialization.data(withJSONObject: ["images": images, "info": ["author":"xcode","version":1] as [String:Any], ],
    options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: appiconset + "/Contents.json"))

let snap = "/Users/qinyixiong/Programer/CodeManager/MetriBar/.tmp/snap"
try? fm.createDirectory(atPath: snap, withIntermediateDirectories: true)
let png512 = cache[512]!
try! png512.write(to: URL(fileURLWithPath: snap + "/metribar-icon-preview.png"))
print("卡通图标已生成 \(images.count) 尺寸")
