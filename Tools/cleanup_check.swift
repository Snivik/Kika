//
//  cleanup_check.swift
//  Clean Up (Kika/Cleanup/): grouping rules, crop scoring, sharpness on drawn photos (sharp / defocused / shaken),
//  and a whole run on a temp catalog: verdicts as workflow tag values, similar groups + keeper, "kept by you"
//  surviving a re-run, the analysis cache, virtual copies skipped. Draws its own photos (runs in CI; Vision).
//
//  Build & run:
//    Tools/harness.sh /private/tmp/claude-501/cleanup/cleanup_check Tools/cleanup_check.swift Kika/Cleanup/*.swift Kika/VirtualCopies/Catalog+VirtualCopies.swift
//    /private/tmp/claude-501/cleanup/cleanup_check [out-dir]
//

import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

@main
struct CleanupHarness {
    nonisolated(unsafe) static var failures = 0

    static func check(_ ok: Bool, _ name: String) {
        print("  \(ok ? "PASS" : "FAIL") \(name)")
        if !ok { failures += 1 }
    }

    static func main() async throws {
        let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/private/tmp/claude-501/cleanup")
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        grouping()
        crop()
        let photos = try drawPhotos(out)
        sharpness(photos)
        try catalogRun(out, photos)

        print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
        exit(failures == 0 ? 0 : 1)
    }

    // MARK: Grouping

    static func grouping() {
        print("Grouping")
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        func item(_ id: Int64, _ s: Double, _ f: [Float], q: Double = 0, flag: Flag = .none, kept: Bool = false) -> CleanupGroupingItem {
            CleanupGroupingItem(id: id, date: t0.addingTimeInterval(s), fileName: "P\(id).JPG", feature: f, flag: flag, kept: kept, quality: q)
        }
        let a: [Float] = [1, 0, 0], a2: [Float] = [0.95, 0.2, 0], b: [Float] = [0, 1, 0]
        // Burst of 3, a different scene, a lone shot, then the same scene again much later.
        var items = [item(1, 0, a), item(2, 1, a2, q: 0.5), item(3, 2, a), item(4, 3, b), item(5, 400, a), item(6, 401, [])]
        var g = CleanupGrouping.groups(items, maxDistance: 0.33, maxGap: 120)
        check(g.count == 1 && g[0].photoIDs == [1, 2, 3] && g[0].id == 1, "a burst groups; another scene and a later return don't: \(g.map(\.photoIDs))")
        check(g.first?.bestID == 2, "the best looking shot is the keeper")
        items[0].flag = .pick
        check(CleanupGrouping.groups(items, maxDistance: 0.33, maxGap: 120).first?.bestID == 1, "a picked photo is the keeper")
        items[0].flag = .none; items[2].kept = true
        check(CleanupGrouping.groups(items, maxDistance: 0.33, maxGap: 120).first?.bestID == 3, "a photo you kept is the keeper")
        items[1].flag = .reject; items[2].kept = false
        check(CleanupGrouping.groups(items, maxDistance: 0.33, maxGap: 120).first?.bestID != 2, "a rejected photo is never the keeper")

        // Gap allowance: 0.36 apart is a burst at 1 s, not at 30 s.
        let c: [Float] = [1, 0], d: [Float] = [1, 0.36]
        g = CleanupGrouping.groups([item(10, 0, c), item(11, 1, d)], maxDistance: 0.33, maxGap: 120)
        check(g.count == 1, "bursts get a little more room")
        g = CleanupGrouping.groups([item(10, 0, c), item(11, 30, d)], maxDistance: 0.33, maxGap: 120)
        check(g.isEmpty, "shots 30 s apart need to look closer")
        // A slow pan: each step close to the last, the end far from the start.
        var pan: [CleanupGroupingItem] = []
        for i in 0..<8 {
            let angle = Double(i) * 0.3
            let f: [Float] = [Float(cos(angle)), Float(sin(angle))]
            pan.append(item(Int64(20 + i), Double(i), f))
        }
        g = CleanupGrouping.groups(pan, maxDistance: 0.33, maxGap: 120)
        check(g.count >= 2, "a pan doesn't chain into one group: \(g.map(\.photoIDs))")
        check(CleanupGrouping.distance([1, 2], [1]) == .infinity && CleanupGrouping.distance([0, 3], [4, 0]) == 5, "distance")
    }

    // MARK: Crop

    static func crop() {
        print("Crop")
        let face = CGRect(x: 0.4, y: 0.4, width: 0.12, height: 0.15)
        check(CleanupAnalyzer.cropScore(faces: [face], pose: [], humans: [], animals: []).score == 0, "a face inside the frame isn't cut")
        let left = CleanupAnalyzer.cropScore(faces: [CGRect(x: -0.04, y: 0.4, width: 0.12, height: 0.15)], pose: [], humans: [], animals: [])
        check(left.score >= 0.8 && left.reason == "Face cut at the left edge", "a face at the left edge: \(left)")
        let top = CleanupAnalyzer.cropScore(faces: [CGRect(x: 0.4, y: 0.88, width: 0.12, height: 0.12)], pose: [], humans: [], animals: [])
        check(top.score < CleanupOptions().cropThreshold && top.score >= CleanupOptions(cropSensitivity: .high).cropThreshold,
              "a trimmed forehead only counts at More: \(top.score)")
        let tiny = CleanupAnalyzer.cropScore(faces: [CGRect(x: 0, y: 0.4, width: 0.02, height: 0.02)], pose: [], humans: [], animals: [])
        check(tiny.score == 0, "a tiny background face doesn't count")
        let slice = CleanupAnalyzer.cropScore(faces: [], pose: [], humans: [CGRect(x: 0.9, y: 0.1, width: 0.1, height: 0.6)], animals: [])
        check(slice.score > 0 && slice.score < CleanupOptions().cropThreshold, "a person sliced at the side only counts at More")
    }

    // MARK: Sharpness

    nonisolated struct Drawn { var sharp: URL; var sharp2: URL; var defocused: URL; var shaken: URL; var other: URL }

    static func drawPhotos(_ out: URL) throws -> Drawn {
        let scene = drawScene(width: 1800, height: 1200, shift: 0, seed: 1)
        let ctx = CIContext()
        func save(_ image: CGImage, _ name: String) throws -> URL {
            let url = out.appendingPathComponent(name)
            guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { throw CocoaError(.fileWriteUnknown) }
            CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary)
            guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
            return url
        }
        func filtered(_ name: String, _ params: [String: Any]) -> CGImage {
            let ci = CIImage(cgImage: scene).clampedToExtent().applyingFilter(name, parameters: params)
                .cropped(to: CGRect(x: 0, y: 0, width: scene.width, height: scene.height))
            return ctx.createCGImage(ci, from: ci.extent)!
        }
        return Drawn(sharp: try save(scene, "sharp.jpg"),
                     sharp2: try save(drawScene(width: 1800, height: 1200, shift: 6, seed: 1), "sharp2.jpg"),
                     defocused: try save(filtered("CIGaussianBlur", [kCIInputRadiusKey: 4.0]), "defocused.jpg"),
                     shaken: try save(filtered("CIMotionBlur", [kCIInputRadiusKey: 10.0, kCIInputAngleKey: 0.3]), "shaken.jpg"),
                     other: try save(drawScene(width: 1800, height: 1200, shift: 0, seed: 7), "other.jpg"))
    }

    static func sharpness(_ d: Drawn) {
        print("Sharpness (drawn photos)")
        func score(_ url: URL) -> Double {
            guard let image = PreviewDiskCache.decode(url: url, maxPixelSize: CleanupAnalyzer.side) else { return -1 }
            return CleanupAnalyzer.analyze(image).analysis.sharpness
        }
        let sharp = score(d.sharp), defocused = score(d.defocused), shaken = score(d.shaken)
        let o = CleanupOptions()
        check(sharp > CleanupOptions(blurSensitivity: .high).blurThreshold, String(format: "a sharp photo isn't blurry even at More: %.2f", sharp))
        check(defocused < CleanupOptions(blurSensitivity: .low).blurThreshold, String(format: "a defocused photo is blurry at Only Obvious: %.2f", defocused))
        check(shaken < o.blurThreshold, String(format: "a shaken photo is blurry: %.2f", shaken))
    }

    // MARK: Whole run on a catalog

    static func catalogRun(_ out: URL, _ d: Drawn) throws {
        print("Run (temp catalog)")
        let catalog = try Catalog.open(at: out.appendingPathComponent("catalog"))
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        func photo(_ url: URL, _ s: Double) -> Photo {
            var p = Photo(path: url.path)
            p.width = 1800; p.height = 1200
            p.captureDate = base.addingTimeInterval(s)
            return p
        }
        // sharp + sharp2 + defocused: a burst (one scene); other: 5 minutes later; shaken: alone much later.
        let ids = try catalog.insertPhotos([photo(d.sharp, 0), photo(d.sharp2, 1), photo(d.defocused, 2), photo(d.other, 300), photo(d.shaken, 900)])
        let (sharp, sharp2, defocused, other, shaken) = (ids[0], ids[1], ids[2], ids[3], ids[4])
        let copies = try catalog.createVirtualCopies(of: [sharp])

        let job = CleanupJob()
        var progressCalls = 0
        let s1 = try job.run(photoIDs: ids + copies.map(\.id), options: CleanupOptions(), catalog: catalog) { _ in progressCalls += 1 }
        check(s1.photos == 5 && s1.analysed == 5 && s1.skippedVirtualCopies == 1 && progressCalls >= 5, "analyses masters only: \(s1)")

        let tags = try catalog.existingCleanupTagIDs()
        check(tags.count == 3, "Blurry, Cropped and Duplicate tags exist")
        let values = try catalog.photoTagValues()
        func workflow(_ id: Int64, _ c: CleanupCheck) -> String? { values[id]?[tags[c]!]?.byAuthor.first { $0.author == CleanupTags.author }?.value }
        check(workflow(defocused, .blurry) == "true" && workflow(shaken, .blurry) == "true", "defocused + shaken photos are flagged Blurry")
        check(workflow(sharp, .blurry) == nil && workflow(other, .blurry) == nil, "sharp photos get no Blurry value (not even false)")

        let groups = try catalog.cleanupGroups()
        check(groups.count == 1 && Set(groups[0].photoIDs) == [sharp, sharp2, defocused], "the burst is one group: \(groups.map(\.photoIDs))")
        check(groups.first.map { $0.bestID != defocused } ?? false, "the defocused shot isn't the keeper")
        let best = groups.first?.bestID ?? 0
        check(workflow(best, .similar) == nil && [sharp, sharp2, defocused].filter { $0 != best }.allSatisfy { workflow($0, .similar) == "true" },
              "the group's other shots are Duplicate, the keeper isn't")

        // Review: you keep the defocused one (artistic) and reject one duplicate.
        let blurryReview = try catalog.photos(in: .all, filter: PhotoFilter(tags: [TagCondition(tagID: tags[.blurry]!, match: .toReview(CleanupTags.yes))]))
        check(Set(blurryReview.map(\.id)) == [defocused, shaken], "To Review lists the flagged photos")
        try catalog.setPhotoTag(tags[.blurry]!, value: CleanupTags.no, for: [defocused])
        check(try catalog.cleanupKeptPhotoIDs(tagID: tags[.blurry]!) == [defocused], "kept by you")

        // Re-run (cached): nothing re-analysed, the kept photo stays kept.
        let s2 = try job.run(photoIDs: ids, options: CleanupOptions(), catalog: catalog)
        check(s2.analysed == 0 && s2.reused == 5, "a re-run reuses the analyses: \(s2)")
        let again = try catalog.photos(in: .all, filter: PhotoFilter(tags: [TagCondition(tagID: tags[.blurry]!, match: .toReview(CleanupTags.yes))]))
        check(again.map(\.id) == [shaken], "a photo you kept never comes back for review")
        let mine = try catalog.photoTagValues()[defocused]?[tags[.blurry]!]
        check(mine?.effective?.value == CleanupTags.no && mine?.suggested?.value == CleanupTags.yes, "your value wins over the workflow's")

        // A picked photo is never flagged.
        try catalog.setFlag(.pick, for: [shaken])
        _ = try job.run(photoIDs: ids, options: CleanupOptions(), catalog: catalog)
        let picked = try catalog.photos(in: .all, filter: PhotoFilter(tags: [TagCondition(tagID: tags[.blurry]!, match: .toReview(CleanupTags.yes))]))
        check(picked.isEmpty, "a picked photo is never flagged")

        // An edit re-analyses that photo only.
        _ = try catalog.saveEditSettings({ var e = EditSettings(); e.tone.exposure = 0.3; return e }(), for: other)
        let s3 = try job.run(photoIDs: ids, options: CleanupOptions(checks: [.blurry]), catalog: catalog)
        check(s3.analysed == 1 && s3.flagged[.similar] == nil, "an edited photo is re-analysed; only the chosen checks run: \(s3)")

        // Removing a photo drops its analysis and group row.
        try catalog.removePhotos(ids: [sharp2])
        check(try catalog.cleanupAnalyses().count == 4, "analyses cascade with their photo")
        check(try catalog.cleanupGroups().first.map { !$0.photoIDs.contains(sharp2) } ?? true, "group rows cascade with their photo")

        // Cancel before starting: nothing written.
        let cancelled = CleanupJob()
        cancelled.cancel()
        let s4 = try cancelled.run(photoIDs: [shaken], options: CleanupOptions(), catalog: catalog) { _ in }
        check(s4.cancelled || s4.analysed == 0, "a cancelled run stops")
    }

    // MARK: Drawing

    /// A textured street scene: bricks, text, thin lines, a figure. `shift` moves the camera a little.
    static func drawScene(width: Int, height: Int, shift: CGFloat, seed: UInt64) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        var rng = seed
        func rand() -> CGFloat { rng = rng &* 6364136223846793005 &+ 1442695040888963407; return CGFloat(rng >> 33) / CGFloat(1 << 31) }
        let w = CGFloat(width), h = CGFloat(height)
        ctx.setFillColor(CGColor(red: 0.55, green: 0.7, blue: 0.9, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.translateBy(x: shift, y: 0)
        // Bricks.
        for row in 0..<Int(h * 0.6 / 24) {
            for col in -1..<Int(w / 60) + 1 {
                let x = CGFloat(col) * 60 + (row % 2 == 0 ? 0 : 30), y = CGFloat(row) * 24
                ctx.setFillColor(CGColor(red: 0.5 + 0.3 * rand(), green: 0.25 + 0.1 * rand(), blue: 0.2, alpha: 1))
                ctx.fill(CGRect(x: x + 2, y: y + 2, width: 56, height: 20))
            }
        }
        // Thin poles and wires.
        ctx.setStrokeColor(CGColor(gray: 0.1, alpha: 1)); ctx.setLineWidth(2)
        for i in 0..<12 {
            let x = CGFloat(i) * w / 12 + 40 * rand()
            ctx.move(to: CGPoint(x: x, y: 0)); ctx.addLine(to: CGPoint(x: x, y: h * 0.9)); ctx.strokePath()
            ctx.move(to: CGPoint(x: x, y: h * 0.85)); ctx.addLine(to: CGPoint(x: x + w / 12, y: h * 0.8 + 30 * rand())); ctx.strokePath()
        }
        // Checker sign + a "figure" (the subject).
        for i in 0..<10 { for j in 0..<10 where (i + j) % 2 == 0 {
            ctx.setFillColor(CGColor(gray: 0.05, alpha: 1)); ctx.fill(CGRect(x: w * 0.6 + CGFloat(i) * 14, y: h * 0.65 + CGFloat(j) * 14, width: 14, height: 14))
        } }
        ctx.setFillColor(CGColor(red: 0.9, green: 0.75, blue: 0.6, alpha: 1)); ctx.fillEllipse(in: CGRect(x: w * 0.3, y: h * 0.62, width: 90, height: 110))
        ctx.setFillColor(CGColor(red: 0.15, green: 0.2, blue: 0.5, alpha: 1)); ctx.fill(CGRect(x: w * 0.28, y: h * 0.3, width: 130, height: 260))
        for k in 0..<40 {
            ctx.setStrokeColor(CGColor(gray: rand(), alpha: 1)); ctx.setLineWidth(1)
            let x = w * 0.28 + 130 * rand(), y = h * 0.3 + 260 * rand()
            ctx.move(to: CGPoint(x: x, y: y)); ctx.addLine(to: CGPoint(x: x + 20, y: y + CGFloat(k % 5))); ctx.strokePath()
        }
        return ctx.makeImage()!
    }
}
