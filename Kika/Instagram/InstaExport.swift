//
//  InstaExport.swift
//  Kika
//
//  Instagram export (UI-free; compiled by Tools/insta_export_check.swift): a slide, a post / story set or a whole plan
//  as ready-to-upload JPEGs. Every photo is its own image, never a composite of a layout:
//    - a single-photo slide → one image at the post's export size (`InstaAspect.pixelSize`, 1080 wide);
//    - a layout → one image per filled cell, in the cell's shape (its rect at export size, `cellRects`), 1080 wide;
//    - a split (span n) → the photo framed in its n-slide-wide cell, cut into n strips at the post's export size.
//  Each photo is framed in its cell exactly as on the board (InstaFraming), rendered with its Develop edits
//  (RenderPipeline, at the resolution the framing needs), 8-bit sRGB, metadata kept (ExportMetadata). Where a photo
//  scaled below Fill leaves part of its cell uncovered, the slide's background shows, as on the board; the gaps and
//  margins around cells are never exported.
//
//  Files sort in posting order: "01.jpg", "02.jpg", …, numbered by the slide's position on the board; the parts of a
//  layout or split are "03-1.jpg", "03-2.jpg", … (a layout's by cell number, a split's left to right).
//    - slide: straight into the chosen folder, prefixed with the post's title ("Post 1 03-2.jpg");
//    - post / story set: a folder named after it ("Post 1/"); a post also gets post.txt (caption + planned date, status);
//    - plan: one such folder per post / story set, numbered in board order ("01 Post 1/", "02 Stories 1/").
//  Nothing is overwritten: names that exist get " (2)" (folders) or "-1" (files of a slide export).
//
//  Usage (off the main thread):
//      let job = try InstaExportJob(catalog: catalog, scope: .post(id), destination: url)
//      let result = job.run { progress in … }      // blocks; job.cancel() from anywhere
//

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// What to export.
nonisolated enum InstaExportScope: Hashable, Sendable {
    case slide(Int64)
    case post(Int64)
    case plan(Int64)
}

/// One render: a photo framed in a cell, written as one file, or cut into strips (a split).
nonisolated struct InstaExportImage: Hashable, Sendable {
    var photoID: Int64
    var transform: InstaTransform
    /// Pixels of the framed cell (a split: all its strips side by side).
    var renderSize: CGSize
    /// "#RRGGBB", where the photo doesn't cover its cell.
    var background: String
    /// File names without extension, one per strip (left to right).
    var fileNames: [String]

    var strips: Int { fileNames.count }
    /// Pixels of each written file.
    var fileSize: CGSize { CGSize(width: renderSize.width / CGFloat(max(strips, 1)), height: renderSize.height) }
}

/// Files of one post / story set, in a folder of their own (`name` nil = straight into the destination).
nonisolated struct InstaExportFolder: Hashable, Sendable {
    var name: String?
    /// post.txt (posts only).
    var postText: String?
    var images: [InstaExportImage]

    var fileCount: Int { images.reduce(0) { $0 + $1.strips } + (postText == nil ? 0 : 1) }
}

// MARK: - Layout (what gets written where)

nonisolated enum InstaExportLayout {
    /// Output width of every image.
    static let width: CGFloat = 1080

    /// The images of one slide. `number` = its 1-based position on the board, `prefix` goes before each file name.
    static func images(of slide: InstaSlide, number: Int, digits: Int, aspect: InstaAspect, prefix: String = "") -> [InstaExportImage] {
        let base = prefix + padded(number, digits)
        let frame = aspect.pixelSize
        if slide.layout == .single {
            guard let cell = slide.cell(0) else { return [] }
            let span = max(1, slide.span)
            let names = span == 1 ? [base] : (1...span).map { "\(base)-\($0)" }
            return [InstaExportImage(photoID: cell.photoID, transform: cell.transform,
                                     renderSize: CGSize(width: frame.width * CGFloat(span), height: frame.height),
                                     background: slide.background, fileNames: names)]
        }
        let rects = slide.layout.cellRects(in: frame, gap: slide.gap)
        return slide.cells.sorted { $0.index < $1.index }.compactMap { cell in
            guard rects.indices.contains(cell.index) else { return nil }
            return InstaExportImage(photoID: cell.photoID, transform: cell.transform, renderSize: cellSize(rects[cell.index].size),
                                    background: slide.background, fileNames: ["\(base)-\(cell.index + 1)"])
        }
    }

    /// A cell's shape at the output width: 1080 wide, height to keep its aspect (at least 1 px).
    static func cellSize(_ rect: CGSize) -> CGSize {
        guard rect.width > 0 else { return CGSize(width: width, height: width) }
        return CGSize(width: width, height: max(1, (width * rect.height / rect.width).rounded()))
    }

    /// Every image of the post, in board order.
    static func images(of post: InstaPost, prefix: String = "") -> [InstaExportImage] {
        let digits = digitCount(post.slides.count)
        return post.slides.enumerated().flatMap { i, s in images(of: s, number: i + 1, digits: digits, aspect: post.aspect, prefix: prefix) }
    }

    /// The folders a scope writes. `posts` = the plan's posts and story sets in board order.
    static func folders(for scope: InstaExportScope, posts: [InstaPost], locale: Locale = .current,
                        timeZone: TimeZone = .current) -> [InstaExportFolder] {
        func folder(_ post: InstaPost, name: String) -> InstaExportFolder {
            InstaExportFolder(name: name, postText: post.kind == .post ? InstaExportText.post(post, locale: locale, timeZone: timeZone) : nil,
                              images: images(of: post))
        }
        switch scope {
        case .slide(let id):
            guard let post = posts.first(where: { $0.slides.contains { $0.id == id } }),
                  let i = post.slides.firstIndex(where: { $0.id == id }) else { return [] }
            let images = images(of: post.slides[i], number: i + 1, digits: digitCount(post.slides.count), aspect: post.aspect,
                                prefix: fileSafe(post.title, fallback: post.kind.title) + " ")
            return images.isEmpty ? [] : [InstaExportFolder(name: nil, postText: nil, images: images)]
        case .post(let id):
            guard let post = posts.first(where: { $0.id == id }) else { return [] }
            return [folder(post, name: fileSafe(post.title, fallback: post.kind.title))]
        case .plan:
            let digits = digitCount(posts.count)
            return posts.enumerated().compactMap { i, post in
                let f = folder(post, name: padded(i + 1, digits) + " " + fileSafe(post.title, fallback: post.kind.title))
                return f.images.isEmpty && (post.caption.isEmpty || f.postText == nil) ? nil : f   // nothing to post yet
            }
        }
    }

    static func digitCount(_ n: Int) -> Int { max(2, String(max(n, 1)).count) }
    static func padded(_ n: Int, _ digits: Int) -> String {
        let s = String(n)
        return String(repeating: "0", count: max(0, digits - s.count)) + s
    }

    /// A title usable as a file / folder name: no "/" or ":", no leading dot, trimmed, at most 80 characters.
    static func fileSafe(_ title: String, fallback: String) -> String {
        var s = title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .components(separatedBy: .newlines).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        while s.hasPrefix(".") { s.removeFirst() }
        s = String(s.prefix(80)).trimmingCharacters(in: .whitespaces)
        return s.isEmpty ? fallback : s
    }
}

// MARK: - post.txt

nonisolated enum InstaExportText {
    /// The caption exactly as written, then a blank line and the planned date and status:
    ///     Golden hour #trip
    ///
    ///     Planned: 21 Oct 2026 at 18:00
    ///     Status: Ready
    static func post(_ post: InstaPost, locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = locale
        f.timeZone = timeZone
        f.dateStyle = .medium
        f.timeStyle = .short
        var footer: [String] = []
        if let d = post.scheduledAt { footer.append("Planned: " + f.string(from: d)) }
        if post.status == .posted, let d = post.postedAt { footer.append("Status: Posted " + f.string(from: d)) }
        else { footer.append("Status: " + post.status.title) }
        let foot = footer.joined(separator: "\n")
        return post.caption.isEmpty ? foot + "\n" : post.caption + "\n\n" + foot + "\n"
    }
}

// MARK: - Rendering

nonisolated enum InstaExportRenderer {
    /// The developed photo (`image`, any resolution; `imageSize` = its aspect as the board places it) framed in a
    /// cell of `size` pixels by `transform`, on `background`. 8-bit sRGB.
    static func frame(_ image: CGImage, imageSize: CGSize, in size: CGSize, transform: InstaTransform, background: String) -> CGImage? {
        let w = Int(size.width.rounded()), h = Int(size.height.rounded())
        guard w > 0, h > 0,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: RenderPipeline.sRGB,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.setFillColor(color(background))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let p = InstaFraming.placement(imageSize: imageSize, cellSize: CGSize(width: w, height: h), transform: transform)
        // Placement is y-down; the context is y-up (so clockwise is a negative angle).
        ctx.translateBy(x: p.center.x, y: CGFloat(h) - p.center.y)
        ctx.rotate(by: -p.radians)
        ctx.draw(image, in: CGRect(x: -p.size.width / 2, y: -p.size.height / 2, width: p.size.width, height: p.size.height))
        return ctx.makeImage()
    }

    /// `image` cut into `count` equal strips, left to right.
    static func strips(_ image: CGImage, count: Int) -> [CGImage] {
        guard count > 1 else { return [image] }
        let w = image.width / count
        return (0..<count).compactMap { image.cropping(to: CGRect(x: $0 * w, y: 0, width: w, height: image.height)) }
    }

    /// "#RRGGBB" → sRGB; white if malformed.
    static func color(_ hex: String) -> CGColor {
        let h = hex.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "#", with: "")
        guard h.count == 6, let v = UInt32(h, radix: 16) else { return CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1) }
        return CGColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }
}

// MARK: - Job

nonisolated struct InstaExportProgress: Sendable {
    /// Files to write (images + post.txt).
    var total = 0
    var done = 0
}

nonisolated struct InstaExportSkip: Sendable {
    /// The file(s) not written ("03-2.jpg").
    var fileName: String
    var photoName: String
    var reason: ExportSkipReason
}

nonisolated struct InstaExportResult: Sendable {
    /// Every file written, in order.
    var files: [URL] = []
    /// Folders created (post / story set folders).
    var folders: [URL] = []
    var skipped: [InstaExportSkip] = []
    var wasCancelled = false
    var stopError: ExportError?
    var elapsed: TimeInterval = 0

    var imageCount: Int { files.filter { $0.pathExtension == "jpg" }.count }

    /// "12 images exported, 1 skipped (offline)".
    var summary: String {
        let n = imageCount
        var parts = ["\(n) image\(n == 1 ? "" : "s") exported"]
        var counts: [String: Int] = [:]
        var order: [String] = []
        for s in skipped {
            if counts[s.reason.label] == nil { order.append(s.reason.label) }
            counts[s.reason.label, default: 0] += 1
        }
        for label in order { parts.append("\(counts[label]!) skipped (\(label))") }
        return parts.joined(separator: ", ") + (wasCancelled ? " — cancelled" : "")
    }
}

/// One export run. `run` is synchronous — call it off the main thread; `cancel()` from anywhere (files written stay;
/// the image being rendered is dropped, never half-written).
nonisolated final class InstaExportJob: @unchecked Sendable {
    let catalog: Catalog
    let scope: InstaExportScope
    let destination: URL
    let quality: Int
    let folders: [InstaExportFolder]

    private let lock = NSLock()
    private var cancelled = false

    /// Reads the plan from the catalog (the latest framing and captions). `destination` must exist and be writable
    /// (the caller holds its security scope).
    init(catalog: Catalog, scope: InstaExportScope, destination: URL, quality: Int = 92,
         locale: Locale = .current, timeZone: TimeZone = .current) throws {
        self.catalog = catalog
        self.scope = scope
        self.destination = destination
        self.quality = quality
        let planID: Int64?
        switch scope {
        case .plan(let id): planID = id
        case .post(let id): planID = try catalog.instaPosts(planID: nil).first { $0.id == id }?.planID
        case .slide(let id): planID = try catalog.instaPosts(planID: nil).first { $0.slides.contains { $0.id == id } }?.planID
        }
        let posts = try planID.map { try catalog.instaPosts(planID: $0) } ?? []
        folders = InstaExportLayout.folders(for: scope, posts: posts, locale: locale, timeZone: timeZone)
    }

    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

    var fileCount: Int { folders.reduce(0) { $0 + $1.fileCount } }

    func run(progress: @escaping @Sendable (InstaExportProgress) -> Void = { _ in }) -> InstaExportResult {
        let start = Date()
        var result = InstaExportResult()
        var stats = InstaExportProgress(total: fileCount)
        do { try ExportFiles.checkWriteAccess(destination) } catch {
            result.stopError = error as? ExportError ?? .io("\(error)", EIO)
            result.elapsed = Date().timeIntervalSince(start)
            return result
        }
        let photos: [Int64: Photo]
        do {
            let ids = Array(Set(folders.flatMap { $0.images.map(\.photoID) }))
            photos = Dictionary(try catalog.photos(ids: ids).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        } catch {
            result.stopError = .io("Can't read the catalog (\(error))", EIO)
            return result
        }

        func stop(_ error: Error) {
            result.stopError = error as? ExportError ?? .io("\(error)", EIO)
        }

        folderLoop: for folder in folders {
            if isCancelled { break }
            let dir: URL
            if let name = folder.name {
                do { dir = try makeFolder(name) } catch { stop(error); break }
                result.folders.append(dir)
            } else {
                dir = destination
            }
            if let text = folder.postText {
                do {
                    result.files.append(try ExportFiles.write(Data(text.utf8), named: "post.txt", in: dir) { _ in
                        ExportFiles.uniqueFileName(base: "post", ext: "txt", in: dir, reserved: [])
                    })
                } catch { stop(error); break }
                stats.done += 1
                progress(stats)
            }
            for image in folder.images {
                if isCancelled { break folderLoop }
                let photo = photos[image.photoID]
                switch autoreleasepool(invoking: { render(image, photo: photo) }) {
                case .skipped(let reason):
                    for name in image.fileNames {
                        result.skipped.append(InstaExportSkip(fileName: name + ".jpg", photoName: photo?.displayTitle ?? "photo", reason: reason))
                    }
                case .strips(let strips):
                    if isCancelled { break folderLoop }
                    let url = photo.map { SecurityScopeManager.shared.accessibleURL(for: $0, catalog: catalog) }
                    let sidecar = photo?.sidecarURL.map { u in SecurityScope.withAccess(to: u, catalog: catalog) { $0 } }
                    for (strip, name) in zip(strips, image.fileNames) {
                        do {
                            let data = try encode(strip, source: url, sidecar: sidecar)
                            result.files.append(try ExportFiles.write(data, named: name + ".jpg", in: dir) { _ in
                                ExportFiles.uniqueFileName(base: name, in: dir, reserved: [])
                            })
                        } catch let error as ExportError {
                            if case .noWriteAccess = error { stop(error); break folderLoop }
                            result.skipped.append(InstaExportSkip(fileName: name + ".jpg", photoName: photo?.displayTitle ?? "photo",
                                                                  reason: .failed(error.description)))
                        } catch {
                            result.skipped.append(InstaExportSkip(fileName: name + ".jpg", photoName: photo?.displayTitle ?? "photo",
                                                                  reason: .failed("\(error)")))
                        }
                    }
                }
                stats.done += image.strips
                progress(stats)
            }
        }
        result.wasCancelled = isCancelled
        result.elapsed = Date().timeIntervalSince(start)
        return result
    }

    private enum Rendered {
        case strips([CGImage])
        case skipped(ExportSkipReason)
    }

    /// The photo with its edits, framed in its cell and cut into the image's strips.
    private func render(_ image: InstaExportImage, photo: Photo?) -> Rendered {
        guard let photo else { return .skipped(.failed("photo not in the catalog")) }
        let url = SecurityScopeManager.shared.accessibleURL(for: photo, catalog: catalog)
        guard FileManager.default.isReadableFile(atPath: url.path) else { return .skipped(.offline) }
        guard let source = RenderPipeline.makeSource(url: url) else { return .skipped(.unreadable) }
        let settings = photo.editSettings
        let cropped = GeometryMath(sourceSize: source.orientedSize, geometry: settings.geometry).croppedSize
        // Render at the size the photo is drawn at (capped at full resolution by the pipeline).
        let drawn = InstaFraming.placement(imageSize: cropped, cellSize: image.renderSize, transform: image.transform).size
        let target = CGSize(width: max(1, drawn.width.rounded(.up)), height: max(1, drawn.height.rounded(.up)))
        guard let developed = RenderPipeline.renderCGImage(source: source, settings: settings, targetSize: target,
                                                           colorSpace: RenderPipeline.sRGB) else { return .skipped(.failed("render failed")) }
        guard let framed = InstaExportRenderer.frame(developed, imageSize: cropped, in: image.renderSize, transform: image.transform,
                                                     background: image.background) else { return .skipped(.failed("framing failed")) }
        return .strips(InstaExportRenderer.strips(framed, count: image.strips))
    }

    private func encode(_ image: CGImage, source: URL?, sidecar: URL?) throws -> Data {
        var props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: Double(min(max(quality, 0), 100)) / 100,
                                      kCGImagePropertyOrientation: 1]
        if let source {
            props = ExportMetadata.properties(source: source, sidecar: sidecar, pixelWidth: image.width, pixelHeight: image.height,
                                              quality: quality)
        }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw ExportError.io("JPEG encoder unavailable", EIO)
        }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw ExportError.io("JPEG encoding failed", EIO) }
        return data as Data
    }

    /// Creates `name` in the destination ("Post 1", or "Post 1 (2)", … if taken).
    private func makeFolder(_ name: String) throws -> URL {
        for n in 1...1000 {
            let url = destination.appendingPathComponent(n == 1 ? name : "\(name) (\(n))", isDirectory: true)
            if mkdir(url.path, 0o755) == 0 { return url }
            let code = errno
            guard code == EEXIST else {
                throw ExportError.isPermission(code) ? ExportError.noWriteAccess(destination.path)
                    : ExportError.io("Can't create the folder “\(url.lastPathComponent)”", code)
            }
        }
        throw ExportError.io("Can't create the folder “\(name)”", EEXIST)
    }
}
