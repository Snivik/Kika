// Renders the Кика app icon: a kika (horned headdress) drawn in red marker on a white tile.
// The strokes wobble, overshoot and leave gaps like a quick hand drawing; the random numbers are seeded,
// so every run draws the same icon. 16 and 32 px get a single heavier pass so the shape still reads.
//
// usage: swift Tools/icon/make_icon.swift Kika/Assets.xcassets/AppIcon.appiconset
import AppKit

let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1]
                 : "Kika/Assets.xcassets/AppIcon.appiconset", isDirectory: true)
let S = 1024
let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
func c(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: a)
}
let red = c(0xD52B1E)   // flag red

typealias Pt = CGPoint
func P(_ x: CGFloat, _ y: CGFloat) -> Pt { Pt(x: x, y: y) }
func Mx(_ p: Pt) -> Pt { Pt(x: 1024 - p.x, y: p.y) }
func bez(_ a: Pt, _ b: Pt, _ c: Pt, _ d: Pt, _ n: Int = 40) -> [Pt] {
    (0...n).map { i in let t = CGFloat(i) / CGFloat(n), u = 1 - t
        return Pt(x: u*u*u*a.x + 3*u*u*t*b.x + 3*u*t*t*c.x + t*t*t*d.x, y: u*u*u*a.y + 3*u*u*t*b.y + 3*u*t*t*c.y + t*t*t*d.y) }
}
func quad(_ a: Pt, _ c: Pt, _ b: Pt) -> [Pt] {
    bez(a, P(a.x + 2/3*(c.x-a.x), a.y + 2/3*(c.y-a.y)), P(b.x + 2/3*(c.x-b.x), b.y + 2/3*(c.y-b.y)), b)
}
func join(_ parts: [[Pt]]) -> [Pt] { parts.enumerated().flatMap { i, p in i == 0 ? p : Array(p.dropFirst()) } }

// The kika, y-up: forehead edge at y = L, band top 118 above it, horn tips at 490.
let L: CGFloat = 272
func K(_ x: CGFloat, _ y: CGFloat) -> Pt { P(x, y + L) }
let leftSide = join([bez(K(300,0), K(290,70), K(276,140), K(272,200)), bez(K(272,200), K(264,300), K(250,400), K(262,490))])
let dip = join([bez(K(262,490), K(330,440), K(400,200), K(512,200)), bez(K(512,200), Mx(K(400,200)), Mx(K(330,440)), Mx(K(262,490)))])
let rightSide = Array(leftSide.map(Mx).reversed())
let bottom = quad(K(300,0), K(512,28), Mx(K(300,0)))
let bandTop = quad(K(282,118), K(512,134), Mx(K(282,118)))

/// Draws one icon into a 1024 canvas. `small` = one heavier, closed pass and three dots (for 16 / 32 px).
/// `fullBleed` = no tile or shadow (iOS masks the square itself).
func render(small: Bool, weight: CGFloat, fullBleed: Bool) -> CGImage {
    var seed: UInt64 = 0x6B696B61
    func rnd() -> CGFloat { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return CGFloat(seed >> 33) / CGFloat(1 << 31) }
    func rr(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * rnd() }

    let ctx = CGContext(data: nil, width: S, height: S, bitsPerComponent: 8, bytesPerRow: S * 4, space: srgb,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // macOS icon grid: 824 pt tile centred in 1024 with a soft drop shadow.
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    if fullBleed {
        ctx.setFillColor(c(0xFFFFFF)); ctx.fill(CGRect(x: 0, y: 0, width: S, height: S))
        ctx.translateBy(x: 512, y: 512); ctx.scaleBy(x: 1024 / 824, y: 1024 / 824); ctx.translateBy(x: -512, y: -512)
    } else {
        let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: c(0x000000, 0.35))
        ctx.addPath(tilePath); ctx.setFillColor(c(0xFFFFFF)); ctx.fillPath()
        ctx.restoreGState()
        ctx.addPath(tilePath); ctx.clip()
    }

    // A marker stroke: a sub-range of the path, overshooting at both ends, with a smooth sideways wobble
    // and a pressure curve. Drawn as short translucent segments, so the overlaps darken like ink.
    func draw(_ pts: [Pt], width w: CGFloat, start: CGFloat = 0, end: CGFloat = 1, overshoot: CGFloat = 14,
              wobble: CGFloat = 5, alpha: CGFloat = 0.92) {
        let n = pts.count
        var p = Array(pts[Int(CGFloat(n-1) * start)...Int(CGFloat(n-1) * end)])
        func ext(_ a: Pt, _ b: Pt, _ d: CGFloat) -> Pt { let l = hypot(a.x-b.x, a.y-b.y); return Pt(x: a.x + (a.x-b.x)/l*d, y: a.y + (a.y-b.y)/l*d) }
        p.insert(ext(p[0], p[1], overshoot * rr(0.3, 1.2)), at: 0)
        p.append(ext(p[p.count-1], p[p.count-2], overshoot * rr(0.3, 1.2)))
        var s: [CGFloat] = [0]
        for i in 1..<p.count { s.append(s[i-1] + hypot(p[i].x-p[i-1].x, p[i].y-p[i-1].y)) }
        let total = s.last!
        let ph = (0..<3).map { _ in rr(0, 2 * .pi) }
        var q: [Pt] = []
        for i in 0..<p.count {
            let a = p[max(i-1, 0)], b = p[min(i+1, p.count-1)]
            let l = max(hypot(b.x-a.x, b.y-a.y), 0.001)
            let o = wobble * (0.6*sin(s[i]/90 + ph[0]) + 0.3*sin(s[i]/37 + ph[1]) + 0.1*sin(s[i]/13 + ph[2]))
            q.append(Pt(x: p[i].x - (b.y-a.y)/l*o, y: p[i].y + (b.x-a.x)/l*o))
        }
        ctx.setStrokeColor(red.copy(alpha: alpha)!); ctx.setLineCap(.round)
        for i in 1..<q.count {
            let t = s[i] / total
            let pressure = min(1, min(t, 1 - t) * 6 + 0.25) * (0.85 + 0.15 * sin(s[i] / 23))
            ctx.setLineWidth(w * weight * pressure)
            ctx.move(to: q[i-1]); ctx.addLine(to: q[i]); ctx.strokePath()
        }
    }
    // An embroidery dot: a loose loop that doesn't quite close.
    func loop(_ c: Pt, _ r: CGFloat, width w: CGFloat) {
        let a0 = rr(0, 2 * .pi), sweep = rr(1.75, 2.1) * .pi
        let pts = (0...30).map { i -> Pt in
            let a = a0 + sweep * CGFloat(i)/30, r2 = r * (1 + 0.12*sin(a*2 + a0))
            return Pt(x: c.x + cos(a)*r2, y: c.y + sin(a)*r2)
        }
        draw(pts, width: w, overshoot: 0, wobble: 1.2)
    }

    let W: CGFloat = 20
    ctx.translateBy(x: 512, y: 512); ctx.rotate(by: -0.035); ctx.translateBy(x: -512, y: -512)
    if small {
        draw(leftSide, width: W, alpha: 1); draw(dip, width: W, alpha: 1); draw(rightSide, width: W, alpha: 1)
        draw(bottom, width: W, alpha: 1); draw(bandTop, width: W * 0.9, alpha: 1)
        ctx.setFillColor(red)
        for i in -1...1 { ctx.fillEllipse(in: CGRect(origin: K(512 + CGFloat(i) * 130 - 26, 34), size: CGSize(width: 52, height: 52))) }
    } else {
        // Two passes; each leaves the outline open somewhere else.
        for pass in 0..<2 {
            let w = pass == 0 ? W : W * 0.55, al: CGFloat = pass == 0 ? 0.95 : 0.7
            draw(leftSide, width: w, start: pass == 0 ? 0.04 : 0.15, end: 1, alpha: al)
            draw(dip, width: w, start: 0, end: pass == 0 ? 0.93 : 1, alpha: al)
            draw(rightSide, width: w, start: pass == 0 ? 0.06 : 0, end: pass == 0 ? 0.9 : 0.8, alpha: al)
            draw(bottom, width: w, start: pass == 0 ? 0.0 : 0.1, end: pass == 0 ? 0.82 : 1, alpha: al)
            draw(bandTop, width: w * 0.9, start: pass == 0 ? 0.0 : 0.2, end: pass == 0 ? 0.97 : 0.75, alpha: al)
        }
        for i in -3...3 { loop(K(512 + CGFloat(i) * 58, 62 + rr(-3, 3)), 15, width: W * 0.6) }
    }
    return ctx.makeImage()!
}

func write(_ image: CGImage, px: Int, _ name: String) {
    var img = image
    if px != S {
        let d = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: px * 4, space: srgb,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        d.interpolationQuality = .high
        d.draw(image, in: CGRect(x: 0, y: 0, width: px, height: px))
        img = d.makeImage()!
    }
    let url = outDir.appendingPathComponent(name)
    try! NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])!.write(to: url)
    print("wrote \(url.path)")
}

let full = render(small: false, weight: 1, fullBleed: false)
let w64 = render(small: false, weight: 1.6, fullBleed: false)
let w32 = render(small: true, weight: 2.2, fullBleed: false)
let w16 = render(small: true, weight: 3.4, fullBleed: false)
write(w16, px: 16, "icon_16.png")
write(w32, px: 32, "icon_16@2x.png")
write(w32, px: 32, "icon_32.png")
write(w64, px: 64, "icon_32@2x.png")
for (px, name) in [(128, "icon_128.png"), (256, "icon_128@2x.png"), (256, "icon_256.png"), (512, "icon_256@2x.png"),
                   (512, "icon_512.png"), (1024, "icon_512@2x.png")] { write(full, px: px, name) }
write(render(small: false, weight: 1, fullBleed: true), px: 1024, "icon_1024.png")
