//
//  aimasks_check.swift
//  AI masks (Kika/Develop/Masking/AIMasks.swift): JSON round trip, an unknown mask kind skipped without losing
//  the others, kinds ↔ targets, and the sky finder through the whole engine (analysis render, cache, mask image)
//  on a drawn photo: smooth blue sky over textured green ground. Draws its own photo (runs in CI).
//
//  Build & run:
//    Tools/harness.sh /private/tmp/claude-501/aimasks/aimasks_check Tools/aimasks_check.swift
//    /private/tmp/claude-501/aimasks/aimasks_check [out-dir]
//

import Foundation
import CoreGraphics
import CoreImage
import ImageIO
import UniformTypeIdentifiers

@main
struct AIMasksCheck {
    nonisolated(unsafe) static var failures = 0

    static func check(_ ok: Bool, _ name: String) {
        print("  \(ok ? "PASS" : "FAIL") \(name)")
        if !ok { failures += 1 }
    }

    static func main() async throws {
        let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/private/tmp/claude-501/aimasks")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        print("Model")
        var settings = EditSettings()
        settings.tone.exposure = 0.5
        var object = Mask(name: "Object 1", shape: .ai(AIMask(target: .object, points: [NormPoint(x: 0.25, y: 0.75)])))
        object.adjustments.exposure = 1
        settings.masks = [object, Mask(name: "Linear", shape: .linear(LinearGradientMask()))]
        let json = settings.jsonString() ?? ""
        let back = EditSettings.fromJSON(json)
        check(back?.masks == settings.masks && json.contains("\"kind\":\"ai\""), "AI mask JSON round trip")
        check(back?.masks.first?.shape.kind == .object && MaskKind.found.allSatisfy { $0.aiTarget != nil }
              && MaskKind.shapes.allSatisfy { $0.aiTarget == nil }, "kinds ↔ targets")

        let unknown = json.replacingOccurrences(of: "\"kind\":\"ai\"", with: "\"kind\":\"hologram\"")
        let lossy = EditSettings.fromJSON(unknown)
        check(lossy?.masks.count == 1 && lossy?.masks.first?.linear != nil && lossy?.tone.exposure == 0.5,
              "an unknown mask kind is skipped; the other masks and settings stay")

        print("Sky (engine, drawn photo)")
        let url = out.appendingPathComponent("sky-ground.jpg")
        try drawSkyAndGround(url, width: 1200, height: 800, horizon: 0.45)
        guard let source = RenderPipeline.makeSource(url: url) else { check(false, "source"); exit(1) }
        let start = Date()
        let raster = AIMaskEngine.raster(for: AIMask(target: .sky), source: source)
        print(String(format: "  sky found in %.0f ms", Date().timeIntervalSince(start) * 1000))
        guard let raster else { check(false, "sky raster"); exit(1) }
        check(raster.found == 1 && abs(raster.coverage - 0.45) < 0.06, "covers the sky half: \(raster.coverage)")
        let rows = rowMeans(raster.image)
        let skyRows = rows.prefix(Int(Double(rows.count) * 0.4)), groundRows = rows.suffix(Int(Double(rows.count) * 0.5))
        check(skyRows.allSatisfy { $0 > 0.9 } && groundRows.allSatisfy { $0 < 0.05 },
              "sky rows selected, ground rows not (top \(String(format: "%.2f", skyRows.min() ?? 0)), bottom \(String(format: "%.2f", groundRows.max() ?? 1)))")
        check(AIMaskEngine.raster(for: AIMask(target: .sky), source: source) === raster, "cached")

        let ctx = RenderContext(fullSize: source.orientedSize, imageSize: CGSize(width: 600, height: 400), draft: true, applyCrop: true,
                                source: source)
        let image = AIMaskEngine.maskImage(for: AIMask(target: .sky), context: ctx)
        check(image?.extent == CGRect(x: 0, y: 0, width: 600, height: 400), "mask image at render size")
        let noSource = RenderContext(fullSize: source.orientedSize, imageSize: CGSize(width: 600, height: 400), draft: true, applyCrop: true)
        check(AIMaskEngine.maskImage(for: AIMask(target: .sky), context: noSource) == nil, "no source: no mask")

        print("Subject (engine runs; a drawn photo may have none)")
        let subject = AIMaskEngine.raster(for: AIMask(target: .subject), source: source)
        let background = AIMaskEngine.raster(for: AIMask(target: .background), source: source)
        check(subject != nil && background != nil && abs((subject?.coverage ?? 0) + (background?.coverage ?? 0) - 1) < 0.01,
              "background = inverse of subject (\(subject?.found ?? -1) found)")

        print("Expand / Feather")
        let square = CIImage(color: .white).cropped(to: CGRect(x: 250, y: 250, width: 500, height: 500))
            .composited(over: CIImage(color: .black)).cropped(to: CGRect(x: 0, y: 0, width: 1000, height: 1000))
        func coverage(_ expand: Double, _ feather: Double) -> (mean: Double, edge: Double) {
            let image = AIMaskEngine.refined(square.clampedToExtent(), expand: expand, feather: feather, width: 1000)
                .cropped(to: CGRect(x: 0, y: 0, width: 1000, height: 1000))
            // Raw values (no colour management), as the engine reads masks.
            var px = [UInt8](repeating: 0, count: 1000 * 1000)
            px.withUnsafeMutableBytes { bytes in
                RenderPipeline.context.render(image, toBitmap: bytes.baseAddress!, rowBytes: 1000,
                                              bounds: CGRect(x: 0, y: 0, width: 1000, height: 1000), format: .L8, colorSpace: nil)
            }
            let mean = Double(px.reduce(0) { $0 + Int($1) }) / Double(px.count * 255)
            return (mean, Double(px[255 * 1000 + 500]) / 255)   // just inside an edge of the square
        }
        let plain = coverage(0, 0), grown = coverage(50, 0), shrunk = coverage(-50, 0), soft = coverage(0, 100)
        let px = 0.5 * AIMaskEngine.maxExpand * 1000
        check(abs(plain.mean - 0.25) < 0.01, "untouched mask (\(fmt(plain.mean)))")
        check(abs(grown.mean - pow(0.5 + 2 * px / 1000, 2)) < 0.01 && abs(shrunk.mean - pow(0.5 - 2 * px / 1000, 2)) < 0.01,
              "Expand ±50 grows / shrinks by \(Int(px)) px (\(fmt(grown.mean)), \(fmt(shrunk.mean)))")
        check(abs(soft.mean - plain.mean) < 0.01 && soft.edge < 0.85 && plain.edge > 0.97,
              "Feather softens the edge, same area (edge \(fmt(plain.edge)) → \(fmt(soft.edge)), area \(fmt(soft.mean)))")

        print("Objects (Pick Object preview)")
        let objects = AIMaskEngine.objects(source: source)
        check(objects != nil && objects?.masks.count == objects?.labelOf.count && AIMaskEngine.objects(source: source) === objects,
              "objects found and cached (\(objects?.count ?? -1) on the drawn photo)")
        check(AIMaskEngine.label(at: NormPoint(x: 0.5, y: 0.5), labels: [0, 0, 0, 3], width: 2, height: 2) == 3
              && AIMaskEngine.label(at: NormPoint(x: 0.1, y: 0.1), labels: [UInt8](repeating: 0, count: 10_000), width: 100, height: 100) == nil,
              "label lookup: under the point / nothing near")

        print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
        if failures > 0 { exit(1) }
    }

    /// Smooth blue gradient above `horizon` (fraction of the height), noisy green below.
    static func drawSkyAndGround(_ url: URL, width w: Int, height h: Int, horizon: Double) throws {
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        var seed: UInt32 = 12345
        func noise() -> Int { seed = seed &* 1_103_515_245 &+ 12345; return Int((seed >> 16) % 90) - 45 }
        let line = Int(Double(h) * horizon)
        for y in 0..<h {
            for x in 0..<w {
                let i = (y * w + x) * 4
                if y < line {
                    let t = Double(y) / Double(line)
                    pixels[i] = UInt8(90 + 60 * t); pixels[i + 1] = UInt8(140 + 50 * t); pixels[i + 2] = 230
                } else {
                    pixels[i] = UInt8(max(0, min(255, 40 + noise()))); pixels[i + 1] = UInt8(max(0, min(255, 110 + noise())))
                    pixels[i + 2] = UInt8(max(0, min(255, 30 + noise())))
                }
                pixels[i + 3] = 255
            }
        }
        let ctx = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let image = ctx.makeImage()!
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
    }

    static func fmt(_ v: Double) -> String { String(format: "%.3f", v) }

    /// Mean of each row of an 8-bit gray image, 0…1, top row first.
    static func rowMeans(_ image: CGImage) -> [Double] {
        let w = image.width, h = image.height
        var gray = [UInt8](repeating: 0, count: w * h)
        let ctx = CGContext(data: &gray, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                            bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return (0..<h).map { y in Double((0..<w).reduce(0) { $0 + Int(gray[y * w + $1]) }) / Double(w * 255) }
    }
}
