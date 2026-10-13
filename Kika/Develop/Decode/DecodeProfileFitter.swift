//
//  DecodeProfileFitter.swift
//  Kika
//
//  "Match Camera JPEG": fits a camera's decode profile so Кика's unedited render matches the
//  camera's own JPEG rendering (the preview embedded in each RAW) over a set of photos.
//
//  Fitted: Apple's base curve (boost, boost shadow, black point) and Кика's baseline exposure and
//  highlight shoulder (knee, hue keep). Not fitted: noise reduction / sharpening (a downsized preview
//  can't measure them) and white balance (as shot either way).
//
//  Metric: both images at the same small size (≤ 192 px), converted to Oklab; per pixel
//  ΔL² + 0.5·(Δa² + Δb²); the worst 5 % of pixels are dropped (small misalignments, sharpening halos,
//  in-camera local effects), the rest averaged over all photos. Optimiser: coordinate descent with step
//  halving over normalised parameters (bounded, deterministic). Samples render in parallel.
//
//  Per-photo brightness matching (`cameraMatchedBrightness`) stays on, as in normal rendering:
//  the fit then finds the curve SHAPE + a residual exposure offset.
//
//  Which photos (`Sampling`): every RAW of the camera is placed by capture date, ISO and scene
//  brightness (EV100 from aperture / shutter / ISO); the 2 % extremes of ISO and EV are dropped, then
//  farthest-point sampling picks photos as different from each other as possible. `prepareChecked`
//  skips nearly black / heavily blown previews, and `rejectOutliers` drops photos whose camera JPEG is
//  far from the RAW (monochrome picture styles, in-camera filters) before fitting.
//

import Foundation
import CoreGraphics
import CoreImage
import ImageIO

nonisolated enum DecodeProfileFitter {
    /// One photo prepared for fitting: its source and the camera JPEG in Oklab at the render size.
    final class Sample: @unchecked Sendable {
        let url: URL
        let source: RenderSource
        let size: CGSize
        let target: [SIMD3<Float>]
        init(url: URL, source: RenderSource, size: CGSize, target: [SIMD3<Float>]) {
            self.url = url; self.source = source; self.size = size; self.target = target
        }
    }

    struct Result: Sendable {
        var params: DecodeParams
        /// Mean trimmed Oklab error with Кика's defaults / with the fitted profile.
        var errorBefore: Double
        var errorAfter: Double
        var photoCount: Int
        var evaluations: Int
        var seconds: Double
        /// Photos left out, by reason ("too dark", …), for the summary.
        var skipped: [String: Int] = [:]

        /// RMS Oklab difference × 100 (≈ ΔE; ~2 is just noticeable).
        static func deltaE(_ error: Double) -> Double { sqrt(max(error, 0)) * 100 }

        var summary: String {
            var text = String(format: "Fitted on %d photo%@: difference to the camera JPEGs ΔE %.1f → %.1f, %d evaluations, %.0f s.",
                              photoCount, photoCount == 1 ? "" : "s", Self.deltaE(errorBefore), Self.deltaE(errorAfter), evaluations, seconds)
            if !skipped.isEmpty {
                text += " Skipped " + skipped.sorted { $0.key < $1.key }.map { "\($0.value) \($0.key)" }.joined(separator: ", ") + "."
            }
            return text
        }
    }

    nonisolated enum FitError: LocalizedError {
        case noUsablePhotos
        case cancelled
        var errorDescription: String? {
            switch self {
            case .noUsablePhotos: "None of the photos could be compared with a camera JPEG (no embedded preview, or a different crop)."
            case .cancelled: "Cancelled."
            }
        }
    }

    /// The fitted parameters with their bounds (normalised to 0…1 for the optimiser).
    struct Dimension {
        let keyPath: WritableKeyPath<DecodeParams, Double?>
        let range: ClosedRange<Double>
    }
    static let dimensions: [Dimension] = [
        Dimension(keyPath: \.boost, range: 0...1),
        Dimension(keyPath: \.boostShadow, range: 0...2),
        Dimension(keyPath: \.shadowBias, range: 0...10),
        Dimension(keyPath: \.baselineOffset, range: -1...1),
        Dimension(keyPath: \.shoulderKnee, range: 0.6...0.97),
        Dimension(keyPath: \.shoulderHueKeep, range: 0...1),
    ]

    static let maxSide: CGFloat = 192

    // MARK: Preparing

    /// Why a photo was left out of a fit.
    nonisolated enum SkipReason: String, Error, Sendable {
        case unusable = "without a comparable camera JPEG"
        case tooDark = "nearly black"
        case tooBright = "heavily blown out"
        case unlikeJPEG = "unlike their camera JPEG (monochrome style, filter?)"
    }

    /// nil when the RAW can't be opened or has no comparable embedded JPEG (exposure not checked).
    static func prepare(url: URL) -> Sample? {
        try? prepareChecked(url: url, checkExposure: false).get()
    }

    /// The sample, or why it can't be used: no embedded JPEG of the same framing, or (with
    /// `checkExposure`) a preview that is nearly black (median Oklab L < 0.22 ≈ 1 % luminance) or
    /// heavily blown (over 25 % of pixels at white).
    static func prepareChecked(url: URL, checkExposure: Bool = true) -> Swift.Result<Sample, SkipReason> {
        guard let source = RenderPipeline.makeSource(url: url), source.isRAW,
              let preview = embeddedPreview(url: url) else { return .failure(.unusable) }
        let rendered = render(source, DecodeParams())
        let size = rendered.extent.size
        guard size.width >= 32, size.height >= 32 else { return .failure(.unusable) }
        let pw = CGFloat(preview.width), ph = CGFloat(preview.height)
        // Same framing only (a preview cropped to another aspect would compare different content).
        guard abs(pw / ph - size.width / size.height) < 0.02 else { return .failure(.unusable) }
        let ci = CIImage(cgImage: preview)
        let scaled = ci.transformed(by: CGAffineTransform(scaleX: size.width / pw, y: size.height / ph))
        guard let target = oklab(scaled, size: size) else { return .failure(.unusable) }
        if checkExposure {
            let l = target.map(\.x).sorted()
            if l[l.count / 2] < 0.22 { return .failure(.tooDark) }
            if Double(l.filter { $0 > 0.99 }.count) / Double(l.count) > 0.25 { return .failure(.tooBright) }
        }
        return .success(Sample(url: url, source: source, size: size, target: target))
    }

    /// Drops photos whose camera JPEG doesn't represent the RAW: a JPEG with much less colour than the
    /// render (under 30 % of its mean Oklab chroma: monochrome / sepia picture styles), or a default-render
    /// error over 4× the median (strong in-camera filters, HDR modes). Keeps at least half; with fewer
    /// than 4 photos only the colour check applies.
    static func rejectOutliers(_ samples: [Sample]) -> (kept: [Sample], rejected: [Sample]) {
        var errors = [Double](repeating: 0, count: samples.count)
        var colourless = [Bool](repeating: false, count: samples.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: samples.count) { i in
            let s = samples[i]
            let e = sampleError(s, DecodeParams())
            var mono = false
            if let lab = oklab(render(s.source, DecodeParams()), size: s.size) {
                let renderChroma = lab.reduce(0.0) { $0 + Double(sqrt($1.y * $1.y + $1.z * $1.z)) } / Double(lab.count)
                let jpegChroma = s.target.reduce(0.0) { $0 + Double(sqrt($1.y * $1.y + $1.z * $1.z)) } / Double(s.target.count)
                mono = renderChroma > 0.02 && jpegChroma < 0.3 * renderChroma
            }
            lock.lock(); errors[i] = e; colourless[i] = mono; lock.unlock()
        }
        var rejected = Set(samples.indices.filter { colourless[$0] })
        if samples.count >= 4 {
            let median = errors.sorted()[errors.count / 2]
            rejected.formUnion(samples.indices.filter { errors[$0] > 4 * median })
        }
        let byError = samples.indices.sorted { errors[$0] < errors[$1] }
        while rejected.count > samples.count / 2, let best = byError.first(where: { rejected.contains($0) }) {
            rejected.remove(best)   // never throw away more than half
        }
        return (samples.indices.filter { !rejected.contains($0) }.map { samples[$0] },
                samples.indices.filter { rejected.contains($0) }.map { samples[$0] })
    }

    // MARK: Choosing photos

    nonisolated enum Sampling {
        struct Candidate: Sendable {
            var id: Int64
            var date: Date?
            var iso: Int?
            var shutter: Double?
            var aperture: Double?

            /// Scene brightness at ISO 100 (EV100), nil without exposure data.
            var ev100: Double? {
                guard let t = shutter, t > 0, let n = aperture, n > 0, let iso, iso > 0 else { return nil }
                return log2(n * n / t) - log2(Double(iso) / 100)
            }
        }

        /// Candidate ids in pick order: the first `count` are the most varied set; up to `2 × count`
        /// are returned so skipped photos can be replaced. Deterministic.
        static func order(_ candidates: [Candidate], count: Int) -> [Int64] {
            guard !candidates.isEmpty, count > 0 else { return [] }
            var pool = candidates
            // Drop the extreme 2 % of ISO and scene brightness (odd frames skew a curve fit).
            if pool.count >= 50 {
                func trim(_ value: (Candidate) -> Double?) {
                    let v = pool.compactMap(value).sorted()
                    guard v.count >= 50 else { return }
                    let lo = v[Int(Double(v.count) * 0.02)], hi = v[Int(Double(v.count) * 0.98)]
                    pool = pool.filter { c in value(c).map { (lo...hi).contains($0) } ?? true }
                }
                trim { $0.iso.map { log2(Double($0)) } }
                trim { $0.ev100 }
            }
            // Features in 0…1: date rank, log ISO, EV100 (missing = middle).
            let byDate = pool.indices.sorted { (pool[$0].date ?? .distantPast, pool[$0].id) < (pool[$1].date ?? .distantPast, pool[$1].id) }
            var dateRank = [Double](repeating: 0.5, count: pool.count)
            for (rank, i) in byDate.enumerated() { dateRank[i] = pool.count > 1 ? Double(rank) / Double(pool.count - 1) : 0.5 }
            func normalized(_ value: (Candidate) -> Double?) -> [Double] {
                let v = pool.map(value)
                let known = v.compactMap { $0 }
                guard let lo = known.min(), let hi = known.max(), hi > lo else { return v.map { _ in 0.5 } }
                return v.map { $0.map { ($0 - lo) / (hi - lo) } ?? 0.5 }
            }
            let iso = normalized { $0.iso.map { log2(Double($0)) } }
            let ev = normalized { $0.ev100 }
            let features = pool.indices.map { [dateRank[$0], iso[$0], ev[$0]] }
            func dist(_ a: Int, _ b: Int) -> Double { zip(features[a], features[b]).reduce(0) { $0 + ($1.0 - $1.1) * ($1.0 - $1.1) } }
            // Farthest-point sampling, starting from the most typical photo (nearest the centroid).
            let centroid = (0..<3).map { k in features.reduce(0) { $0 + $1[k] } / Double(features.count) }
            let first = features.indices.min { a, b in
                zip(features[a], centroid).reduce(0) { $0 + ($1.0 - $1.1) * ($1.0 - $1.1) }
                    < zip(features[b], centroid).reduce(0) { $0 + ($1.0 - $1.1) * ($1.0 - $1.1) }
            }!
            var picked = [first]
            var nearest = features.indices.map { dist($0, first) }
            let want = min(pool.count, 2 * count)
            while picked.count < want {
                guard let next = nearest.indices.max(by: { nearest[$0] < nearest[$1] }), nearest[next] >= 0 else { break }
                picked.append(next)
                for i in nearest.indices { nearest[i] = min(nearest[i], dist(i, next)) }
                nearest[next] = -1
            }
            return picked.map { pool[$0].id }
        }
    }

    // MARK: Fitting

    /// Fits on `samples`. `progress` gets 0…1; return true from `isCancelled` to stop (throws `.cancelled`).
    static func fit(samples: [Sample], maxEvaluations: Int = 160,
                    progress: (Double) -> Void = { _ in }, isCancelled: () -> Bool = { false }) throws -> Result {
        guard !samples.isEmpty else { throw FitError.noUsablePhotos }
        let start = Date()
        var evaluations = 0
        func cost(_ x: [Double]) throws -> Double {
            if isCancelled() { throw FitError.cancelled }
            evaluations += 1
            progress(min(0.99, Double(evaluations) / Double(maxEvaluations)))
            return error(samples, params(x))
        }

        // Start: Apple's defaults (averaged over the samples) and Кика's built-in values.
        let builtin = DecodeParams.builtin
        let apple = samples.compactMap { $0.source.appleDefaults?.values }
        func mean(_ kp: KeyPath<DecodeParams, Double?>, _ fallback: Double) -> Double {
            let v = apple.compactMap { $0[keyPath: kp] }
            return v.isEmpty ? fallback : v.reduce(0, +) / Double(v.count)
        }
        let initial: [Double] = [mean(\.boost, 1), mean(\.boostShadow, 1), mean(\.shadowBias, 3),
                                 builtin.baselineOffset ?? 0, builtin.shoulderKnee ?? 0.86, builtin.shoulderHueKeep ?? 0.5]
        var x = zip(initial, dimensions).map { v, d in (v - d.range.lowerBound) / (d.range.upperBound - d.range.lowerBound) }
            .map { $0.clamped(to: 0...1) }
        let before = error(samples, DecodeParams())
        var best = try cost(x)
        var step = 0.25
        while step >= 0.01 && evaluations < maxEvaluations {
            var improved = false
            for i in x.indices {
                for dir in [1.0, -1.0] {
                    var y = x
                    y[i] = (y[i] + dir * step).clamped(to: 0...1)
                    guard y[i] != x[i] else { continue }
                    let c = try cost(y)
                    if c < best - 1e-7 { best = c; x = y; improved = true; break }
                }
                if evaluations >= maxEvaluations { break }
            }
            if !improved { step /= 2 }
        }
        progress(1)
        return Result(params: rounded(params(x)), errorBefore: before, errorAfter: best,
                      photoCount: samples.count, evaluations: evaluations, seconds: Date().timeIntervalSince(start))
    }

    /// Normalised vector → parameters.
    static func params(_ x: [Double]) -> DecodeParams {
        var p = DecodeParams()
        for (v, d) in zip(x, dimensions) {
            p[keyPath: d.keyPath] = d.range.lowerBound + v * (d.range.upperBound - d.range.lowerBound)
        }
        return p
    }

    private static func rounded(_ p: DecodeParams) -> DecodeParams {
        var out = p
        for d in dimensions { out[keyPath: d.keyPath] = p[keyPath: d.keyPath].map { ($0 * 1000).rounded() / 1000 } }
        return out
    }

    /// Mean trimmed error over all samples (rendered in parallel).
    static func error(_ samples: [Sample], _ params: DecodeParams) -> Double {
        var errors = [Double](repeating: 0, count: samples.count)
        errors.withUnsafeMutableBufferPointer { buf in
            let base = buf.baseAddress!
            DispatchQueue.concurrentPerform(iterations: samples.count) { i in
                base[i] = sampleError(samples[i], params)
            }
        }
        return errors.reduce(0, +) / Double(errors.count)
    }

    static func sampleError(_ s: Sample, _ params: DecodeParams) -> Double {
        let img = render(s.source, params)
        guard let lab = oklab(img, size: s.size), lab.count == s.target.count else { return 1 }
        var e = [Float](repeating: 0, count: lab.count)
        for i in lab.indices {
            let d = lab[i] - s.target[i]
            e[i] = d.x * d.x + 0.5 * (d.y * d.y + d.z * d.z)
        }
        e.sort()
        let keep = max(1, Int(Double(e.count) * 0.95))
        return Double(e[0..<keep].reduce(0, +)) / Double(keep)
    }

    /// Unedited render with `params` as the photo's overrides.
    static func render(_ source: RenderSource, _ params: DecodeParams) -> CIImage {
        var s = EditSettings()
        s.decode.overrides = params
        return RenderPipeline.render(source: source, settings: s, targetSize: CGSize(width: maxSide, height: maxSide))
    }

    // MARK: Pixels

    /// Oklab of every pixel of `image` cropped / sampled at exactly `size` (origin = image origin).
    static func oklab(_ image: CIImage, size: CGSize) -> [SIMD3<Float>]? {
        let w = Int(size.width), h = Int(size.height)
        guard w > 0, h > 0 else { return nil }
        let e = image.extent
        let placed = image.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
        var px = [Float](repeating: 0, count: w * h * 4)
        RenderPipeline.context.render(placed, toBitmap: &px, rowBytes: w * 16, bounds: CGRect(x: 0, y: 0, width: w, height: h),
                                      format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!)
        var out = [SIMD3<Float>](repeating: .zero, count: w * h)
        for i in 0..<(w * h) {
            // Display range only: the camera JPEG can't go above 1.
            let r = min(max(px[i * 4], 0), 1), g = min(max(px[i * 4 + 1], 0), 1), b = min(max(px[i * 4 + 2], 0), 1)
            let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
            let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
            let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
            out[i] = SIMD3(0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
                           1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
                           0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s)
        }
        return out
    }

    /// The camera JPEG embedded in the RAW (never a RAW decode), oriented.
    static func embeddedPreview(url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: false,
            kCGImageSourceCreateThumbnailFromImageAlways: false,
            kCGImageSourceThumbnailMaxPixelSize: 640,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary),
              max(image.width, image.height) >= 320 else { return nil }
        return image
    }
}
