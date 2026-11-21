//
//  AIMasks.swift
//  Kika
//
//  AI masks (MaskShape.ai): Apple's Vision finds the mask on the photo, on device.
//    - Subject: every foreground instance (VNGenerateForegroundInstanceMaskRequest), soft edges.
//    - Background: the inverse of Subject.
//    - People: VNGeneratePersonSegmentationRequest (accurate).
//    - Object: the foreground instances under the picked points (the instance label map, nearest instance within
//      3 % when a point misses).
//    - Sky: Vision has no sky detector, so a heuristic: smooth, blue-ish, neutral or bright pixels that connect to
//      the top edge (flood fill at ~256 px, subjects excluded), refined at full analysis size by their distance to
//      the found sky's colour. Labelled "beta" in the UI.
//  Vision looks at the photo decoded with DEFAULT settings (oriented, uncropped = mask space, `analysisSide` long),
//  so edits never move a mask. The result is an 8-bit gray raster, cached in memory per (file, size, target,
//  points) and scaled to the render like brush rasters. Renders need `RenderContext.source`; without one (or
//  while Vision finds nothing) the mask is empty. `AIMaskStatus` tells the panel what was found.
//  Expand / Feather (AIMask) shape the found mask at render time (morphology + blur), so they never recompute it.
//  `objects(source:)`: every foreground instance on its own (label map + one raster each), for Pick Object's
//  preview of what can be picked (ObjectPreviewRenderer).
//

import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import Observation
import Vision

nonisolated enum AIMaskEngine {
    /// Long side of the image Vision analyses.
    static let analysisSide: CGFloat = 1536

    /// One analysed mask.
    nonisolated final class Raster: @unchecked Sendable {
        let image: CGImage
        /// Instances found (subject / object / background), or 1 / 0 (people, sky).
        let found: Int
        /// Mean mask value, 0…1.
        let coverage: Double
        init(image: CGImage, found: Int, coverage: Double) { self.image = image; self.found = found; self.coverage = coverage }
        var bytes: Int { image.width * image.height }
    }

    /// Largest Expand (±100) as a fraction of the image width.
    static let maxExpand = 0.02
    /// Largest Feather (100) blur radius as a fraction of the image width.
    static let maxFeather = 0.015

    /// The mask at `context.imageSize` (white = selected), or nil without a source / result.
    static func maskImage(for m: AIMask, context: RenderContext) -> CIImage? {
        guard let source = context.source, let raster = raster(for: m, source: source) else { return nil }
        let w = context.imageSize.width, h = context.imageSize.height
        let rw = CGFloat(raster.image.width), rh = CGFloat(raster.image.height)
        var image = CIImage(cgImage: raster.image, options: [.colorSpace: NSNull()])
            .clampedToExtent()
            .transformed(by: CGAffineTransform(scaleX: w / rw, y: h / rh))
        image = refined(image, expand: m.expand, feather: m.feather, width: w)
        return image.cropped(to: CGRect(x: 0, y: 0, width: w, height: h))
    }

    /// Expand (grow / shrink) and Feather (blur) applied to a clamped mask image `width` pixels wide.
    static func refined(_ image: CIImage, expand: Double, feather: Double, width w: CGFloat) -> CIImage {
        var image = image
        let grow = CGFloat(min(max(expand, -100), 100) / 100 * maxExpand) * w
        if abs(grow) >= 0.5 {
            // Separable rectangle morphology (fast at any radius), rounded off by a small blur.
            let size = 2 * abs(grow) + 1
            image = image.applyingFilter(grow > 0 ? "CIMorphologyRectangleMaximum" : "CIMorphologyRectangleMinimum",
                                         parameters: ["inputWidth": size, "inputHeight": size])
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: abs(grow) / 3])
                .clampedToExtent()
        }
        let blur = CGFloat(min(max(feather, 0), 100) / 100 * maxFeather) * w
        if blur >= 0.3 {
            image = image.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: blur]).clampedToExtent()
        }
        return image
    }

    /// Cache / status key.
    static func key(_ m: AIMask, path: String, size: CGSize) -> String {
        let points = m.points.map { String(format: "%.5f,%.5f", $0.x, $0.y) }.joined(separator: ";")
        return "\(path)|\(Int(size.width))x\(Int(size.height))|\(m.target.rawValue)|\(points)"
    }

    static func key(_ m: AIMask, source: RenderSource) -> String { key(m, path: source.url.path, size: source.orientedSize) }

    /// The analysed mask (cached; computed at most once at a time).
    static func raster(for m: AIMask, source: RenderSource) -> Raster? {
        let k = key(m, source: source)
        if let hit = cache.get(k) { return hit }
        computeLock.lock()
        defer { computeLock.unlock() }
        if let hit = cache.get(k) { return hit }
        AIMaskStatus.post(k, .computing)
        do {
            let r = try compute(m, source: source)
            cache.set(k, r)
            AIMaskStatus.post(k, .done(found: r.found, coverage: r.coverage))
            return r
        } catch {
            AIMaskStatus.post(k, .failed("\(error.localizedDescription)"))
            return nil
        }
    }

    private static let computeLock = NSLock()
    private static let cache = RasterCache(limit: 160_000_000)

    // MARK: - Objects (Pick Object preview)

    /// Every foreground instance found on a photo, each on its own.
    nonisolated final class Objects: @unchecked Sendable {
        /// Instance label per pixel (0 = background), `labelWidth` × `labelHeight`, top row first.
        let labels: [UInt8]
        let labelWidth: Int, labelHeight: Int
        /// One soft mask per instance (analysis size).
        let masks: [CGImage]
        /// `masks[i]`'s label in `labels`.
        let labelOf: [Int]
        init(labels: [UInt8], labelWidth: Int, labelHeight: Int, masks: [CGImage], labelOf: [Int]) {
            self.labels = labels; self.labelWidth = labelWidth; self.labelHeight = labelHeight
            self.masks = masks; self.labelOf = labelOf
        }
        var count: Int { masks.count }

        /// Index into `masks` of the instance under `p` (mask space) or the nearest within 3 %; nil = none.
        func index(at p: NormPoint) -> Int? {
            guard let label = AIMaskEngine.label(at: p, labels: labels, width: labelWidth, height: labelHeight) else { return nil }
            return labelOf.firstIndex(of: label)
        }
    }

    /// Every instance on the photo (cached per photo; computed at most once at a time).
    static func objects(source: RenderSource) -> Objects? {
        let k = "objects|" + key(AIMask(target: .subject), source: source)
        objectsLock.lock()
        defer { objectsLock.unlock() }
        if let hit = objectsCache[k] { return hit }
        guard let photo = analysisImage(source) else { return nil }
        let w = photo.width, h = photo.height
        let handler = VNImageRequestHandler(cgImage: photo, orientation: .up, options: [:])
        let request = VNGenerateForegroundInstanceMaskRequest()
        var result = Objects(labels: [], labelWidth: 0, labelHeight: 0, masks: [], labelOf: [])
        if (try? handler.perform([request])) != nil, let obs = request.results?.first {
            let map = obs.instanceMask
            CVPixelBufferLockBaseAddress(map, .readOnly)
            let lw = CVPixelBufferGetWidth(map), lh = CVPixelBufferGetHeight(map), row = CVPixelBufferGetBytesPerRow(map)
            var labels = [UInt8](repeating: 0, count: lw * lh)
            if let base = CVPixelBufferGetBaseAddress(map)?.assumingMemoryBound(to: UInt8.self) {
                for y in 0..<lh { for x in 0..<lw { labels[y * lw + x] = base[y * row + x] } }
            }
            CVPixelBufferUnlockBaseAddress(map, .readOnly)
            var masks: [CGImage] = [], labelOf: [Int] = []
            for label in obs.allInstances.prefix(maxObjects) {
                guard let buffer = try? obs.generateScaledMaskForImage(forInstances: IndexSet(integer: label), from: handler),
                      let pixels = try? gray(buffer, width: w, height: h),
                      let r = try? raster(pixels, width: w, height: h, found: 1) else { continue }
                masks.append(r.image)
                labelOf.append(label)
            }
            result = Objects(labels: labels, labelWidth: lw, labelHeight: lh, masks: masks, labelOf: labelOf)
        }
        objectsCache = [k: result]   // one photo at a time
        return result
    }

    /// Most instances previewed (Vision rarely finds more).
    static let maxObjects = 16
    private static let objectsLock = NSLock()
    nonisolated(unsafe) private static var objectsCache: [String: Objects] = [:]

    nonisolated struct Failure: LocalizedError {
        var errorDescription: String?
        init(_ text: String) { errorDescription = text }
    }

    // MARK: - Analysis

    private static func compute(_ m: AIMask, source: RenderSource) throws -> Raster {
        guard let photo = analysisImage(source) else { throw Failure("Can't read the photo") }
        let w = photo.width, h = photo.height
        let handler = VNImageRequestHandler(cgImage: photo, orientation: .up, options: [:])
        switch m.target {
        case .subject, .background, .object:
            let request = VNGenerateForegroundInstanceMaskRequest()
            try handler.perform([request])
            var pixels = [UInt8](repeating: 0, count: w * h)
            var found = 0
            if let obs = request.results?.first {
                var instances = obs.allInstances
                if m.target == .object {
                    instances = IndexSet(m.points.compactMap { label(at: $0, in: obs.instanceMask) })
                }
                found = instances.count
                if !instances.isEmpty {
                    let buffer = try obs.generateScaledMaskForImage(forInstances: instances, from: handler)
                    pixels = try gray(buffer, width: w, height: h)
                }
            }
            if m.target == .background {
                for i in pixels.indices { pixels[i] = 255 - pixels[i] }
            }
            return try raster(pixels, width: w, height: h, found: found)
        case .people:
            let request = VNGeneratePersonSegmentationRequest()
            request.qualityLevel = .accurate
            request.outputPixelFormat = kCVPixelFormatType_OneComponent8
            try handler.perform([request])
            guard let buffer = request.results?.first?.pixelBuffer else { return try raster([UInt8](repeating: 0, count: w * h), width: w, height: h, found: 0) }
            let pixels = try gray(buffer, width: w, height: h)
            let r = try raster(pixels, width: w, height: h, found: 1)
            return r.coverage < 0.002 ? try raster([UInt8](repeating: 0, count: w * h), width: w, height: h, found: 0) : r
        case .sky:
            // Subjects are never sky.
            let request = VNGenerateForegroundInstanceMaskRequest()
            try? handler.perform([request])
            var subject: [UInt8]?
            if let obs = request.results?.first, !obs.allInstances.isEmpty,
               let buffer = try? obs.generateScaledMaskForImage(forInstances: obs.allInstances, from: handler) {
                subject = try? gray(buffer, width: w, height: h)
            }
            let pixels = SkyFinder.find(photo, subject: subject)
            let r = try raster(pixels, width: w, height: h, found: 1)
            return r.coverage < 0.003 ? try raster([UInt8](repeating: 0, count: w * h), width: w, height: h, found: 0) : r
        }
    }

    /// The photo with default settings, oriented and uncropped (mask space), `analysisSide` long, sRGB.
    static func analysisImage(_ source: RenderSource) -> CGImage? {
        RenderPipeline.renderCGImage(source: source, settings: EditSettings(), targetSize: CGSize(width: analysisSide, height: analysisSide),
                                     draft: true, applyCrop: false, colorSpace: RenderPipeline.sRGB)
    }

    /// The instance label under `p` (mask space), or the nearest one within 3 % of the map; nil = background.
    private static func label(at p: NormPoint, in map: CVPixelBuffer) -> Int? {
        CVPixelBufferLockBaseAddress(map, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(map, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(map)?.assumingMemoryBound(to: UInt8.self) else { return nil }
        let w = CVPixelBufferGetWidth(map), h = CVPixelBufferGetHeight(map), row = CVPixelBufferGetBytesPerRow(map)
        var labels = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h { for x in 0..<w { labels[y * w + x] = base[y * row + x] } }
        return label(at: p, labels: labels, width: w, height: h)
    }

    /// `label(at:in:)` on a copied label map.
    static func label(at p: NormPoint, labels: [UInt8], width w: Int, height h: Int) -> Int? {
        guard w > 0, h > 0, labels.count == w * h else { return nil }
        let cx = min(max(Int(p.x * Double(w)), 0), w - 1), cy = min(max(Int(p.y * Double(h)), 0), h - 1)
        func at(_ x: Int, _ y: Int) -> Int { Int(labels[y * w + x]) }
        if at(cx, cy) != 0 { return at(cx, cy) }
        let reach = max(2, Int(Double(max(w, h)) * 0.03))
        var best: (d: Int, label: Int)?
        for y in max(0, cy - reach)...min(h - 1, cy + reach) {
            for x in max(0, cx - reach)...min(w - 1, cx + reach) where at(x, y) != 0 {
                let d = (x - cx) * (x - cx) + (y - cy) * (y - cy)
                if d <= reach * reach, d < (best?.d ?? .max) { best = (d, at(x, y)) }
            }
        }
        return best?.label
    }

    /// A one-component mask buffer (8-bit or float) as 8-bit gray at `width` × `height`, top row first.
    private static func gray(_ buffer: CVPixelBuffer, width: Int, height: Int) throws -> [UInt8] {
        let image = CIImage(cvPixelBuffer: buffer, options: [.colorSpace: NSNull()])
        let e = image.extent
        guard e.width > 0, e.height > 0 else { throw Failure("Empty mask") }
        let scaled = image.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY)
            .concatenating(CGAffineTransform(scaleX: CGFloat(width) / e.width, y: CGFloat(height) / e.height)))
        var out = [UInt8](repeating: 0, count: width * height)
        out.withUnsafeMutableBytes { bytes in
            RenderPipeline.context.render(scaled, toBitmap: bytes.baseAddress!, rowBytes: width,
                                          bounds: CGRect(x: 0, y: 0, width: width, height: height), format: .L8, colorSpace: nil)
        }
        return out
    }

    private static func raster(_ pixels: [UInt8], width: Int, height: Int, found: Int) throws -> Raster {
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0), provider: provider,
                                  decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { throw Failure("Can't make the mask") }
        let sum = pixels.reduce(0) { $0 + Int($1) }
        return Raster(image: image, found: found, coverage: pixels.isEmpty ? 0 : Double(sum) / Double(pixels.count * 255))
    }

    /// Byte-limited LRU (thread-safe).
    private nonisolated final class RasterCache: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String: Raster] = [:]
        private var order: [String] = []
        private var bytes = 0
        let limit: Int
        init(limit: Int) { self.limit = limit }

        func get(_ k: String) -> Raster? {
            lock.lock(); defer { lock.unlock() }
            guard let r = items[k] else { return nil }
            order.removeAll { $0 == k }
            order.append(k)
            return r
        }

        func set(_ k: String, _ r: Raster) {
            lock.lock(); defer { lock.unlock() }
            if let old = items[k] { bytes -= old.bytes; order.removeAll { $0 == k } }
            items[k] = r
            order.append(k)
            bytes += r.bytes
            while bytes > limit, order.count > 1 {
                let oldest = order.removeFirst()
                bytes -= items.removeValue(forKey: oldest)?.bytes ?? 0
            }
        }
    }
}

// MARK: - Sky

/// Sky as the smooth, bright, blue-ish or neutral area connected to the top edge, refined by colour.
nonisolated enum SkyFinder {
    /// 8-bit mask the size of `image` (top row first). `subject`: a foreground mask of the same size, excluded.
    static func find(_ image: CGImage, subject: [UInt8]?) -> [UInt8] {
        let w = image.width, h = image.height
        guard w > 1, h > 1, let rgba = rgba(image) else { return [UInt8](repeating: 0, count: max(0, w * h)) }

        // 1. Candidates on a ~256 px grid (block averages).
        let f = max(1, Int((Double(max(w, h)) / 256).rounded(.up)))
        let sw = w / f, sh = h / f
        guard sw > 2, sh > 2 else { return [UInt8](repeating: 0, count: w * h) }
        var sr = [Float](repeating: 0, count: sw * sh), sg = sr, sb = sr, sl = sr, ss = sr
        for y in 0..<sh {
            for x in 0..<sw {
                var r: Float = 0, g: Float = 0, b: Float = 0, sub: Float = 0
                for dy in 0..<f {
                    for dx in 0..<f {
                        let i = (y * f + dy) * w + (x * f + dx)
                        r += Float(rgba[i * 4]); g += Float(rgba[i * 4 + 1]); b += Float(rgba[i * 4 + 2])
                        if let subject { sub += Float(subject[i]) }
                    }
                }
                let n = Float(f * f) * 255
                let j = y * sw + x
                sr[j] = r / n; sg[j] = g / n; sb[j] = b / n; ss[j] = sub / n
                sl[j] = 0.2126 * sr[j] + 0.7152 * sg[j] + 0.0722 * sb[j]
            }
        }
        var candidate = [Bool](repeating: false, count: sw * sh)
        for y in 0..<sh {
            for x in 0..<sw {
                let j = y * sw + x
                let right = x + 1 < sw ? j + 1 : j, down = y + 1 < sh ? j + sw : j
                let gradient = abs(sl[j] - sl[right]) + abs(sl[j] - sl[down])
                let mx = max(sr[j], sg[j], sb[j]), mn = min(sr[j], sg[j], sb[j])
                let sat = mx > 0 ? (mx - mn) / mx : 0
                // Blue sky, grey overcast, or anything bright (clouds, sunsets).
                let blue = sb[j] >= sr[j] + 0.03 && sb[j] >= sg[j] - 0.06
                let neutral = sat < 0.2 && sl[j] > 0.4
                let bright = sl[j] > 0.45
                candidate[j] = sl[j] > 0.2 && gradient < 0.06 && (blue || neutral || bright) && ss[j] < 0.5
            }
        }

        // 2. Flood fill from the top row.
        var region = [Float](repeating: 0, count: sw * sh)
        var queue: [Int] = (0..<sw).filter { candidate[$0] }
        for j in queue { region[j] = 1 }
        var head = 0
        while head < queue.count {
            let j = queue[head]; head += 1
            let x = j % sw, y = j / sw
            for n in [x > 0 ? j - 1 : -1, x + 1 < sw ? j + 1 : -1, y > 0 ? j - sw : -1, y + 1 < sh ? j + sw : -1]
            where n >= 0 && candidate[n] && region[n] == 0 {
                region[n] = 1
                queue.append(n)
            }
        }
        guard queue.count >= max(4, sw * sh / 300) else { return [UInt8](repeating: 0, count: w * h) }

        // 3. The sky's colour (mean and spread).
        var mean: (Float, Float, Float) = (0, 0, 0)
        for j in queue { mean.0 += sr[j]; mean.1 += sg[j]; mean.2 += sb[j] }
        let n = Float(queue.count)
        mean = (mean.0 / n, mean.1 / n, mean.2 / n)
        var spread: (Float, Float, Float) = (0, 0, 0)
        for j in queue {
            spread.0 += (sr[j] - mean.0) * (sr[j] - mean.0)
            spread.1 += (sg[j] - mean.1) * (sg[j] - mean.1)
            spread.2 += (sb[j] - mean.2) * (sb[j] - mean.2)
        }
        spread = (sqrt(spread.0 / n) + 0.06, sqrt(spread.1 / n) + 0.06, sqrt(spread.2 / n) + 0.06)
        let meanLum = 0.2126 * mean.0 + 0.7152 * mean.1 + 0.0722 * mean.2

        // Grow the region by one cell, so the refinement can reach the real edge.
        var grown = region
        for j in queue {
            let x = j % sw, y = j / sw
            for dy in -1...1 { for dx in -1...1 {
                let nx = x + dx, ny = y + dy
                if nx >= 0, nx < sw, ny >= 0, ny < sh { grown[ny * sw + nx] = 1 }
            } }
        }

        // 4. Full size: the grown region (bilinear), times how sky-coloured each pixel is.
        var out = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h {
            let gy = min(max((Float(y) + 0.5) / Float(f) - 0.5, 0), Float(sh - 1))
            let y0 = Int(gy), y1 = min(y0 + 1, sh - 1), ty = gy - Float(y0)
            for x in 0..<w {
                let gx = min(max((Float(x) + 0.5) / Float(f) - 0.5, 0), Float(sw - 1))
                let x0 = Int(gx), x1 = min(x0 + 1, sw - 1), tx = gx - Float(x0)
                let top = grown[y0 * sw + x0] * (1 - tx) + grown[y0 * sw + x1] * tx
                let bottom = grown[y1 * sw + x0] * (1 - tx) + grown[y1 * sw + x1] * tx
                let inRegion = top * (1 - ty) + bottom * ty
                guard inRegion > 0 else { continue }
                let i = y * w + x
                let r = Float(rgba[i * 4]) / 255, g = Float(rgba[i * 4 + 1]) / 255, b = Float(rgba[i * 4 + 2]) / 255
                let d = sqrt(((r - mean.0) / spread.0) * ((r - mean.0) / spread.0)
                             + ((g - mean.1) / spread.1) * ((g - mean.1) / spread.1)
                             + ((b - mean.2) / spread.2) * ((b - mean.2) / spread.2)) / 1.732
                var colour = min(max((2.5 - d) / 1.5, 0), 1)
                let lum = 0.2126 * r + 0.7152 * g + 0.0722 * b
                let mx = max(r, g, b), mn = min(r, g, b)
                if lum >= meanLum, mx > 0, (mx - mn) / mx < 0.25 { colour = 1 }   // bright haze, the sun
                var v = inRegion * colour
                if let subject { v *= 1 - Float(subject[i]) / 255 }
                out[i] = UInt8(min(max(v * 255, 0), 255))
            }
        }

        // 5. Soften by one pixel.
        var soft = out
        for y in 1..<(h - 1) {
            for x in 1..<(w - 1) {
                var sum = 0
                for dy in -1...1 { for dx in -1...1 { sum += Int(out[(y + dy) * w + x + dx]) } }
                soft[y * w + x] = UInt8(sum / 9)
            }
        }
        return soft
    }

    /// RGBA8 (sRGB) pixels of `image`, top row first.
    private static func rgba(_ image: CGImage) -> [UInt8]? {
        let w = image.width, h = image.height
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let ok = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let ctx = CGContext(data: bytes.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return ok ? pixels : nil
    }
}

// MARK: - Status (for the panel)

/// What the engine found per mask key (main actor; posted from render threads).
@Observable
final class AIMaskStatus {
    static let shared = AIMaskStatus()

    nonisolated enum State: Equatable, Sendable {
        case computing
        /// `found` instances (or 1 / 0), mean coverage 0…1.
        case done(found: Int, coverage: Double)
        case failed(String)
    }

    private(set) var states: [String: State] = [:]

    nonisolated static func post(_ key: String, _ state: State) {
        Task { @MainActor in AIMaskStatus.shared.states[key] = state }
    }

    /// Computes the mask now (off-main) unless it is known, so the panel shows what was found before any
    /// slider moves (renders skip masks without adjustments).
    func prepare(_ mask: AIMask, source: RenderSource) {
        let key = AIMaskEngine.key(mask, source: source)
        guard states[key] == nil else { return }
        states[key] = .computing
        Task.detached(priority: .userInitiated) { _ = AIMaskEngine.raster(for: mask, source: source) }
    }
}
