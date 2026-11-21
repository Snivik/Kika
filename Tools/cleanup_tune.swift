//
//  cleanup_tune.swift
//  Clean Up tuning (local; needs sample photos): runs CleanupAnalyzer on every JPEG / RAW of the given folders
//  (READ-ONLY) and writes <out>/index.html: a contact sheet sorted by sharpness with crop reasons and the
//  similar groups, plus <out>/scores.csv. For eyeballing thresholds, not a pass / fail check.
//
//  Build & run:
//    Tools/harness.sh /private/tmp/claude-501/cleanup-tune/tune Tools/cleanup_tune.swift Kika/Cleanup/CleanupModels.swift Kika/Cleanup/CleanupAnalyzer.swift
//    /private/tmp/claude-501/cleanup-tune/tune <out-dir> <folder> [folder…]
//

import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

@main
struct CleanupTune {
    static func main() async throws {
        let args = CommandLine.arguments
        guard args.count >= 3 else { print("usage: tune <out-dir> <folder>…"); exit(2) }
        let out = URL(fileURLWithPath: args[1])
        let thumbs = out.appendingPathComponent("t")
        try FileManager.default.createDirectory(at: thumbs, withIntermediateDirectories: true)

        var files: [URL] = []
        for dir in args.dropFirst(2) {
            let all = (try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: dir), includingPropertiesForKeys: nil)) ?? []
            let names = Set(all.map { $0.deletingPathExtension().lastPathComponent + "." + $0.pathExtension.lowercased() })
            for f in all.sorted(by: { $0.path < $1.path }) {
                let ext = f.pathExtension.lowercased()
                // RAW+JPEG pairs: the RAW (as Кика catalogues it).
                if ["jpg", "jpeg", "heic"].contains(ext) {
                    let base = f.deletingPathExtension().lastPathComponent
                    if ["dng", "rw2", "arw", "cr3", "nef", "raf"].contains(where: { names.contains(base + "." + $0) }) { continue }
                    files.append(f)
                } else if ["dng", "rw2", "arw", "cr3", "nef", "raf"].contains(ext) {
                    files.append(f)
                }
            }
        }
        print("\(files.count) photos")

        struct Row { var url: URL; var date: Date; var r: CleanupAnalyzer.Result; var ms: Double; var thumb: String }
        var rows: [Row] = []
        let synth = ProcessInfo.processInfo.environment["CLEANUP_SYNTH"] != nil
        let ctx = CIContext()
        let start = Date()
        for (i, url) in files.enumerated() {
            guard let meta = PhotoMetadataReader.read(url: url) else { continue }
            var photo = Photo(path: url.path)
            photo.width = meta.pixelWidth; photo.height = meta.pixelHeight
            let t0 = Date()
            guard let image = CleanupAnalyzer.image(for: photo, url: url) else { print("  can't read \(url.lastPathComponent)"); continue }
            let r = CleanupAnalyzer.analyze(image)
            if synth {
                // Blur the real photo (Gaussian σ px at analysis size, and a horizontal shake) and re-measure.
                var line = String(format: "SYNTH %@ orig %.2f", url.lastPathComponent, r.analysis.sharpness)
                for (name, filter, params) in [("g1", "CIGaussianBlur", [kCIInputRadiusKey: 1.0]), ("g2", "CIGaussianBlur", [kCIInputRadiusKey: 2.0]),
                                               ("g3", "CIGaussianBlur", [kCIInputRadiusKey: 3.0]), ("m6", "CIMotionBlur", [kCIInputRadiusKey: 6.0])] as [(String, String, [String: Any])] {
                    let ci = CIImage(cgImage: image).clampedToExtent().applyingFilter(filter, parameters: params).cropped(to: CGRect(x: 0, y: 0, width: image.width, height: image.height))
                    guard let blurred = ctx.createCGImage(ci, from: ci.extent) else { continue }
                    line += String(format: " %@ %.2f", name, CleanupAnalyzer.analyze(blurred).analysis.sharpness)
                }
                print(line)
            }
            let ms = Date().timeIntervalSince(t0) * 1000
            let name = "\(i).jpg"
            writeThumb(image, to: thumbs.appendingPathComponent(name))
            rows.append(Row(url: url, date: meta.captureDate ?? .distantPast, r: r, ms: ms, thumb: name))
            if i % 20 == 0 { print(String(format: "  %d/%d  %.0f ms  %@", i, files.count, ms, url.lastPathComponent)) }
        }
        print(String(format: "analysed %d in %.1f s (%.0f ms each)", rows.count, Date().timeIntervalSince(start),
                     Date().timeIntervalSince(start) * 1000 / Double(max(1, rows.count))))

        let options = CleanupOptions()
        let items = rows.enumerated().map { i, row in
            CleanupGroupingItem(id: Int64(i), date: row.date, fileName: row.url.lastPathComponent, feature: row.r.analysis.feature,
                                quality: row.r.analysis.quality, sharpness: row.r.analysis.sharpness)
        }
        var html = "<html><head><meta charset=utf-8><style>body{font:12px -apple-system;background:#222;color:#ddd}"
            + "div.c{display:inline-block;width:220px;margin:4px;vertical-align:top}img{max-width:220px;max-height:160px}"
            + ".blur{outline:3px solid orange}.crop{outline:3px solid yellow}h2{clear:both}</style></head><body>"
        // Neighbour distances (to tune the similar threshold).
        let sortedIdx = items.indices.sorted { (items[$0].date, items[$0].fileName) < (items[$1].date, items[$1].fileName) }
        var neighbour: [Int: (Float, Double)] = [:]
        for k in 1..<max(1, sortedIdx.count) {
            let a = items[sortedIdx[k - 1]], b = items[sortedIdx[k]]
            neighbour[sortedIdx[k]] = (CleanupGrouping.distance(a.feature, b.feature), b.date.timeIntervalSince(a.date))
        }
        for sens in CleanupSensitivity.allCases {
            var o = options; o.similarSensitivity = sens
            let g = CleanupGrouping.groups(items, maxDistance: o.similarDistance, maxGap: o.maxGapSeconds)
            print("similar \(sens.rawValue): \(g.count) groups, \(g.map(\.photoIDs.count).reduce(0, +)) photos")
        }
        let groups = CleanupGrouping.groups(items, maxDistance: options.similarDistance, maxGap: options.maxGapSeconds)
        html += "<h2>Similar groups (medium): \(groups.count)</h2>"
        for g in groups {
            html += "<div>"
            for id in g.photoIDs {
                let row = rows[Int(id)]
                let d = neighbour[Int(id)].map { String(format: "d %.2f, %.0fs", $0.0, $0.1) } ?? ""
                html += "<div class=c><img src='t/\(row.thumb)' style='\(id == g.bestID ? "outline:3px solid #4c4" : "")'><br>\(row.url.lastPathComponent) \(d)"
                    + String(format: " q %.2f s %.2f", row.r.analysis.quality, row.r.analysis.sharpness) + "</div>"
            }
            html += "</div><hr>"
        }

        html += "<h2>By sharpness (orange = blurry at medium \(options.blurThreshold); yellow = cropped at \(options.cropThreshold))</h2>"
        var csv = "file,sharpness,subjectRMS,frameRMS,source,faces,crop,reason,quality,ms\n"
        for row in rows.sorted(by: { $0.r.analysis.sharpness < $1.r.analysis.sharpness }) {
            let a = row.r.analysis
            let cls = a.sharpness < options.blurThreshold ? "blur" : (a.cropScore >= options.cropThreshold ? "crop" : "")
            html += "<div class=c><img class='\(cls)' src='t/\(row.thumb)'><br>\(row.url.lastPathComponent)<br>"
                + String(format: "sharp %.2f (subj %.1f / frame %.1f, %@ %d)<br>crop %.2f %@<br>q %.2f",
                         a.sharpness, row.r.subjectRMS, row.r.frameRMS, row.r.subjectSource, row.r.faces, a.cropScore, a.cropReason ?? "", a.quality)
                + "</div>"
            csv += "\(row.url.lastPathComponent),\(a.sharpness),\(row.r.subjectRMS),\(row.r.frameRMS),\(row.r.subjectSource),\(row.r.faces),"
                + "\(a.cropScore),\"\(a.cropReason ?? "")\",\(a.quality),\(Int(row.ms))\n"
        }
        html += "</body></html>"
        try html.write(to: out.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        try csv.write(to: out.appendingPathComponent("scores.csv"), atomically: true, encoding: .utf8)
        print("wrote \(out.path)/index.html")
    }

    static func writeThumb(_ image: CGImage, to url: URL) {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return }
        let src = CGImageSourceCreateWithData(jpeg(image) as CFData, nil)
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 440]
        if let src, let t = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) {
            CGImageDestinationAddImage(dest, t, [kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary)
            CGImageDestinationFinalize(dest)
        }
    }

    static func jpeg(_ image: CGImage) -> Data {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return Data() }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
        return data as Data
    }
}
