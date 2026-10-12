//
//  decode_check.swift
//  Decode profiles (Develop/Decode): model JSON, catalog CRUD + defaults, layering, invalidation,
//  import / export, and their effect on real renders.
//
//  Build & run:
//    Tools/harness.sh /private/tmp/claude-501/decode-out/decode_check Tools/decode_check.swift
//    /private/tmp/claude-501/decode-out/decode_check [raw-file] [out-dir]
//
//  Reads the RAW READ-ONLY; writes only into out-dir (temp catalog + JPEGs).
//

import Foundation
import CoreGraphics
import CoreImage
import ImageIO
import UniformTypeIdentifiers

@main
struct DecodeCheck {
    nonisolated(unsafe) static var failures = 0

    static func check(_ ok: Bool, _ what: String) {
        print(ok ? "  PASS" : "  FAIL", what)
        if !ok { failures += 1 }
    }

    static func main() async throws {
        let args = CommandLine.arguments
        let rawPath = args.count > 1 ? args[1] : "/Volumes/T9/Lightroom/2026/2026-10-11/P1033881.RW2"
        let outDir = URL(fileURLWithPath: args.count > 2 ? args[2] : "/private/tmp/claude-501/decode-out")
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        modelChecks()
        try catalogChecks(outDir: outDir)
        if FileManager.default.fileExists(atPath: rawPath) {
            try renderChecks(raw: URL(fileURLWithPath: rawPath), outDir: outDir)
        } else {
            print("(no RAW at \(rawPath): render checks skipped)")
        }
        print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILURE(S)")
        exit(failures == 0 ? 0 : 1)
    }

    // MARK: - Model

    static func modelChecks() {
        print("Model")
        let old = #"{"tone":{"exposure":0.5},"version":1}"#
        let s = EditSettings.fromJSON(old)
        check(s?.decode == DecodeSettings() && s?.tone.exposure == 0.5, "old JSON without decode decodes with default decode")
        var e = EditSettings()
        e.decode.profileID = 7
        e.decode.overrides.boost = 0.3
        e.decode.overrides.lensCorrection = false
        e.decode.decoderVersion = "8"
        let back = EditSettings.fromJSON(e.jsonString())
        check(back == e, "decode section round-trips")
        check(e.jsonString()?.contains("\"boost\":0.3") == true && e.jsonString()?.contains("sharpness") == false,
              "unset parameters are omitted from JSON")
        var pinned = EditSettings(); pinned.decode.decoderVersion = "8"
        check(pinned.isDefault && !pinned.isEmpty, "a pinned decoder alone renders like default but is stored")
        var a = DecodeParams(); a.boost = 0.2; a.sharpness = 0.5
        var b = DecodeParams(); b.boost = 0.9; b.gamutMapping = false
        let m = a.overlaid(by: b)
        check(m.boost == 0.9 && m.sharpness == 0.5 && m.gamutMapping == false, "overlay: top wins, unset inherits")
        check(DecodeParamInfo.all.count == 19 && Set(DecodeParamInfo.all.map(\.id)).count == 19, "19 unique parameter descriptors")
        var everything = DecodeParams()
        for info in DecodeParamInfo.all {
            switch info.kind {
            case .number(let kp, let r, _): everything[keyPath: kp] = r.lowerBound
            case .toggle(let kp): everything[keyPath: kp] = true
            }
        }
        check(DecodeParams().overlaid(by: everything) == everything, "overlay covers every field")
        check(e.replacing([.rawDecode], from: EditSettings()).decode == DecodeSettings()
              && EditSettings().replacing([.rawDecode], from: e).decode == e.decode, "Raw Decode is a copy / paste section")
    }

    // MARK: - Catalog

    static func catalogChecks(outDir: URL) throws {
        print("Catalog")
        let dir = outDir.appendingPathComponent("catalog-\(Int(Date().timeIntervalSince1970))")
        let catalog = try Catalog.open(at: dir)
        try catalog.reloadDecodeRegistry()
        let seeded = try catalog.allDecodeProfiles()
        check(seeded.map(\.name) == ["Flat for Editing", "Clean High ISO", "Maximum Detail", "Previous Highlights (before Oct 2026)"],
              "starter profiles seeded: \(seeded.map(\.name))")
        try catalog.ensureDecodeProfiles()
        check(try catalog.allDecodeProfiles().count == 4, "seeding runs once")
        let flat = seeded[0]
        check(flat.params.boost == 0, "Flat for Editing sets boost 0")

        // Photos: two Panasonic RAWs (one edited, one not), a Leica RAW (edited), an edited JPEG.
        func photo(_ path: String, _ make: String, _ model: String) -> Photo {
            var p = Photo(path: path); p.cameraMake = make; p.cameraModel = model; return p
        }
        let ids = try catalog.insertPhotos([
            photo("/x/P1.RW2", "Panasonic", "DC-S5M2"), photo("/x/P2.RW2", "Panasonic", "DC-S5M2"),
            photo("/x/L1.DNG", "Leica Camera AG", "LEICA SL2"), photo("/x/J1.JPG", "Panasonic", "DC-S5M2"),
        ])
        var edited = EditSettings(); edited.tone.exposure = 0.3
        _ = try catalog.saveEditSettings(edited, for: ids[0])
        _ = try catalog.saveEditSettings(edited, for: ids[2])
        _ = try catalog.saveEditSettings(edited, for: ids[3])
        func versions() throws -> [Int] { try catalog.photos(ids: ids).sorted { $0.id < $1.id }.map(\.editVersion) }
        let v0 = try versions()

        let pana = CameraKey(make: "Panasonic", model: "DC-S5M2")
        try catalog.setCameraDecodeDefault(pana, profileID: flat.id)
        let v1 = try versions()
        check(v1[0] == v0[0] + 1 && v1[1] == v0[1] && v1[2] == v0[2] && v1[3] == v0[3],
              "camera default bumps only the edited RAWs of that camera (\(v0) → \(v1))")
        let reg = DecodeProfileRegistry.shared
        let r1 = reg.resolve(DecodeSettings(), camera: pana)
        check(r1.params.boost == 0 && r1.layers.map(\.kind) == [.builtin, .camera], "camera default resolves")
        check(r1.source(of: DecodeParamInfo.info("boost")!)?.kind == .camera, "provenance of boost = camera")
        check(r1.source(of: DecodeParamInfo.info("sharpness")!) == nil, "unset Apple knob = Apple's default (no layer)")
        check(r1.params.highlightNeutralStart == RawDecodeStage.clipNeutralStart, "Sloproom knobs default to built-in")

        let hiISO = seeded[1]
        try catalog.setGlobalDecodeDefault(hiISO.id)
        let v2 = try versions()
        check(v2[0] == v1[0] + 1 && v2[2] == v1[2] + 1 && v2[3] == v1[3], "global default bumps every edited RAW, not the JPEG (\(v1) → \(v2))")
        var mine = DecodeSettings(); mine.profileID = seeded[2].id; mine.overrides.sharpness = 0.1
        let r2 = reg.resolve(mine, camera: pana)
        check(r2.layers.map(\.kind) == [.builtin, .global, .camera, .profile, .photo], "full chain order")
        check(r2.params.sharpness == 0.1 && r2.params.boost == 0 && r2.params.luminanceNoiseReduction == 0 && r2.params.colorNoiseReduction == 0.25,
              "photo > profile > camera > global")
        check(r2.inheritedParams().sharpness == 1, "inherited value under the photo override")

        // A photo that chose a profile: editing that profile bumps it; deleting clears the reference.
        var chose = edited; chose.decode.profileID = seeded[2].id
        _ = try catalog.saveEditSettings(chose, for: ids[2])
        check(try catalog.photosUsingDecodeProfile(seeded[2].id) == [ids[2]], "usage of a chosen profile")
        check(Set(try catalog.photosUsingDecodeProfile(hiISO.id)) == [ids[0], ids[2]], "usage of the global default")
        let v3 = try versions()
        var maxDetail = seeded[2]; maxDetail.params.detail = 1.5
        try catalog.updateDecodeProfile(maxDetail)
        let v4 = try versions()
        check(v4[2] == v3[2] + 1 && v4[0] == v3[0], "editing a chosen profile bumps its photos only (\(v3) → \(v4))")
        let renamed = { var p = maxDetail; p.name = "Max Detail"; return p }()
        try catalog.updateDecodeProfile(renamed)
        check(try versions() == v4, "renaming a profile changes no render")
        try catalog.deleteDecodeProfile(id: seeded[2].id)
        let afterDelete = try catalog.photo(id: ids[2])
        check(afterDelete?.editSettings.decode.profileID == nil && afterDelete?.editSettings.tone.exposure == 0.3,
              "deleting a profile clears photo references, keeps the edit")
        check(try versions()[2] == v4[2] + 1, "and re-renders that photo")

        // Defaults survive / cascade.
        try catalog.deleteDecodeProfile(id: flat.id)
        check(try catalog.decodeDefaults().cameras.isEmpty, "deleting a profile removes its camera default")
        check(try catalog.decodeDefaults().global == hiISO.id, "global default kept")
        try catalog.setGlobalDecodeDefault(nil)
        check(try catalog.decodeDefaults().global == nil && reg.globalDefault == nil, "global default cleared")

        // Import / export.
        let exported = try DecodeProfileFile(profiles: try catalog.allDecodeProfiles()).data()
        let url = outDir.appendingPathComponent("profiles.\(DecodeProfileFile.fileExtension)")
        try exported.write(to: url)
        let file = try DecodeProfileFile.read(try Data(contentsOf: url))
        let before = try catalog.allDecodeProfiles()
        let newIDs = try catalog.importDecodeProfiles(file)
        let after = try catalog.allDecodeProfiles()
        check(newIDs.count == before.count && after.count == before.count * 2, "import adds every profile")
        check(after.filter { newIDs.contains($0.id) }.map(\.params) == before.map(\.params), "imported params identical")
        check(after.filter { newIDs.contains($0.id) }.map(\.name) == before.map { "\($0.name) 2" }, "imported names made unique")
        check((try? DecodeProfileFile.read(Data("{\"a\":1}".utf8))) == nil, "foreign JSON refused")
        let dup = try catalog.duplicateDecodeProfile(id: hiISO.id)
        check(try catalog.allDecodeProfiles().first { $0.id == dup }?.name == "Clean High ISO Copy", "duplicate")
        check(try catalog.decodeCameras().map(\.camera.displayName).contains("DC-S5M2") == false
              && (try catalog.decodeCameras().first?.camera.displayName) == "Panasonic DC-S5M2", "camera list with display names")
        check(CameraKey(make: "Leica Camera AG", model: "LEICA SL2").displayName == "LEICA SL2", "display name drops a repeated make")

        // Lightroom-imported photos have no make: their own camera row until the makes are filled in.
        let lrIDs = try catalog.insertPhotos([photo("/x/P9.RW2", "", "DC-S5M2"), photo("/x/P10.RW2", "", "dc-s5m2 "),
                                              photo("/x/C1.CR2", "", "Canon EOS 5DS R")])
        _ = try catalog.saveEditSettings(edited, for: lrIDs[0])
        let bare = CameraKey(make: nil, model: "DC-S5M2")
        check(bare != pana && CameraKey(make: "PANASONIC", model: "dc-s5m2") == pana, "identity = make + model, case-insensitive")
        var cams = try catalog.decodeCameras()
        check(cams.first { $0.camera == pana }?.count == 3 && cams.first { $0.camera == bare }?.count == 2,
              "make-less photos are a separate camera row: \(cams.map { "\($0.camera.displayName) \($0.count)" })")
        let gaps = try catalog.cameraMakeGaps()
        check(gaps.map(\.model) == ["DC-S5M2", "Canon EOS 5DS R"] && gaps[0].photoCount == 2
              && gaps[0].knownMakes.map(\.make) == ["Panasonic"] && gaps[1].knownMakes.isEmpty,
              "gaps: make-less models with the makes other photos have")
        check(try catalog.cameraMakeSample(model: "canon eos 5ds r")?.id == lrIDs[2], "sample photo to read a make from")

        // A default set on the make-less row applies to what rendering sees (the file's make + model)…
        let lrBefore = try catalog.photo(id: lrIDs[0])!.editVersion
        try catalog.setCameraDecodeDefault(bare, profileID: hiISO.id)
        check(try catalog.photo(id: lrIDs[0])!.editVersion == lrBefore + 1, "default on the make-less row re-renders its edited photos")
        check(reg.cameraDefault(for: pana)?.id == hiISO.id, "… and applies to the file's make + model while Panasonic has none of its own")
        try catalog.setCameraDecodeDefault(pana, profileID: dup)
        check(reg.cameraDefault(for: pana)?.id == dup && reg.cameraDefault(for: bare)?.id == hiISO.id, "an exact default wins")

        // Filling in the make merges the rows and carries the make-less default over (unless one exists).
        try catalog.setCameraDecodeDefault(pana, profileID: nil)
        let filled = try catalog.fillCameraMake(model: "DC-S5M2", make: "Panasonic")
        cams = try catalog.decodeCameras()
        check(filled == 2 && cams.first { $0.camera == pana }?.count == 5 && !cams.contains { $0.camera == bare }, "fill merges the camera rows")
        check(try catalog.decodeDefaults().cameras == [pana: hiISO.id], "the make-less default moved to the completed camera")
        check(try catalog.cameraMakeGaps().map(\.model) == ["Canon EOS 5DS R"], "only the Canon gap is left")
        check(try catalog.decodeFitPhotos(camera: pana, count: 10).count == 4, "fit photos: the camera's RAWs (JPEG excluded)")

        // Match profiles record their origin (informational; copies are the user's).
        let match = try catalog.createDecodeProfile(name: "Panasonic DC-S5M2 Camera Match (16 photos)", params: DecodeParams(),
                                                    camera: pana, origin: DecodeProfile.Origin.cameraMatch)
        let copy = try catalog.duplicateDecodeProfile(id: match)
        var m = try catalog.allDecodeProfiles().first { $0.id == match }!; m.params.boost = 0.7
        try catalog.updateDecodeProfile(m)
        let all = try catalog.allDecodeProfiles()
        check(all.first { $0.id == match }?.origin == DecodeProfile.Origin.cameraMatch && all.first { $0.id == copy }?.origin == nil,
              "origin stored, kept on update, not copied")
        check(try catalog.uniqueDecodeProfileName("Panasonic DC-S5M2 Camera Match (16 photos)") == "Panasonic DC-S5M2 Camera Match (16 photos) 2",
              "a second run with the same size gets its own name")
        samplingChecks()
        try catalog.setCameraDecodeDefault(pana, profileID: nil)

        // Recent renders key follows the registry.
        let h1 = RecentRenderKey.settingsHash(edited)
        try catalog.setGlobalDecodeDefault(hiISO.id)
        check(RecentRenderKey.settingsHash(edited) != h1, "recent-render hash changes with the profiles")
        try catalog.setGlobalDecodeDefault(nil)
    }

    // MARK: - Sampling

    static func samplingChecks() {
        print("Match Camera JPEG sampling")
        typealias C = DecodeProfileFitter.Sampling.Candidate
        // 1,000 photos over two years, ISO 100…12800 (a few extreme 51200), apertures / shutters varied.
        var rng = SystemRandomNumberGenerator()
        _ = rng
        var cands: [C] = []
        for i in 0..<1000 {
            let iso = i % 97 == 0 ? 51200 : [100, 200, 400, 800, 1600, 3200, 6400, 12800][(i * 7) % 8]
            let shutter = [1.0 / 4000, 1.0 / 1000, 1.0 / 250, 1.0 / 60, 1.0 / 15][(i * 3) % 5]
            cands.append(C(id: Int64(i + 1), date: Date(timeIntervalSince1970: 1_700_000_000 + Double(i) * 60_000),
                           iso: iso, shutter: shutter, aperture: [1.4, 2.8, 5.6, 11][(i * 5) % 4]))
        }
        let order = DecodeProfileFitter.Sampling.order(cands, count: 16)
        check(order.count == 32 && Set(order).count == 32, "2 × count unique picks for replacing skipped photos")
        check(order == DecodeProfileFitter.Sampling.order(cands, count: 16), "deterministic")
        let first = order.prefix(16).compactMap { id in cands.first { $0.id == id } }
        check(!first.contains { $0.iso == 51200 }, "extreme ISO (top 2 %) left out")
        let isos = Set(first.compactMap(\.iso))
        check(isos.contains(100) && isos.contains(12800) && isos.count >= 5, "ISO spread across the range: \(isos.sorted())")
        let days = first.compactMap(\.date).map(\.timeIntervalSince1970)
        check((days.max()! - days.min()!) > 0.7 * 999 * 60_000, "dates spread over the whole period")
        let evs = first.compactMap(\.ev100)
        check(evs.max()! - evs.min()! > 8, "scene brightness spread (\(String(format: "%.1f", evs.min()!))…\(String(format: "%.1f", evs.max()!)) EV)")
        let few = DecodeProfileFitter.Sampling.order(Array(cands.prefix(5)), count: 16)
        check(Set(few).count == 5, "fewer candidates than wanted: all of them")
        let bare = DecodeProfileFitter.Sampling.order((0..<40).map { C(id: Int64($0), date: nil, iso: nil, shutter: nil, aperture: nil) }, count: 8)
        check(bare.count == 16, "photos without metadata still sampled")
    }

    // MARK: - Rendering

    /// Mean saturation ((max−min)/max) and fraction of display-clipped pixels in a region (top-left normalized).
    static func stats(_ image: CIImage, _ r: CGRect) -> (sat: Double, clipped: Double, mean: [Double]) {
        let e = image.extent
        let rect = CGRect(x: e.minX + r.minX * e.width, y: e.minY + (1 - r.maxY) * e.height,
                          width: r.width * e.width, height: r.height * e.height).integral
        let w = Int(rect.width), h = Int(rect.height)
        var px = [Float](repeating: 0, count: w * h * 4)
        RenderPipeline.context.render(image, toBitmap: &px, rowBytes: w * 16, bounds: rect, format: .RGBAf,
                                      colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!)
        var sat = 0.0, clipped = 0, sum = [0.0, 0.0, 0.0]
        for i in 0..<(w * h) {
            let c = [px[i * 4], px[i * 4 + 1], px[i * 4 + 2]]
            let mx = c.max()!, mn = c.min()!
            if mx > 0 { sat += Double((mx - mn) / mx) }
            if mx >= 0.98 { clipped += 1 }
            for k in 0..<3 { sum[k] += Double(c[k]) }
        }
        let n = Double(w * h)
        return (sat / n, Double(clipped) / n, sum.map { $0 / n })
    }

    static func save(_ cg: CGImage, _ url: URL) {
        let d = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(d, cg, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        CGImageDestinationFinalize(d)
    }

    static func renderChecks(raw: URL, outDir: URL) throws {
        print("Rendering \(raw.lastPathComponent)")
        let catalog = try Catalog.open(at: outDir.appendingPathComponent("render-catalog-\(Int(Date().timeIntervalSince1970))"))
        try catalog.reloadDecodeRegistry()
        guard let source = RenderPipeline.makeSource(url: raw), let defaults = source.appleDefaults else {
            check(false, "RAW opens"); return
        }
        check(source.camera != nil, "camera read from the RAW: \(source.camera?.displayName ?? "-")")
        check(!defaults.decoderVersions.isEmpty && defaults.decoderVersions.contains(defaults.newestDecoder),
              "decoder versions \(defaults.decoderVersions), newest \(defaults.newestDecoder)")
        check(defaults.values.boost == 1 && defaults.supported.contains("sharpness"), "Apple defaults captured (boost 1, sharpness supported)")
        let target = CGSize(width: 1200, height: 1200)
        let face = CGRect(x: 0.44, y: 0.355, width: 0.10, height: 0.045)
        func render(_ s: EditSettings, _ name: String) -> CIImage {
            let img = RenderPipeline.render(source: source, settings: s, targetSize: target)
            if let cg = RenderPipeline.makeCGImage(img, colorSpace: RenderPipeline.sRGB) { save(cg, outDir.appendingPathComponent(name + ".jpg")) }
            return img
        }
        let base = render(EditSettings(), "decode_default")
        let sBase = stats(base, face)
        print(String(format: "    default: face saturation %.2f, clipped %.0f%%", sBase.sat, sBase.clipped * 100))

        let old = try catalog.allDecodeProfiles().first { $0.name.hasPrefix("Previous Highlights") }!
        var oldSettings = EditSettings(); oldSettings.decode.profileID = old.id
        let sOld = stats(render(oldSettings, "decode_previous_highlights"), face)
        print(String(format: "    previous highlights profile: face saturation %.2f", sOld.sat))
        check(sOld.sat < 0.6, "the old clip fade reproduces the bleached face (sat \(String(format: "%.2f", sOld.sat)))")
        check(sBase.sat > sOld.sat + 0.2, "the new built-in keeps the face's colour (sat \(String(format: "%.2f", sBase.sat)))")

        var flat = EditSettings(); flat.decode.overrides.boost = 0
        let sFlat = stats(render(flat, "decode_boost0"), face)
        check(abs(sFlat.mean[0] - sBase.mean[0]) > 0.02, "boost 0 changes the render")

        // The shared filter is reset to the file's defaults when a knob is no longer overridden.
        var soft = EditSettings(); soft.decode.overrides.sharpness = 0; soft.decode.overrides.luminanceNoiseReduction = 1
        _ = render(soft, "decode_soft")
        let again = stats(render(EditSettings(), "decode_default_again"), face)
        check(abs(again.sat - sBase.sat) < 1e-4 && abs(again.mean[1] - sBase.mean[1]) < 1e-4, "knobs reset to Apple's defaults afterwards")

        // Pinning an older decoder renders (and an unknown one falls back to the newest).
        if let older = defaults.decoderVersions.first(where: { $0 != defaults.newestDecoder }) {
            var pin = EditSettings(); pin.decode.decoderVersion = older
            let sPin = stats(render(pin, "decode_v\(older)"), face)
            check(sPin.mean[0] > 0, "renders with decoder \(older)")
        }
        var bogus = EditSettings(); bogus.decode.decoderVersion = "999"
        let sBogus = stats(render(bogus, "decode_bogus"), face)
        check(abs(sBogus.mean[1] - sBase.mean[1]) < 1e-4, "unknown pinned decoder falls back to the newest")

        // Camera default applies through the registry.
        if let cam = source.camera {
            let flatProfile = try catalog.allDecodeProfiles().first { $0.name == "Flat for Editing" }!
            try catalog.setCameraDecodeDefault(cam, profileID: flatProfile.id)
            let sCam = stats(render(EditSettings(), "decode_camera_flat"), face)
            check(abs(sCam.mean[0] - sFlat.mean[0]) < 1e-4, "camera default (Flat) renders like boost 0")
            try catalog.setCameraDecodeDefault(cam, profileID: nil)
        }
        print("    renders in \(outDir.path)")
        try fitChecks(raw: raw)
    }

    /// Match Camera JPEG on the RAW and up to 3 neighbours (short run: 40 evaluations).
    static func fitChecks(raw: URL) throws {
        print("Match Camera JPEG")
        let dir = raw.deletingLastPathComponent()
        let ext = raw.pathExtension.lowercased()
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { ($0 as NSString).pathExtension.lowercased() == ext }.sorted()
        let urls = [raw] + names.filter { $0 != raw.lastPathComponent }.prefix(3).map { dir.appendingPathComponent($0) }
        let samples = urls.compactMap { DecodeProfileFitter.prepare(url: $0) }
        check(!samples.isEmpty, "\(samples.count)/\(urls.count) photos have a comparable camera JPEG")
        guard !samples.isEmpty else { return }
        var reported = 0.0
        let r = try DecodeProfileFitter.fit(samples: samples, maxEvaluations: 40, progress: { reported = $0 })
        print("    " + r.summary + " " + DecodeProfileRegistry.json(r.params))
        check(r.errorAfter <= r.errorBefore, "fit never makes the match worse")
        check(reported == 1, "progress reaches 1")
        check(DecodeProfileFitter.dimensions.allSatisfy { d in r.params[keyPath: d.keyPath].map { d.range.contains($0) } ?? false },
              "every fitted parameter set and within bounds")
        check(abs(DecodeProfileFitter.error(samples, r.params) - r.errorAfter) < 1e-3, "fitted (rounded) params reproduce the error")
        if case .success = DecodeProfileFitter.prepareChecked(url: raw) { check(true, "the portrait passes the exposure checks") }
        else { check(false, "the portrait passes the exposure checks") }
        // A monochrome picture style: the camera JPEG has no colour, the RAW does.
        let mono = samples.map { s in
            DecodeProfileFitter.Sample(url: s.url, source: s.source, size: s.size, target: s.target.map { SIMD3($0.x, 0, 0) })
        }
        let mixed = samples + [mono[0]]
        let (kept, rejected) = DecodeProfileFitter.rejectOutliers(mixed)
        check(rejected.count == 1 && rejected[0] === mono[0] && kept.count == samples.count,
              "a monochrome-style JPEG is dropped as unlike its RAW (kept \(kept.count), dropped \(rejected.count))")
        check(DecodeProfileFitter.rejectOutliers(samples).rejected.isEmpty, "normal photos are all kept")
        var withSkips = r; withSkips.skipped = ["nearly black": 2]
        check(withSkips.summary.hasSuffix("Skipped 2 nearly black."), "summary lists skipped photos")
        var calls = 0
        do {
            _ = try DecodeProfileFitter.fit(samples: samples, isCancelled: { calls += 1; return calls > 3 })
            check(false, "cancel stops the fit")
        } catch DecodeProfileFitter.FitError.cancelled {
            check(true, "cancel stops the fit")
        }
    }
}
