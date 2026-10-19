//
//  insta_export_check.swift
//  Instagram export (Kika/Instagram/InstaExport.swift): file layout and names, one image per cell / split strip at the
//  right sizes, framing (offset, rotation, scale below Fill) as the board places it, post.txt, the plan's subfolders,
//  offline photos, no overwrites, cancel.
//
//  Build & run:
//    Tools/harness.sh /private/tmp/claude-501/insta-export-out/insta_export_check Tools/insta_export_check.swift \
//      Kika/Instagram/InstaModels.swift Kika/Instagram/Catalog+Insta.swift Kika/Instagram/InstaExport.swift \
//      Kika/Export/ExportEngine.swift Kika/Develop/Crop/CropMath.swift
//    /private/tmp/claude-501/insta-export-out/insta_export_check [out-dir]
//
//  Draws its own test photos (four coloured quadrants) into out-dir; no sample photos needed (runs in CI).
//

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

@main
struct InstaExportCheck {
    nonisolated(unsafe) static var failures = 0

    static func check(_ ok: Bool, _ name: String) {
        print("  \(ok ? "PASS" : "FAIL") \(name)")
        if !ok { failures += 1 }
    }

    enum Hue: String { case red, green, blue, yellow, white, black, other }

    /// A JPEG of `size` with red / green (top) and blue / yellow (bottom) quadrants.
    static func writeQuadrants(_ url: URL, size: CGSize) throws {
        let w = Int(size.width), h = Int(size.height)
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let quads: [(CGFloat, CGFloat, CGFloat, CGFloat, CGFloat)] = [   // x, y (y-up), r, g, b
            (0, 0.5, 1, 0, 0), (0.5, 0.5, 0, 1, 0), (0, 0, 0, 0, 1), (0.5, 0, 1, 1, 0),
        ]
        for (x, y, r, g, b) in quads {
            ctx.setFillColor(CGColor(srgbRed: r, green: g, blue: b, alpha: 1))
            ctx.fill(CGRect(x: x * size.width, y: y * size.height, width: size.width / 2, height: size.height / 2))
        }
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
    }

    /// Decoded pixels of a written JPEG (RGBA, rows top to bottom).
    struct Pixels {
        var width: Int, height: Int, data: [UInt8]
        init?(_ url: URL) {
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
            width = img.width; height = img.height
            data = [UInt8](repeating: 0, count: width * height * 4)
            let ok = data.withUnsafeMutableBytes { buf -> Bool in
                guard let ctx = CGContext(data: buf.baseAddress, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: img.width * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
                ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
                return true
            }
            if !ok { return nil }
        }
        func hue(_ x: Int, _ y: Int) -> Hue {
            let i = (y * width + x) * 4
            let r = data[i] > 160, g = data[i + 1] > 160, b = data[i + 2] > 160
            let r0 = data[i] < 90, g0 = data[i + 1] < 90, b0 = data[i + 2] < 90
            switch (r, g, b) {
            case (true, false, false) where g0 && b0: return .red
            case (false, true, false) where r0 && b0: return .green
            case (false, false, true) where r0 && g0: return .blue
            case (true, true, false) where b0: return .yellow
            case (true, true, true): return .white
            default: return r0 && g0 && b0 ? .black : .other
            }
        }
    }

    static func hues(_ url: URL, _ points: [(Int, Int)]) -> [Hue] {
        guard let p = Pixels(url) else { return [] }
        return points.map { p.hue($0.0, $0.1) }
    }

    static func size(_ url: URL) -> CGSize {
        guard let p = Pixels(url) else { return .zero }
        return CGSize(width: p.width, height: p.height)
    }

    static func listing(_ dir: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
    }

    static func main() async throws {
        let args = CommandLine.arguments
        let outDir = URL(fileURLWithPath: args.count > 1 ? args[1] : "/private/tmp/claude-501/insta-export-out")
        let work = outDir.appendingPathComponent("insta-export-\(UUID().uuidString.prefix(8))")
        let fm = FileManager.default
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { if failures == 0 { try? fm.removeItem(at: work) } }
        let catalog = try Catalog.open(at: work.appendingPathComponent("catalog"))

        let photosDir = work.appendingPathComponent("photos")
        try fm.createDirectory(at: photosDir, withIntermediateDirectories: true)
        let wideURL = photosDir.appendingPathComponent("WIDE.jpg"), tallURL = photosDir.appendingPathComponent("TALL.jpg")
        try writeQuadrants(wideURL, size: CGSize(width: 1600, height: 1200))
        try writeQuadrants(tallURL, size: CGSize(width: 1200, height: 1600))
        let ids = try catalog.insertPhotos([Photo(path: wideURL.path), Photo(path: tallURL.path),
                                            Photo(path: photosDir.appendingPathComponent("MISSING.jpg").path)])
        let (wide, tall, missing) = (ids[0], ids[1], ids[2])

        // Post 1 (4:5): plain, moved right, split ×3, rotated 90°, scaled to half.
        let folder = try catalog.createFolder(name: "Trip")
        let plan = try catalog.createInstaPlan(folderID: folder)
        let post1 = try catalog.createInstaPost(planID: plan, kind: .post)
        let stories = try catalog.createInstaPost(planID: plan, kind: .story)
        let post2 = try catalog.createInstaPost(planID: plan, kind: .post)
        _ = try catalog.createInstaPost(planID: plan, kind: .post)   // Post 3: empty, left out of a plan export
        let s = try catalog.addInstaSlides(postID: post1, photoIDs: [wide, wide, wide, wide, wide])
        try catalog.setInstaCellTransforms(slideID: s[1], [0: InstaTransform(offsetX: 0.2)])
        try catalog.setInstaSlideSpan(slideID: s[2], span: 3)
        try catalog.setInstaCellTransforms(slideID: s[3], [0: InstaTransform(rotation: 90)])
        try catalog.setInstaCellTransforms(slideID: s[4], [0: InstaTransform(scale: 0.5)])
        var p1 = try catalog.instaPosts(planID: plan)[0]
        p1.caption = "Golden hour ✨\nOn the road again.\n\n#trip #iceland"
        p1.scheduledAt = Date(timeIntervalSince1970: 1_792_605_600)   // 2026-10-21 18:00 UTC
        p1.status = .ready
        try catalog.updateInstaPost(p1)

        // Stories 1: 3 stacked (wide, tall, wide) on black; a 2 × 2 grid with cells 1 and 3 filled.
        let f1 = try catalog.addInstaSlide(postID: stories, layout: .stack3)
        try catalog.setInstaCells(slideID: f1, from: 0, photoIDs: [wide, tall, wide])
        try catalog.setInstaSlideStyle(slideID: f1, background: "#000000", gap: 0.015)
        let f2 = try catalog.addInstaSlide(postID: stories, layout: .grid4)
        try catalog.setInstaCells(slideID: f2, from: 0, photoIDs: [wide])
        try catalog.setInstaCells(slideID: f2, from: 2, photoIDs: [tall])
        // Post 2: an offline photo and no caption.
        try catalog.addInstaSlides(postID: post2, photoIDs: [missing])

        let posts = try catalog.instaPosts(planID: plan)
        let gb = Locale(identifier: "en_GB"), utc = TimeZone(identifier: "UTC")!

        print("Layout")
        let planFolders = InstaExportLayout.folders(for: .plan(plan), posts: posts, locale: gb, timeZone: utc)
        check(planFolders.map { $0.name ?? "-" } == ["01 Post 1", "02 Stories 1", "03 Post 2"], "plan: a numbered folder per post / story set, empty Post 3 left out")
        check(planFolders[0].images.flatMap(\.fileNames) == ["01", "02", "03-1", "03-2", "03-3", "04", "05"], "post: board numbers, split strips 03-1…03-3")
        check(planFolders[1].images.flatMap(\.fileNames) == ["01-1", "01-2", "01-3", "02-1", "02-3"], "stories: layout cells by cell number, empty cells skipped")
        check(planFolders[0].postText != nil && planFolders[1].postText == nil, "post.txt for posts only")
        let slideFolders = InstaExportLayout.folders(for: .slide(s[2]), posts: posts)
        check(slideFolders.count == 1 && slideFolders[0].name == nil && slideFolders[0].images[0].fileNames == ["Post 1 03-1", "Post 1 03-2", "Post 1 03-3"],
              "slide: straight into the folder, titled")
        let story = AspectSizes(planFolders[1].images.map(\.fileSize))
        check(story.list == ["1080×635", "1080×643", "1080×635", "1080×1960", "1080×1960"], "story cells keep their shape at 1080 wide: \(story.list)")
        check(InstaExportLayout.fileSafe("a/b: c\nd", fallback: "x") == "a-b- c d" && InstaExportLayout.fileSafe(" ..", fallback: "Post") == "Post",
              "titles made file-safe")

        print("post.txt")
        let text = InstaExportText.post(posts[0], locale: gb, timeZone: utc)
        let footer = text.split(separator: "\n", omittingEmptySubsequences: false).suffix(3)
        check(text.hasPrefix("Golden hour ✨\nOn the road again.\n\n#trip #iceland\n\nPlanned: ") && text.hasSuffix("\nStatus: Ready\n")
              && footer.first.map { $0.contains("21 Oct 2026") && $0.contains("18:00") } == true,
              "caption as written, then a blank line, date and status:\n\(text)")
        var bare = posts[2]
        bare.status = .draft
        check(InstaExportText.post(bare, locale: gb, timeZone: utc) == "Status: Draft\n", "no caption, no date: status only")

        print("Plan export")
        let out = work.appendingPathComponent("out")
        try fm.createDirectory(at: out, withIntermediateDirectories: true)
        let job = try InstaExportJob(catalog: catalog, scope: .plan(plan), destination: out, locale: gb, timeZone: utc)
        let progress = ProgressLog()
        let result = job.run { progress.add($0) }
        print("  \(result.summary) in \(String(format: "%.1f", result.elapsed)) s")
        check(listing(out) == ["01 Post 1", "02 Stories 1", "03 Post 2"], "subfolders in board order: \(listing(out))")
        let postDir = out.appendingPathComponent("01 Post 1"), storyDir = out.appendingPathComponent("02 Stories 1")
        check(listing(postDir) == ["01.jpg", "02.jpg", "03-1.jpg", "03-2.jpg", "03-3.jpg", "04.jpg", "05.jpg", "post.txt"], "post files: \(listing(postDir))")
        check(listing(storyDir) == ["01-1.jpg", "01-2.jpg", "01-3.jpg", "02-1.jpg", "02-3.jpg"], "story files, no post.txt: \(listing(storyDir))")
        check(listing(out.appendingPathComponent("03 Post 2")) == ["post.txt"], "offline photo's post: post.txt only")
        check(result.skipped.map(\.fileName) == ["01.jpg"] && result.skipped.first?.reason == .offline, "offline photo skipped")
        check((try? String(contentsOf: postDir.appendingPathComponent("post.txt"), encoding: .utf8)) == text, "post.txt written")
        check(result.imageCount == 12 && result.stopError == nil && !result.wasCancelled, "12 images: \(result.summary)")
        check(progress.last?.done == job.fileCount && progress.last?.total == job.fileCount, "progress reaches every file (\(job.fileCount))")

        print("Sizes")
        let postSizes = AspectSizes(["01", "02", "03-1", "03-2", "03-3", "04", "05"].map { size(postDir.appendingPathComponent("\($0).jpg")) })
        check(Set(postSizes.list) == ["1080×1350"], "every post image 1080×1350 (4:5): \(postSizes.list)")
        let storySizes = AspectSizes(["01-1", "01-2", "01-3", "02-1", "02-3"].map { size(storyDir.appendingPathComponent("\($0).jpg")) })
        check(storySizes.list == story.list, "story images as laid out: \(storySizes.list)")

        print("Framing (photo 1600×1200: red | green over blue | yellow)")
        // Plain: fills 1080×1350 (scaled to 1800×1350), centred: the quadrants meet in the middle.
        check(hues(postDir.appendingPathComponent("01.jpg"), [(480, 600), (600, 600), (480, 750), (600, 750)]) == [.red, .green, .blue, .yellow],
              "centred")
        // offsetX 0.2: the centre moves to x = 756.
        check(hues(postDir.appendingPathComponent("02.jpg"), [(700, 300), (812, 300), (20, 1300), (1060, 1300)]) == [.red, .green, .blue, .yellow],
              "moved right by a fifth of the cell")
        // Split ×3: 3240×1350 cell, the photo's middle at x = 1620 = the middle of strip 2.
        check(hues(postDir.appendingPathComponent("03-1.jpg"), [(20, 300), (1060, 300)]) == [.red, .red]
              && hues(postDir.appendingPathComponent("03-2.jpg"), [(480, 300), (600, 300), (480, 1000), (600, 1000)]) == [.red, .green, .blue, .yellow]
              && hues(postDir.appendingPathComponent("03-3.jpg"), [(20, 300), (1060, 1000)]) == [.green, .yellow], "split strips continue each other")
        // Rotated 90° clockwise: red moves to the top right, blue to the top left.
        check(hues(postDir.appendingPathComponent("04.jpg"), [(800, 300), (300, 300), (800, 1000), (300, 1000)]) == [.red, .blue, .green, .yellow],
              "rotated clockwise")
        // Half scale: 900×675 centred, the white background around it.
        check(hues(postDir.appendingPathComponent("05.jpg"), [(20, 20), (1060, 1330), (440, 575), (640, 775)]) == [.white, .white, .red, .yellow],
              "scaled below Fill: background shows")
        // Story stack3 cell 2: the tall photo fills a wide cell, so only its middle band shows (meeting point centred).
        check(hues(storyDir.appendingPathComponent("01-2.jpg"), [(480, 280), (600, 280), (480, 360), (600, 360)]) == [.red, .green, .blue, .yellow],
              "tall photo in a wide cell: centred")
        check(hues(storyDir.appendingPathComponent("01-1.jpg"), [(2, 2), (1077, 632)]) == [.red, .yellow], "no gap or background around a cell")

        print("Post and slide export")
        let again = try InstaExportJob(catalog: catalog, scope: .post(post1), destination: out).run()
        check(again.folders.map(\.lastPathComponent) == ["Post 1"] && again.imageCount == 7, "post: its own folder")
        let twice = try InstaExportJob(catalog: catalog, scope: .post(post1), destination: out).run()
        check(twice.folders.map(\.lastPathComponent) == ["Post 1 (2)"], "existing folder never reused: \(twice.folders.map(\.lastPathComponent))")
        let slide = try InstaExportJob(catalog: catalog, scope: .slide(f1), destination: out).run()
        check(slide.files.map(\.lastPathComponent) == ["Stories 1 01-1.jpg", "Stories 1 01-2.jpg", "Stories 1 01-3.jpg"] && slide.folders.isEmpty,
              "slide: \(slide.files.map(\.lastPathComponent))")
        let slide2 = try InstaExportJob(catalog: catalog, scope: .slide(f1), destination: out).run()
        check(slide2.files.first?.lastPathComponent == "Stories 1 01-1-1.jpg", "slide files never overwritten: \(slide2.files.map(\.lastPathComponent))")

        print("Cancel, temp files")
        let cancelled = try InstaExportJob(catalog: catalog, scope: .plan(plan), destination: out)
        cancelled.cancel()
        let c = cancelled.run()
        check(c.wasCancelled && c.files.isEmpty, "cancelled before start: nothing written")
        let temps = ([out, postDir, storyDir] + again.folders).flatMap { ExportFiles.tempFiles(in: $0) }
        check(temps.isEmpty, "no temp files left")

        print(failures == 0 ? "ALL PASS" : "\(failures) FAILED (output kept in \(work.path))")
        if failures > 0 { exit(1) }
    }
}

/// "1080×1350" per size.
struct AspectSizes {
    var list: [String]
    init(_ sizes: [CGSize]) { list = sizes.map { "\(Int($0.width))×\(Int($0.height))" } }
}

final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [InstaExportProgress] = []
    func add(_ p: InstaExportProgress) { lock.lock(); values.append(p); lock.unlock() }
    var last: InstaExportProgress? { lock.lock(); defer { lock.unlock() }; return values.last }
}
