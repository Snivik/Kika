//
//  DecodeSettings.swift
//  sloproom
//
//  RAW decode calibration: Apple's CIRAWFilter knobs plus Sloproom's own front-end constants
//  (highlight neutralisation, output shoulder, camera-matched brightness).
//
//  Layers (each one only overrides what it sets; `nil` = inherit):
//    built-in (Apple's per-image defaults + Sloproom constants)
//      ← global default profile ← camera default profile (make + model)
//      ← the photo's chosen profile ← the photo's own overrides
//  Profiles live in the catalog (Catalog+DecodeProfiles); `DecodeProfileRegistry` resolves the chain.
//  Photos reference profiles live: improving a profile changes every photo that inherits from it.
//
//  Apple values are stored as absolute numbers but default to "Auto" (nil), because Apple picks
//  several of them per image (noise reduction by ISO, sharpening by camera…).
//

import Foundation
import CoreImage

// MARK: - Parameters

/// One set of decode parameters. Every field is optional: `nil` = inherit from the layer below.
/// JSON keys are stable (add, never rename).
nonisolated struct DecodeParams: Codable, Equatable, Sendable, Hashable {
    // Apple CIRAWFilter (nil at every layer = Apple's default for this file)
    /// `boostAmount` 0…1: Apple's global tone curve (0 = linear response).
    var boost: Double?
    /// `boostShadowAmount` 0…2: shadow lift inside the boost curve (no effect at boost 0).
    var boostShadow: Double?
    /// `shadowBias`: amount subtracted from the shadows (sets the black point).
    var shadowBias: Double?
    /// `luminanceNoiseReductionAmount` 0…1.
    var luminanceNoiseReduction: Double?
    /// `colorNoiseReductionAmount` 0…1.
    var colorNoiseReduction: Double?
    /// `sharpnessAmount` 0…1.
    var sharpness: Double?
    /// `contrastAmount` 0…1: local contrast on edges.
    var localContrast: Double?
    /// `detailAmount` 0…3: fine detail enhancement.
    var detail: Double?
    /// `moireReductionAmount` 0…1.
    var moireReduction: Double?
    /// `localToneMapAmount` 0…1 (mostly iPhone files).
    var localToneMap: Double?
    /// `highlightRecoveryEnabled` (macOS 26+): rebuild partly clipped channels from the others.
    var highlightRecovery: Bool?
    /// `gamutMappingEnabled`: squeeze out-of-gamut colours in instead of clipping them.
    var gamutMapping: Bool?
    /// `lensCorrectionEnabled`: distortion correction from the file's lens data.
    var lensCorrection: Bool?

    // Sloproom (nil at every layer = `DecodeParams.builtin`)
    /// Match the camera JPEG's brightness (BaselineExposure offset).
    var cameraMatchedBrightness: Bool?
    /// Extra baseline exposure in EV on top of everything else (per-camera brightness calibration).
    var baselineOffset: Double?
    /// Where partly clipped highlights start / finish fading to neutral, as fractions of the raw
    /// clip level (max channel). Start ≥ end disables the fade.
    var highlightNeutralStart: Double?
    var highlightNeutralEnd: Double?
    /// OutputStage shoulder knee (perceptual units) and how much of the input hue it re-imposes.
    var shoulderKnee: Double?
    var shoulderHueKeep: Double?

    init() {}

    /// Sloproom's own defaults (Apple fields stay nil = Apple's per-image values). The constants
    /// live with the stages that use them (calibration harnesses may change them).
    static var builtin: DecodeParams {
        var p = DecodeParams()
        p.cameraMatchedBrightness = true
        p.baselineOffset = 0
        p.highlightNeutralStart = RawDecodeStage.clipNeutralStart
        p.highlightNeutralEnd = RawDecodeStage.clipNeutralEnd
        p.shoulderKnee = OutputStage.knee
        p.shoulderHueKeep = OutputStage.hueKeep
        return p
    }

    var isEmpty: Bool { self == DecodeParams() }

    /// `self` with every field that `top` sets replaced by `top`'s value.
    func overlaid(by top: DecodeParams) -> DecodeParams {
        var out = self
        for info in DecodeParamInfo.all {
            switch info.kind {
            case .number(let kp, _, _): if let v = top[keyPath: kp] { out[keyPath: kp] = v }
            case .toggle(let kp): if let v = top[keyPath: kp] { out[keyPath: kp] = v }
            }
        }
        return out
    }

    /// Fields set in `self` (as parameter ids).
    var setIDs: [String] { DecodeParamInfo.all.filter { $0.isSet(in: self) }.map(\.id) }
}

// MARK: - Per-photo section of EditSettings

/// The `decode` section of `EditSettings`.
nonisolated struct DecodeSettings: Codable, Equatable, Sendable, Hashable {
    /// Explicitly chosen profile (nil = only the global / camera defaults).
    var profileID: Int64?
    /// This photo's own overrides (win over every profile).
    var overrides = DecodeParams()
    /// Pinned CIRAWFilter decoder version (nil = newest). Stamped when a RAW is first edited, so an
    /// OS update can't silently change how edited photos look.
    var decoderVersion: String?

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        profileID = (try? c.decodeIfPresent(Int64.self, forKey: .profileID)) ?? nil
        overrides = c.decode(.overrides, default: DecodeParams())
        decoderVersion = (try? c.decodeIfPresent(String.self, forKey: .decoderVersion)) ?? nil
    }

    /// Renders like the defaults (a pinned decoder version alone doesn't count as an edit).
    var isDefault: Bool { profileID == nil && overrides.isEmpty }
}

// MARK: - Camera key

/// Camera identity for camera defaults: EXIF make + model, trimmed (same as the catalog columns).
nonisolated struct CameraKey: Hashable, Sendable, Codable, Comparable {
    let make: String
    let model: String

    init(make: String?, model: String?) {
        let trim = { (s: String?) in (s ?? "").trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters)) }
        self.make = trim(make)
        self.model = trim(model)
    }

    var isEmpty: Bool { make.isEmpty && model.isEmpty }

    /// "Panasonic DC-S5M2" (make omitted when the model already starts with it, e.g. "LEICA SL2").
    var displayName: String {
        if make.isEmpty { return model }
        if model.isEmpty { return make }
        let firstWord = make.split(separator: " ").first.map(String.init) ?? make
        return model.lowercased().hasPrefix(firstWord.lowercased()) ? model : "\(make) \(model)"
    }

    static func < (a: CameraKey, b: CameraKey) -> Bool { (a.make, a.model) < (b.make, b.model) }

    /// From a CIRAWFilter / CGImageSource property dictionary (TIFF Make / Model).
    static func from(properties: [AnyHashable: Any]) -> CameraKey? {
        let tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [AnyHashable: Any] ?? [:]
        let key = CameraKey(make: tiff[kCGImagePropertyTIFFMake as String] as? String,
                            model: tiff[kCGImagePropertyTIFFModel as String] as? String)
        return key.isEmpty ? nil : key
    }
}

// MARK: - Parameter descriptors (UI, merging, harness)

nonisolated struct DecodeParamInfo: Identifiable, @unchecked Sendable {
    nonisolated enum Kind {
        case number(WritableKeyPath<DecodeParams, Double?>, ClosedRange<Double>, step: Double)
        case toggle(WritableKeyPath<DecodeParams, Bool?>)
    }
    nonisolated enum Group: String, CaseIterable, Sendable {
        case tone = "Tone Curve", detail = "Detail", corrections = "Corrections", sloproom = "Highlights & Brightness"
    }

    let id: String
    let title: String
    let help: String
    let group: Group
    /// Owned by CIRAWFilter (default = Apple's per-image value) vs Sloproom (default = `builtin`).
    let isApple: Bool
    let kind: Kind

    func isSet(in p: DecodeParams) -> Bool {
        switch kind {
        case .number(let kp, _, _): p[keyPath: kp] != nil
        case .toggle(let kp): p[keyPath: kp] != nil
        }
    }

    func clear(in p: inout DecodeParams) {
        switch kind {
        case .number(let kp, _, _): p[keyPath: kp] = nil
        case .toggle(let kp): p[keyPath: kp] = nil
        }
    }

    /// Copies this field from `source` into `p` (including nil).
    func copy(from source: DecodeParams, into p: inout DecodeParams) {
        switch kind {
        case .number(let kp, _, _): p[keyPath: kp] = source[keyPath: kp]
        case .toggle(let kp): p[keyPath: kp] = source[keyPath: kp]
        }
    }

    static func info(_ id: String) -> DecodeParamInfo? { all.first { $0.id == id } }

    /// Typical Apple defaults, shown for unset knobs where no photo is at hand (profile editor).
    /// Real values vary per file (see `AppleRawDefaults`).
    static var typicalAppleDefaults: DecodeParams {
        var p = DecodeParams()
        p.boost = 1; p.boostShadow = 0.9; p.shadowBias = 3; p.localToneMap = 0
        p.luminanceNoiseReduction = 0.3; p.colorNoiseReduction = 0.5; p.sharpness = 1; p.detail = 0
        p.localContrast = 0; p.moireReduction = 0.5
        p.highlightRecovery = true; p.gamutMapping = true; p.lensCorrection = true
        return p
    }

    static var all: [DecodeParamInfo] { table }
    private static let table: [DecodeParamInfo] = [
        .init(id: "boost", title: "Base Curve", help: "Apple's global tone curve (boostAmount). 0 = flat, linear response; 1 = Apple's full curve.",
              group: .tone, isApple: true, kind: .number(\.boost, 0...1, step: 0.01)),
        .init(id: "boostShadow", title: "Curve Shadows", help: "Shadow lift inside Apple's curve (boostShadowAmount). Below 1 darkens, above 1 lightens. No effect at Base Curve 0.",
              group: .tone, isApple: true, kind: .number(\.boostShadow, 0...2, step: 0.01)),
        .init(id: "shadowBias", title: "Black Point", help: "Amount subtracted from the shadows (shadowBias). Higher = deeper blacks.",
              group: .tone, isApple: true, kind: .number(\.shadowBias, 0...15, step: 0.1)),
        .init(id: "localToneMap", title: "Local Tone Map", help: "Apple's local (HDR-style) tone mapping (localToneMapAmount). Mostly for iPhone files.",
              group: .tone, isApple: true, kind: .number(\.localToneMap, 0...1, step: 0.01)),
        .init(id: "luminanceNoiseReduction", title: "Luminance NR", help: "Luminance noise reduction during demosaic (luminanceNoiseReductionAmount). Smoother grain vs fine texture.",
              group: .detail, isApple: true, kind: .number(\.luminanceNoiseReduction, 0...1, step: 0.01)),
        .init(id: "colorNoiseReduction", title: "Color NR", help: "Chroma noise reduction (colorNoiseReductionAmount). Removes coloured speckle; too much bleeds colour.",
              group: .detail, isApple: true, kind: .number(\.colorNoiseReduction, 0...1, step: 0.01)),
        .init(id: "sharpness", title: "Sharpness", help: "Edge sharpening (sharpnessAmount).",
              group: .detail, isApple: true, kind: .number(\.sharpness, 0...1, step: 0.01)),
        .init(id: "detail", title: "Detail", help: "Fine detail enhancement (detailAmount, 0…3).",
              group: .detail, isApple: true, kind: .number(\.detail, 0...3, step: 0.01)),
        .init(id: "localContrast", title: "Edge Contrast", help: "Local contrast on edges (contrastAmount).",
              group: .detail, isApple: true, kind: .number(\.localContrast, 0...1, step: 0.01)),
        .init(id: "moireReduction", title: "Moiré Reduction", help: "Removes false colour on fine patterns (moireReductionAmount); can also remove real fine colour.",
              group: .detail, isApple: true, kind: .number(\.moireReduction, 0...1, step: 0.01)),
        .init(id: "highlightRecovery", title: "Highlight Recovery", help: "Rebuild partly clipped channels from the others (macOS 26 and later).",
              group: .corrections, isApple: true, kind: .toggle(\.highlightRecovery)),
        .init(id: "gamutMapping", title: "Gamut Mapping", help: "Squeeze colours the output can't show back in, instead of clipping them.",
              group: .corrections, isApple: true, kind: .toggle(\.gamutMapping)),
        .init(id: "lensCorrection", title: "Lens Correction", help: "Apply the distortion correction stored in the file.",
              group: .corrections, isApple: true, kind: .toggle(\.lensCorrection)),
        .init(id: "cameraMatchedBrightness", title: "Match Camera Brightness", help: "Start from the camera JPEG's brightness (an exposure offset measured per photo against its embedded preview).",
              group: .sloproom, isApple: false, kind: .toggle(\.cameraMatchedBrightness)),
        .init(id: "baselineOffset", title: "Baseline Exposure", help: "Extra exposure in EV applied before everything else (per-camera brightness calibration).",
              group: .sloproom, isApple: false, kind: .number(\.baselineOffset, -2...2, step: 0.01)),
        .init(id: "highlightNeutralStart", title: "Clip Fade Start", help: "Partly clipped highlights start fading to neutral at this fraction of the sensor clip level. At or above Clip Fade End: no fade.",
              group: .sloproom, isApple: false, kind: .number(\.highlightNeutralStart, 0...1.5, step: 0.01)),
        .init(id: "highlightNeutralEnd", title: "Clip Fade End", help: "Fraction of the sensor clip level where highlights are fully neutral.",
              group: .sloproom, isApple: false, kind: .number(\.highlightNeutralEnd, 0...1.5, step: 0.01)),
        .init(id: "shoulderKnee", title: "Shoulder Knee", help: "Where the final highlight roll-off starts (perceptual brightness 0…1). Lower = softer, earlier roll-off.",
              group: .sloproom, isApple: false, kind: .number(\.shoulderKnee, 0.5...0.99, step: 0.01)),
        .init(id: "shoulderHueKeep", title: "Shoulder Hue Keep", help: "How much of the original hue the roll-off keeps (0 = plain per-channel, bright colours shift; 1 = hue kept).",
              group: .sloproom, isApple: false, kind: .number(\.shoulderHueKeep, 0...1, step: 0.01)),
    ]
}

// MARK: - Apple's per-file defaults

/// What a freshly created CIRAWFilter reports for one file: Apple's default for every knob, which
/// knobs it supports, and the decoder versions.
nonisolated struct AppleRawDefaults: Sendable {
    var values = DecodeParams()
    var supported: Set<String> = []
    var decoderVersions: [String] = []
    var newestDecoder: String = ""

    /// Read from a filter nobody has modified yet.
    static func capture(_ raw: CIRAWFilter) -> AppleRawDefaults {
        var d = AppleRawDefaults()
        var v = DecodeParams()
        var s: Set<String> = ["boost", "boostShadow", "shadowBias", "gamutMapping"]
        v.boost = Double(raw.boostAmount)
        v.boostShadow = Double(raw.boostShadowAmount)
        v.shadowBias = Double(raw.shadowBias)
        v.gamutMapping = raw.isGamutMappingEnabled
        func add(_ id: String, _ ok: Bool, _ set: () -> Void) { if ok { s.insert(id); set() } }
        add("luminanceNoiseReduction", raw.isLuminanceNoiseReductionSupported) { v.luminanceNoiseReduction = Double(raw.luminanceNoiseReductionAmount) }
        add("colorNoiseReduction", raw.isColorNoiseReductionSupported) { v.colorNoiseReduction = Double(raw.colorNoiseReductionAmount) }
        add("sharpness", raw.isSharpnessSupported) { v.sharpness = Double(raw.sharpnessAmount) }
        add("detail", raw.isDetailSupported) { v.detail = Double(raw.detailAmount) }
        add("localContrast", raw.isContrastSupported) { v.localContrast = Double(raw.contrastAmount) }
        add("moireReduction", raw.isMoireReductionSupported) { v.moireReduction = Double(raw.moireReductionAmount) }
        add("localToneMap", raw.isLocalToneMapSupported) { v.localToneMap = Double(raw.localToneMapAmount) }
        add("lensCorrection", raw.isLensCorrectionSupported) { v.lensCorrection = raw.isLensCorrectionEnabled }
        if #available(macOS 26.0, *) {
            add("highlightRecovery", raw.isHighlightRecoverySupported) { v.highlightRecovery = raw.isHighlightRecoveryEnabled }
        }
        d.values = v
        d.supported = s
        d.decoderVersions = raw.supportedDecoderVersions.map(\.rawValue)
        d.newestDecoder = raw.decoderVersion.rawValue
        return d
    }
}
