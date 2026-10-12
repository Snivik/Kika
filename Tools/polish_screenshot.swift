//
//  polish_screenshot.swift
//  README screenshots: crops a window out of a screenshot, rounds its corners (transparent outside) and adds a
//  soft drop shadow on a transparent margin.
//
//    xcrun swiftc -O Tools/polish_screenshot.swift -o /private/tmp/claude-501/polish
//    /private/tmp/claude-501/polish <in.png> <out.png> <x> <y> <w> <h> <corner radius px> [max width px]
//
//  x / y / w / h = the window in image pixels (its 1-2 px light rim marks the edge). Corner radius at 2x: main
//  window ≈ 52, Settings ≈ 36, sheets ≈ 60.
//
import AppKit
let a = CommandLine.arguments
let img = NSImage(contentsOfFile: a[1])!.cgImage(forProposedRect: nil, context: nil, hints: nil)!
let crop = img.cropping(to: CGRect(x: Int(a[3])!, y: Int(a[4])!, width: Int(a[5])!, height: Int(a[6])!))!
var radius = CGFloat(Double(a[7])!)
let maxWidth = a.count > 8 ? CGFloat(Double(a[8])!) : 100_000
let scale = min(1, maxWidth / CGFloat(crop.width))
let w = (CGFloat(crop.width) * scale).rounded(), h = (CGFloat(crop.height) * scale).rounded()
radius *= scale
let blur = (60 * scale).rounded(), pad = (blur * 1.6).rounded(), dy = (16 * scale).rounded()
let W = Int(w + pad * 2), H = Int(h + pad * 2)
let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.interpolationQuality = .high
let rect = CGRect(x: pad, y: pad + dy / 2, width: w, height: h)   // a little up: the shadow falls below
let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
// Shadow: draw the rounded shape with a shadow, then the image clipped on top.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -dy), blur: blur, color: CGColor(gray: 0, alpha: 0.45))
ctx.addPath(path); ctx.setFillColor(CGColor(gray: 0.12, alpha: 1)); ctx.fillPath()
ctx.restoreGState()
ctx.saveGState()
ctx.addPath(path); ctx.clip()
ctx.draw(crop, in: rect)
ctx.restoreGState()
let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: a[2]))
print("\(a[2]): \(W)x\(H)")
