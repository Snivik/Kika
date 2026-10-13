//
//  RawDecodeStage.swift
//  Kika
//
//  Stage 1: decode + white balance + exposure + downscale.
//  Output: oriented, uncropped image with extent (0, 0, W, H) at the requested scale,
//  in the linear working space.
//
//  RAW: CIRAWFilter does demosaic, white balance (camera space), exposure and baseline exposure
//  in scene-linear light, then its base tone curve ("boost") and gamut mapping, and outputs
//  display-referred LINEAR extended sRGB. With `extendedDynamicRangeAmount` the output keeps the
//  highlights above diffuse white (1.0 = diffuse white, up to ~2.7 = the brightest raw data at
//  default exposure) instead of clipping them; later stages work on that range and OutputStage
//  rolls it off into 0…1 at the very end. The baseline exposure gets a camera-matched offset
//  (BaselineExposure) so "no edits" looks like the camera JPEG.
//  Decode profiles (Develop/Decode) set the rest of CIRAWFilter's knobs (curve, noise reduction,
//  sharpening, lens correction, decoder version…) and the clip-fade thresholds; whatever they leave
//  unset is reset to the file's own defaults on every render.
//

import Foundation
import CoreGraphics
import CoreImage

nonisolated enum RawDecodeStage {
    /// CIRAWFilter.extendedDynamicRangeAmount (0 = SDR, clipped at 1; 2 = maximum headroom).
    static let extendedDynamicRange: Float = 2
    /// Built-in fractions of the raw clip level (max channel) where partly clipped highlights start /
    /// finish fading to neutral (`DecodeParams.highlightNeutralStart/End`; decode profiles override).
    /// At and beyond the clip level: only values Apple's highlight reconstruction pushed past what the
    /// sensor recorded are neutralised. (Before Oct 2026 this was 0.2…0.75, which bleached bright but
    /// intact colour such as sunset skin; 0.85…1.1 still left grey patches on red-clipped skin.
    /// Compared on P1033881 / P1033890 with Highlights −100: 1.0…1.6 looks like no fade on skin and
    /// keeps the sunset glow, without colour casts.)
    nonisolated(unsafe) static var clipNeutralStart = 1.0
    nonisolated(unsafe) static var clipNeutralEnd = 1.6

    static func apply(source: RenderSource, settings: EditSettings, scale: CGFloat, draft: Bool) -> CIImage {
        let wb = settings.whiteBalance
        let exposure = settings.tone.exposure
        var image: CIImage

        if let raw = source.rawFilter {
            let decode = source.resolvedDecode(settings)
            let builtin = DecodeParams.builtin
            let cameraOffset = (decode.cameraMatchedBrightness ?? true) ? source.baselineOffset : 0
            let extraOffset = decode.baselineOffset ?? 0
            source.lock.lock()
            // The filter is shared and mutable: set EVERY property we touch on every render.
            applyDecoderVersion(settings.decode.decoderVersion, to: raw, source: source)
            let decodeScale = cleanDecodeScale(scale, size: source.orientedSize)
            raw.scaleFactor = Float(decodeScale)
            raw.isDraftModeEnabled = draft
            raw.exposure = Float(exposure)
            raw.baselineExposure = source.defaultBaselineExposure + Float(cameraOffset + extraOffset)
            // Keep the scene highlights above diffuse white (up to ~1.5 stops) instead of letting the
            // filter's SDR output clip them: Highlights / Whites / Exposure− recover detail from them,
            // and OutputStage rolls them off at the end of the pipeline.
            raw.extendedDynamicRangeAmount = Self.extendedDynamicRange
            applyAppleKnobs(decode, to: raw, defaults: source.appleDefaults)
            switch wb.mode {
            case .asShot:
                raw.neutralTemperature = Float(source.asShotTemperature ?? 6500)
                raw.neutralTint = Float(source.asShotTint ?? 0)
            case .custom:
                raw.neutralTemperature = Float(wb.temperature.clamped(to: WhiteBalance.temperatureRange))
                raw.neutralTint = Float(wb.tint.clamped(to: WhiteBalance.tintRange))
            }
            image = raw.outputImage ?? CIImage.empty()
            source.lock.unlock()
            // Partially clipped raw highlights are reconstructed with a color cast (fully clipped
            // ones come out neutral): fade them to neutral towards the clip level, like Lightroom's
            // highlight recovery, so pulling them into view shows clean white/grey, not orange.
            let start = decode.highlightNeutralStart ?? builtin.highlightNeutralStart ?? clipNeutralStart
            let end = decode.highlightNeutralEnd ?? builtin.highlightNeutralEnd ?? clipNeutralEnd
            if source.highlightClip > 0, end > start {
                // highlightClip was measured with the camera offset applied, at exposure 0.
                let clip = source.highlightClip * pow(2, exposure + extraOffset + cameraOffset - source.baselineOffset)
                image = DevelopKernels.apply(DevelopKernels.clipNeutral, image,
                                             [DevelopKernels.vector(start * clip, end * clip)])
            }
            if decodeScale > scale * 1.0001 {
                // Resample the small remainder; a clamped margin gives the filter real edge pixels.
                let e = image.extent
                let r = scale / decodeScale
                image = image.clampedToExtent().cropped(to: e.insetBy(dx: -8, dy: -8))
                    .applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: r, kCIInputAspectRatioKey: 1])
                    .cropped(to: CGRect(x: e.minX * r, y: e.minY * r, width: e.width * r, height: e.height * r))
            }
        } else {
            image = source.image ?? CIImage.empty()
            if scale < 1 {
                image = draft
                    ? image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                    : image.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: scale, kCIInputAspectRatioKey: 1])
            }
            if wb.mode == .custom {
                // Non-RAW: treat temperature/tint relative to D65 (6500 K, 0).
                image = image.applyingFilter("CITemperatureAndTint", parameters: [
                    "inputNeutral": CIVector(x: CGFloat(wb.temperature), y: CGFloat(wb.tint)),
                    "inputTargetNeutral": CIVector(x: 6500, y: 0),
                ])
            }
            if exposure != 0 {
                image = image.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: exposure])
            }
        }

        // Normalize extent to start at (0, 0) and drop fractional/infinite edges.
        let e = image.extent
        guard !e.isInfinite, !e.isEmpty else { return image }
        image = image.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
        // Whole pixels only, and never the partially covered last row/column a resampler adds.
        let expected = CGSize(width: (source.orientedSize.width * scale + 0.01).rounded(.down),
                              height: (source.orientedSize.height * scale + 0.01).rounded(.down))
        let size = CGSize(width: min(e.width.rounded(.down), max(1, expected.width)),
                          height: min(e.height.rounded(.down), max(1, expected.height)))
        return image.cropped(to: CGRect(origin: .zero, size: size))
    }
}

nonisolated extension RawDecodeStage {
    /// Pinned decoder version if this file supports it, else the newest. Set first: a different
    /// decoder may reset the other knobs (they are all set again right after).
    static func applyDecoderVersion(_ pinned: String?, to raw: CIRAWFilter, source: RenderSource) {
        guard let defaults = source.appleDefaults, !defaults.newestDecoder.isEmpty else { return }
        let target = pinned.flatMap { defaults.decoderVersions.contains($0) ? $0 : nil } ?? defaults.newestDecoder
        if raw.decoderVersion.rawValue != target { raw.decoderVersion = CIRAWDecoderVersion(rawValue: target) }
    }

    /// Every Apple knob: the resolved value, else the file's untouched default.
    static func applyAppleKnobs(_ p: DecodeParams, to raw: CIRAWFilter, defaults: AppleRawDefaults?) {
        guard let defaults else { return }
        let d = defaults.values
        func value(_ kp: KeyPath<DecodeParams, Double?>, _ range: ClosedRange<Double>) -> Float? {
            (p[keyPath: kp] ?? d[keyPath: kp]).map { Float($0.clamped(to: range)) }
        }
        let ok = defaults.supported
        if let v = value(\.boost, 0...1) { raw.boostAmount = v }
        if let v = value(\.boostShadow, 0...2) { raw.boostShadowAmount = v }
        if let v = value(\.shadowBias, 0...50) { raw.shadowBias = v }
        if let g = p.gamutMapping ?? d.gamutMapping { raw.isGamutMappingEnabled = g }
        if ok.contains("luminanceNoiseReduction"), let v = value(\.luminanceNoiseReduction, 0...1) { raw.luminanceNoiseReductionAmount = v }
        if ok.contains("colorNoiseReduction"), let v = value(\.colorNoiseReduction, 0...1) { raw.colorNoiseReductionAmount = v }
        if ok.contains("sharpness"), let v = value(\.sharpness, 0...1) { raw.sharpnessAmount = v }
        if ok.contains("detail"), let v = value(\.detail, 0...3) { raw.detailAmount = v }
        if ok.contains("localContrast"), let v = value(\.localContrast, 0...1) { raw.contrastAmount = v }
        if ok.contains("moireReduction"), let v = value(\.moireReduction, 0...1) { raw.moireReductionAmount = v }
        if ok.contains("localToneMap"), let v = value(\.localToneMap, 0...1) { raw.localToneMapAmount = v }
        if ok.contains("lensCorrection"), let b = p.lensCorrection ?? d.lensCorrection { raw.isLensCorrectionEnabled = b }
        if #available(macOS 26.0, *), ok.contains("highlightRecovery"), let b = p.highlightRecovery ?? d.highlightRecovery {
            raw.isHighlightRecoveryEnabled = b
        }
    }

    /// CIRAWFilter rounds its output size UP when the scaled size isn't whole and fills the extra
    /// row/column with edge garbage that bleeds a few pixels in (e.g. a bright line along the top).
    /// Returns a decode scale ≥ `scale` at which BOTH dimensions are whole pixels — the smallest
    /// j / gcd(width, height) (for 8368×5584 that is multiples of 1/16) — so the caller only has to
    /// Lanczos-downscale the small remainder. For awkward sizes (small gcd) it nudges the scale so
    /// the height lands just below a whole pixel instead.
    static func cleanDecodeScale(_ scale: CGFloat, size: CGSize) -> CGFloat {
        guard scale < 1, size.width >= 1, size.height >= 1 else { return scale }
        var a = Int(size.width), b = Int(size.height)
        while b != 0 { (a, b) = (b, a % b) }
        let g = CGFloat(a)
        if g >= 8 { return min(1, (scale * g - 1e-9).rounded(.up) / g) }
        let v = size.height * scale
        return v == v.rounded(.down) ? scale : (v.rounded(.down) - 0.002) / size.height
    }
}

nonisolated extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self { min(max(self, range.lowerBound), range.upperBound) }
}
