//
//  CleanupAnalyzer.swift
//  Kika
//
//  Measures one photo for Clean Up (CleanupModels.swift), on device:
//    - Sharpness: RMS of second differences along x, y and both diagonals per tile on a 2048 px grey image
//      (Accelerate), on the subject only (faces inside the frame, else Vision's attention saliency boxes, else the
//      whole frame), averaged over its sharpest tiles so shallow depth of field is fine and a missed focus is
//      not; the WEAKEST direction counts, so shake (one direction smeared) is caught too. Mapped to 0…1.
//      Calibrated on real photos (Tools/cleanup_tune.swift): sharp originals ≥ ~0.4 (p5 0.48), Gaussian blur of
//      1 px at 2048 → median 0.31, 2 px → ≤ 0.14, a 6 px shake → 0.02.
//    - Crop: faces touching the frame (sides / chin worse than forehead), people whose shoulders reach the
//      top edge without a head (body pose), slices of people / animals at the side edges.
//    - Quality: Vision's aesthetics score (picks the best shot of a group).
//    - Feature print: Vision's image feature print (similar shots; CleanupGrouping).
//  The image is the photo AS EDITED (crop included) when it has edits, else its embedded preview / a fast
//  decode, `side` px long. Engine code.
//

import Accelerate
import CoreGraphics
import Foundation
import ImageIO
import Vision

nonisolated enum CleanupAnalyzer {
    /// Bump when the measurements change: cached analyses of older versions are redone.
    static let version = 1
    /// Long side of the analysed image.
    static let side = 2048

    /// Everything measured, plus the raw numbers behind the scores (tuning harness).
    nonisolated struct Result: Sendable {
        var analysis: CleanupAnalysis
        /// Weakest-direction RMS (0…255 scale) of the subject's sharpest tiles, and of the whole frame's.
        var subjectRMS: Double
        var frameRMS: Double
        /// Where the subject was looked for: "faces", "salient", "frame".
        var subjectSource: String
        var faces: Int
    }

    // MARK: Image

    /// The image to analyse for `photo` whose file is readable at `url` (security scope already started), or nil.
    static func image(for photo: Photo, url: URL) -> CGImage? {
        if photo.hasEdits {
            return RenderPipeline.renderCGImage(url: url, settings: photo.editSettings, maxPixelSize: side,
                                                colorSpace: RenderPipeline.sRGB)
        }
        let longSide = max(photo.width, photo.height)
        let wanted = longSide > 0 ? min(side, longSide) : side
        if let embedded = PreviewService.embeddedPreview(url: url, maxPixelSize: side),
           max(embedded.width, embedded.height) * 10 >= wanted * 7 {
            return embedded
        }
        if !RenderPipeline.isRAW(url: url) { return PreviewDiskCache.decode(url: url, maxPixelSize: side) }
        return RenderPipeline.renderCGImage(url: url, settings: EditSettings(), maxPixelSize: side, colorSpace: RenderPipeline.sRGB)
    }

    // MARK: Analysis

    static func analyze(_ image: CGImage) -> Result {
        let faces = VNDetectFaceRectanglesRequest()
        let saliency = VNGenerateAttentionBasedSaliencyImageRequest()
        let pose = VNDetectHumanBodyPoseRequest()
        let humans = VNDetectHumanRectanglesRequest()
        humans.upperBodyOnly = false
        let animals = VNRecognizeAnimalsRequest()
        let feature = VNGenerateImageFeaturePrintRequest()
        let aesthetics = VNCalculateImageAestheticsScoresRequest()
        let handler = VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])
        // One failing request (e.g. no Neural Engine model) shouldn't sink the others.
        for request in [faces, saliency, pose, humans, animals, feature, aesthetics] as [VNRequest] {
            try? handler.perform([request])
        }

        // Vision rects are normalized with the origin at the bottom left; ours are top-left.
        func flipped(_ r: CGRect) -> CGRect { CGRect(x: r.minX, y: 1 - r.maxY, width: r.width, height: r.height) }
        let faceBoxes = (faces.results ?? []).map(\.boundingBox)
        // A face cut by the frame is rarely the subject (a passer-by): judge sharpness elsewhere.
        let bigFaces = faceBoxes.filter { $0.height >= 0.04 && $0.minX > edge && $0.maxX < 1 - edge && $0.minY > edge && $0.maxY < 1 - edge }

        // Subject regions (top-left normalized) for sharpness.
        var regions: [CGRect] = []
        var source = "frame"
        if !bigFaces.isEmpty {
            regions = bigFaces.map { flipped($0.insetBy(dx: -$0.width * 0.15, dy: -$0.height * 0.15)) }
            source = "faces"
        } else if let salient = saliency.results?.first?.salientObjects, !salient.isEmpty {
            regions = salient.map { flipped($0.boundingBox) }
            source = "salient"
        }

        let gray = grayPixels(image)
        let tiles = tileRMS(gray.pixels, width: gray.width, height: gray.height)
        let frameRMS = topMean(tiles, in: nil)
        var subjectRMS = regions.isEmpty ? frameRMS : topMean(tiles, in: regions)
        if subjectRMS.isNaN {   // the subject is flat (e.g. a bright sky blob): judge the frame
            subjectRMS = frameRMS
            source = "frame"
        }

        let crop = cropScore(faces: faceBoxes, pose: pose.results ?? [], humans: (humans.results ?? []).map(\.boundingBox),
                             animals: (animals.results ?? []).map(\.boundingBox))
        let quality = aesthetics.results?.first.map { Double($0.overallScore) } ?? 0
        let print = feature.results?.first.map(floats) ?? []

        let analysis = CleanupAnalysis(sharpness: sharpness(rms: subjectRMS.isNaN ? 0 : subjectRMS), cropScore: crop.score,
                                       cropReason: crop.reason, quality: quality, feature: print)
        return Result(analysis: analysis, subjectRMS: subjectRMS.isNaN ? 0 : subjectRMS, frameRMS: frameRMS.isNaN ? 0 : frameRMS,
                      subjectSource: source, faces: bigFaces.count)
    }

    /// Weakest-direction RMS of the sharpest tiles → 0…1 (half way at `sharpnessMid`).
    static func sharpness(rms: Double) -> Double {
        let r = max(rms, 0)
        return (r * r) / (r * r + sharpnessMid * sharpnessMid)
    }

    /// RMS (0…255) where sharpness is 0.5.
    static let sharpnessMid = 6.0

    // MARK: Sharpness

    nonisolated struct Tile {
        /// Tile centre, normalized, top-left origin.
        var center: CGPoint
        /// RMS per `directions` entry.
        var rms: [Double]
        var std: Double
    }

    /// Grey 0…255 floats, top row first.
    static func grayPixels(_ image: CGImage) -> (pixels: [Float], width: Int, height: Int) {
        let w = image.width, h = image.height
        var bytes = [UInt8](repeating: 0, count: w * h)
        bytes.withUnsafeMutableBytes { buffer in
            guard let ctx = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            ctx.interpolationQuality = .none
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        var floats = [Float](repeating: 0, count: w * h)
        vDSP.convertElements(of: bytes, to: &floats)
        return (floats, w, h)
    }

    /// Second differences along x, y and both diagonals (diagonals halved: their taps are √2 apart, squared).
    static let directions: [[Float]] = [
        [0, 0, 0, 1, -2, 1, 0, 0, 0],
        [0, 1, 0, 0, -2, 0, 0, 1, 0],
        [0, 0, 0.5, 0, -1, 0, 0.5, 0, 0],
        [0.5, 0, 0, 0, -1, 0, 0, 0, 0.5],
    ]

    /// Per tile (`tileSide` px, about 1/32 of the long side): RMS of each directional second difference and the
    /// grey standard deviation. Shake smears one direction only, so scores use the weakest direction.
    static func tileRMS(_ pixels: [Float], width w: Int, height h: Int) -> [Tile] {
        guard w >= 16, h >= 16 else { return [] }
        var src = pixels
        let responses: [[Float]] = directions.map { kernel in
            var out = [Float](repeating: 0, count: w * h)
            src.withUnsafeMutableBufferPointer { s in
                out.withUnsafeMutableBufferPointer { d in
                    var input = vImage_Buffer(data: s.baseAddress, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w * 4)
                    var output = vImage_Buffer(data: d.baseAddress, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w * 4)
                    _ = vImageConvolve_PlanarF(&input, &output, nil, 0, 0, kernel, 3, 3, 0, vImage_Flags(kvImageEdgeExtend))
                }
            }
            vDSP.square(out, result: &out)
            return out
        }
        let t = max(16, max(w, h) / 32)
        var tiles: [Tile] = []
        var y0 = 0
        while y0 + t / 2 < h {
            let y1 = min(y0 + t, h)
            var x0 = 0
            while x0 + t / 2 < w {
                let x1 = min(x0 + t, w)
                // Skip the outer pixel ring of the frame (edge extension makes fake edges there).
                let ya = max(y0, 1), yb = min(y1, h - 1), xa = max(x0, 1), xb = min(x1, w - 1)
                var sums = [Double](repeating: 0, count: directions.count)
                var sum = 0.0, sum2 = 0.0
                for y in ya..<yb {
                    let row = y * w
                    for x in xa..<xb {
                        let v = Double(pixels[row + x])
                        sum += v; sum2 += v * v
                    }
                    for d in responses.indices {
                        responses[d].withUnsafeBufferPointer { r in
                            var acc: Float = 0
                            vDSP_sve(r.baseAddress! + row + xa, 1, &acc, vDSP_Length(xb - xa))
                            sums[d] += Double(acc)
                        }
                    }
                }
                let n = Double(max(1, (yb - ya) * (xb - xa)))
                let mean = sum / n
                tiles.append(Tile(center: CGPoint(x: (Double(x0 + x1) / 2) / Double(w), y: (Double(y0 + y1) / 2) / Double(h)),
                                  rms: sums.map { ($0 / n).squareRoot() }, std: max(0, sum2 / n - mean * mean).squareRoot()))
                x0 += t
            }
            y0 += t
        }
        return tiles
    }

    /// Weakest direction's mean RMS over the sharpest 15 % (at least 2) textured tiles inside `regions` (nil = all);
    /// NaN if no tile qualifies.
    static func topMean(_ tiles: [Tile], in regions: [CGRect]?) -> Double {
        let inside = tiles.filter { tile in
            tile.std >= 4 && (regions?.contains { $0.contains(tile.center) } ?? true)
        }
        guard !inside.isEmpty else { return .nan }
        let n = min(inside.count, max(2, Int((Double(inside.count) * 0.15).rounded(.up))))
        return directions.indices.map { d in
            inside.map { $0.rms[d] }.sorted(by: >).prefix(n).reduce(0, +) / Double(n)
        }.min() ?? .nan
    }

    // MARK: Crop

    /// Distance from the frame edge that counts as touching it (normalized).
    static let edge: CGFloat = 0.012

    /// Rects are Vision's (normalized, bottom-left origin).
    static func cropScore(faces: [CGRect], pose: [VNHumanBodyPoseObservation], humans: [CGRect], animals: [CGRect]) -> (score: Double, reason: String?) {
        var best: (score: Double, reason: String?) = (0, nil)
        func consider(_ score: Double, _ reason: String) { if score > best.score { best = (score, reason) } }

        // Faces cut by the frame. A forehead trimmed at the top is a common tight-portrait choice: scored lower.
        for f in faces where f.height >= 0.04 {
            let outside = max(0, -f.minX) + max(0, f.maxX - 1) + max(0, -f.minY) + max(0, f.maxY - 1)
            let extra = min(0.15, Double(outside / max(f.width, f.height)) * 0.5)
            if f.minX <= edge { consider(0.8 + extra, "Face cut at the left edge") }
            if f.maxX >= 1 - edge { consider(0.8 + extra, "Face cut at the right edge") }
            if f.minY <= edge { consider(0.8 + extra, "Face cut at the bottom edge") }
            if f.maxY >= 1 - edge { consider(0.5 + extra, "Face cut at the top edge") }
        }

        // A body whose shoulders / neck reach the top of the frame and no head.
        let head: [VNHumanBodyPoseObservation.JointName] = [.nose, .leftEye, .rightEye, .leftEar, .rightEar]
        for person in pose {
            guard let points = try? person.recognizedPoints(.all) else { continue }
            let hasHead = head.contains { (points[$0]?.confidence ?? 0) > 0.1 }
            let torso = [points[.neck], points[.leftShoulder], points[.rightShoulder]].compactMap { $0 }.filter { $0.confidence > 0.3 }
            guard !hasHead, torso.count >= 2 else { continue }
            let top = torso.map(\.location.y).max() ?? 0
            let xs = torso.map(\.location.x)
            let span = (xs.max() ?? 0) - (xs.min() ?? 0)
            if top >= 0.82, span >= 0.1 { consider(0.9, "Head cut off at the top") }
        }

        // Slices of people / animals at a side edge.
        for h in humans where h.height >= 0.35 && h.width <= 0.22 && (h.minX <= edge || h.maxX >= 1 - edge) {
            consider(0.45, "Person cut at the \(h.minX <= edge ? "left" : "right") edge")
        }
        for a in animals where a.width * a.height >= 0.04 {
            if a.minX <= edge || a.maxX >= 1 - edge {
                consider(0.5, "Animal cut at the \(a.minX <= edge ? "left" : "right") edge")
            } else if a.maxY >= 1 - edge, a.height >= 0.3 {
                consider(0.45, "Animal cut at the top edge")
            }
        }
        return best
    }

    // MARK: Feature print

    static func floats(_ o: VNFeaturePrintObservation) -> [Float] {
        let data = o.data
        switch o.elementType {
        case .float:
            return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self).prefix(o.elementCount)) }
        case .double:
            return data.withUnsafeBytes { $0.bindMemory(to: Double.self).prefix(o.elementCount).map(Float.init) }
        default:
            return []
        }
    }

    /// Feature prints as stored in the catalog (little-endian Float32).
    static func encode(_ f: [Float]) -> Data { f.withUnsafeBytes { Data($0) } }
    static func decode(_ d: Data) -> [Float] {
        d.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }
}
