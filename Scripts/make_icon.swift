import AppKit
import CoreGraphics

// ── 调色板（明亮卡通 · 小机器人 mascot）────────────────────────────
let bgTop     = NSColor(srgbRed: 0.46, green: 0.78, blue: 1.00, alpha: 1)   // 天空蓝
let bgBottom  = NSColor(srgbRed: 0.18, green: 0.54, blue: 0.96, alpha: 1)
let chromeTop = NSColor(srgbRed: 0.99, green: 1.00, blue: 1.00, alpha: 1)   // 机身（近白）
let chromeBot = NSColor(srgbRed: 0.80, green: 0.87, blue: 0.97, alpha: 1)   // 机身下（淡蓝）
let glassTop  = NSColor(srgbRed: 0.36, green: 0.76, blue: 1.00, alpha: 1)   // 面罩玻璃（天青）
let glassBot  = NSColor(srgbRed: 0.14, green: 0.47, blue: 0.90, alpha: 1)
let accentTop = NSColor(srgbRed: 1.00, green: 0.58, blue: 0.68, alpha: 1)   // 珊瑚粉（呼应 ♥）
let accentBot = NSColor(srgbRed: 0.91, green: 0.24, blue: 0.42, alpha: 1)
let ink       = NSColor(srgbRed: 0.16, green: 0.20, blue: 0.34, alpha: 1)   // 卡通描边/眼睛
let blush     = NSColor(srgbRed: 1.00, green: 0.62, blue: 0.72, alpha: 0.55)

func grad(_ a: NSColor, _ b: NSColor) -> NSGradient { NSGradient(starting: a, ending: b)! }

func squircle(_ rect: CGRect, _ r: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil)
}

// 四角闪光星
func star(_ c: CGPoint, _ r: CGFloat) -> CGPath {
    let p = CGMutablePath(); let inn = r * 0.34
    let angs: [CGFloat] = [.pi/2, .pi, 1.5 * .pi, 0]
    for k in 0..<4 {
        let a1 = angs[k]; let a2 = angs[k] - .pi/4
        p.addLine(to: CGPoint(x: c.x + cos(a1)*r, y: c.y + sin(a1)*r))
        p.addLine(to: CGPoint(x: c.x + cos(a2)*inn, y: c.y + sin(a2)*inn))
    }
    p.closeSubpath(); return p
}

func fill(_ ctx: CGContext, _ path: CGPath, rect: CGRect, _ g: NSGradient) {
    ctx.saveGState(); ctx.addPath(path); ctx.clip(); g.draw(in: rect, angle: -90); ctx.restoreGState()
}
func inkStroke(_ ctx: CGContext, _ path: CGPath, width w: CGFloat) {
    ctx.saveGState(); ctx.addPath(path); ctx.setStrokeColor(ink.cgColor)
    ctx.setLineWidth(w); ctx.setLineJoin(.round); ctx.strokePath(); ctx.restoreGState()
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

    // ── 背景 squircle + 顶部高光 + 远景气泡 + 内描边 ──
    let m = S * 0.02, corner = S * 0.2237
    let bgRect = CGRect(x: m, y: m, width: S - 2*m, height: S - 2*m)
    let bgPath = squircle(bgRect, corner)
    fill(ctx, bgPath, rect: bgRect, grad(bgTop, bgBottom))
    ctx.saveGState(); ctx.addPath(bgPath); ctx.clip()
    let gloss = NSGradient(colors: [NSColor(white: 1, alpha: 0.22), NSColor(white: 1, alpha: 0)],
                           atLocations: [0.0, 0.5], colorSpace: .sRGB)!
    gloss.draw(in: bgRect, angle: -90)
    ctx.setFillColor(NSColor(white: 1, alpha: 0.10).cgColor)
    ctx.fillEllipse(in: CGRect(x: S*0.68, y: S*0.14, width: S*0.30, height: S*0.30))
    ctx.restoreGState()
    ctx.saveGState(); ctx.addPath(squircle(bgRect.insetBy(dx: S*0.006, dy: S*0.006), corner*0.98))
    ctx.setStrokeColor(NSColor(white: 1, alpha: 0.35).cgColor); ctx.setLineWidth(max(1, S*0.01)); ctx.strokePath(); ctx.restoreGState()

    // ── 小机器人几何 ──
    let cx = S * 0.5
    let headW = S * 0.60, headH = S * 0.42, headCy = S * 0.56
    let headR = S * 0.14
    let headRect = CGRect(x: cx - headW/2, y: headCy - headH/2, width: headW, height: headH)
    let headPath = squircle(headRect, headR)

    // 身体（机身后下方露头，梯形圆角近似：用小圆角矩形）
    let bodyW = S * 0.34, bodyH = S * 0.18, bodyCy = headCy - headH/2 - bodyH*0.52
    let bodyRect = CGRect(x: cx - bodyW/2, y: bodyCy - bodyH/2, width: bodyW, height: bodyH)
    let bodyPath = squircle(bodyRect, S*0.08)

    // 天线 + 耳罩
    let antX = cx, antTopY = headCy + headH/2
    let antLen = S * 0.13, ballR = S * 0.045
    let ballC = CGPoint(x: antX, y: antTopY + antLen)
    func ear(_ sign: CGFloat) -> CGRect {
        let ex = cx + sign * (headW/2 + S*0.01), ey = headCy
        return CGRect(x: ex - S*0.058, y: ey - S*0.058, width: S*0.116, height: S*0.116)
    }

    // ① 贴纸白描边 + 投影（身体→耳→天线→头，整体浮起）
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -S*0.018), blur: S*0.05, color: NSColor(white: 0, alpha: 0.30).cgColor)
    ctx.setStrokeColor(NSColor.white.cgColor); ctx.setLineJoin(.round); ctx.setLineCap(.round)
    let halo = S * 0.075
    ctx.setLineWidth(halo)
    ctx.addPath(bodyPath); ctx.strokePath()
    ctx.addPath(squircle(headRect, headR)); ctx.strokePath()
    ctx.setLineWidth(halo * 0.7)
    ctx.addEllipse(in: ear(-1)); ctx.strokePath()
    ctx.addEllipse(in: ear(1));  ctx.strokePath()
    ctx.beginPath(); ctx.move(to: CGPoint(x: antX, y: headCy + headH/2 - S*0.01)); ctx.addLine(to: ballC); ctx.strokePath()
    ctx.setLineWidth(halo)
    ctx.beginPath(); ctx.addEllipse(in: CGRect(x: ballC.x-ballR, y: ballC.y-ballR, width: 2*ballR, height: 2*ballR)); ctx.strokePath()
    ctx.restoreGState()

    // ② 机身 / 头 / 耳 chrome 渐变填充
    fill(ctx, bodyPath, rect: bodyRect, grad(chromeTop, chromeBot))
    fill(ctx, headPath, rect: headRect, grad(chromeTop, chromeBot))
    for s in [-1.0, 1.0] as [CGFloat] {
        let e = ear(s); fill(ctx, CGPath(ellipseIn: e, transform: nil), rect: e, grad(chromeTop, chromeBot))
        inkStroke(ctx, CGPath(ellipseIn: e.insetBy(dx: S*0.03, dy: S*0.03), transform: nil), width: max(1, S*0.012))
    }

    // ③ 机身/头 深色轮廓线
    inkStroke(ctx, bodyPath, width: S*0.02)
    inkStroke(ctx, headPath, width: S*0.022)

    // ④ 头部顶缘大高光（贴纸光泽）
    ctx.saveGState()
    ctx.translateBy(x: cx - headW*0.20, y: headCy + headH*0.30); ctx.rotate(by: -0.5)
    ctx.setFillColor(NSColor(white: 1, alpha: 0.5).cgColor)
    ctx.fillEllipse(in: CGRect(x: -headW*0.13, y: -headH*0.055, width: headW*0.26, height: headH*0.11))
    ctx.restoreGState()

    // ⑤ 面罩玻璃（kawaii 脸所在屏幕）
    let screenW = headW - S*0.14, screenH = headH * 0.5
    let screenRect = CGRect(x: cx - screenW/2, y: headCy - headH*0.10, width: screenW, height: screenH)
    let screenPath = squircle(screenRect, S*0.09)
    fill(ctx, screenPath, rect: screenRect, grad(glassTop, glassBot))
    inkStroke(ctx, screenPath, width: S*0.018)
    // 面罩斜向高光
    ctx.saveGState(); ctx.addPath(screenPath); ctx.clip()
    ctx.setFillColor(NSColor(white: 1, alpha: 0.28).cgColor)
    ctx.move(to: CGPoint(x: screenRect.minX, y: screenRect.maxY))
    ctx.addLine(to: CGPoint(x: screenRect.minX + screenW*0.5, y: screenRect.maxY))
    ctx.addLine(to: CGPoint(x: screenRect.minX + screenW*0.2, y: screenRect.minY))
    ctx.addLine(to: CGPoint(x: screenRect.minX, y: screenRect.minY)); ctx.fillPath()
    ctx.restoreGState()

    // ⑥ 眼睛（大）+ 高光点
    func ellipse(_ c: CGPoint, _ rx: CGFloat, _ ry: CGFloat, _ color: CGColor) {
        ctx.setFillColor(color); ctx.fillEllipse(in: CGRect(x: c.x-rx, y: c.y-ry, width: 2*rx, height: 2*ry))
    }
    let eyeY = screenRect.midY + screenH*0.02, eyeDX = screenW*0.24
    ellipse(CGPoint(x: cx - eyeDX, y: eyeY), S*0.048, S*0.062, NSColor.white.cgColor)
    ellipse(CGPoint(x: cx + eyeDX, y: eyeY), S*0.048, S*0.062, NSColor.white.cgColor)
    ellipse(CGPoint(x: cx - eyeDX + S*0.012, y: eyeY - S*0.014), S*0.018, S*0.022, ink.cgColor)
    ellipse(CGPoint(x: cx + eyeDX + S*0.012, y: eyeY - S*0.014), S*0.018, S*0.022, ink.cgColor)

    // ⑦ 微笑（在面罩下沿，二次曲线）
    ctx.saveGState()
    ctx.setStrokeColor(NSColor.white.cgColor); ctx.setLineWidth(S*0.022); ctx.setLineCap(.round)
    ctx.move(to: CGPoint(x: cx - screenW*0.14, y: screenRect.minY + screenH*0.22))
    ctx.addQuadCurve(to: CGPoint(x: cx + screenW*0.14, y: screenRect.minY + screenH*0.22),
                     control: CGPoint(x: cx, y: screenRect.minY + screenH*0.05))
    ctx.strokePath(); ctx.restoreGState()

    // ⑧ 腮红（贴在头两侧，面罩外）
    ctx.setFillColor(blush.cgColor)
    ctx.fillEllipse(in: CGRect(x: cx - headW*0.34 - S*0.05, y: screenRect.minY - S*0.01, width: S*0.10, height: S*0.056))
    ctx.fillEllipse(in: CGRect(x: cx + headW*0.34 - S*0.05, y: screenRect.minY - S*0.01, width: S*0.10, height: S*0.056))

    // ⑨ 天线球（珊瑚粉）+ 胸口心形灯（呼应 ♥）
    let ballRect = CGRect(x: ballC.x-ballR, y: ballC.y-ballR, width: 2*ballR, height: 2*ballR)
    fill(ctx, CGPath(ellipseIn: ballRect, transform: nil), rect: ballRect, grad(accentTop, accentBot))
    inkStroke(ctx, CGPath(ellipseIn: ballRect, transform: nil), width: max(1, S*0.014))
    ctx.setFillColor(NSColor.white.cgColor)
    ellipse(CGPoint(x: ballC.x - ballR*0.3, y: ballC.y + ballR*0.3), ballR*0.28, ballR*0.28, NSColor.white.cgColor)
    // 天线杆深色描边
    ctx.saveGState(); ctx.setStrokeColor(ink.cgColor); ctx.setLineWidth(max(1, S*0.016)); ctx.setLineCap(.round)
    ctx.move(to: CGPoint(x: antX, y: headCy + headH/2)); ctx.addLine(to: CGPoint(x: ballC.x, y: ballC.y - ballR*0.6)); ctx.strokePath(); ctx.restoreGState()
    // 胸口小灯（珊瑚）
    ellipse(CGPoint(x: cx, y: bodyCy + bodyH*0.1), S*0.022, S*0.022, accentBot.cgColor)

    // ⑩ 闪光星星（白）
    ctx.setFillColor(NSColor.white.cgColor)
    ctx.addPath(star(CGPoint(x: S*0.16, y: S*0.80), S*0.055)); ctx.fillPath()
    ctx.addPath(star(CGPoint(x: S*0.86, y: S*0.72), S*0.045)); ctx.fillPath()
    ctx.addPath(star(CGPoint(x: S*0.83, y: S*0.24), S*0.032)); ctx.fillPath()

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
try! cache[512]!.write(to: URL(fileURLWithPath: snap + "/metribar-icon-preview.png"))
print("机器人图标已生成 \(images.count) 尺寸")
