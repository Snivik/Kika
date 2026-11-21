//
//  CleanupJob.swift
//  Kika
//
//  One Clean Up run over a set of photos (synchronous; call off-main, `cancel()` from anywhere):
//    1. masters only (a virtual copy is a deliberate duplicate of its master's file);
//    2. analyse every photo without a current analysis (CleanupAnalyzer.version + its edit version), three at a
//       time, each saved as soon as it's done (a cancelled run keeps what it measured);
//    3. per enabled check, write the workflow's verdicts as tag values (Catalog.applyCleanupVerdicts) and, for
//       Similar, replace the stored groups of these photos. Photos you already decided keep your value; picked
//       photos are never flagged (a pick already says "keep").
//  Offline / unreadable photos are skipped and counted. Engine code.
//

import CoreGraphics
import Foundation

nonisolated final class CleanupJob: @unchecked Sendable {
    nonisolated struct Progress: Sendable, Equatable {
        var done = 0
        var total = 0
        /// The photo being analysed (nil while writing results).
        var currentFile: String?
    }

    nonisolated struct Summary: Sendable, Equatable {
        var photos = 0
        var analysed = 0
        /// Analyses reused from an earlier run.
        var reused = 0
        var unreadable = 0
        var skippedVirtualCopies = 0
        /// Photos flagged per check (including ones you already decided on).
        var flagged: [CleanupCheck: Int] = [:]
        var groups = 0
        var cancelled = false
    }

    private let lock = NSLock()
    private var cancelled = false
    /// Parallel analyses (Vision shares the Neural Engine / GPU; more doesn't go faster).
    var workers = 3

    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

    /// `loadImage` is the seam for harnesses (default: the photo's file through its security scope).
    func run(photoIDs: [Int64], options: CleanupOptions, catalog: Catalog,
             loadImage: ((Photo) -> CGImage?)? = nil,
             progress: @escaping (Progress) -> Void = { _ in }) throws -> Summary {
        var summary = Summary()
        let all = try catalog.photos(ids: photoIDs)
        let photos = all.filter { $0.masterID == nil }
        summary.skippedVirtualCopies = all.count - photos.count
        summary.photos = photos.count
        guard !photos.isEmpty else { return summary }

        // 1. What needs measuring.
        var analyses = try catalog.cleanupAnalyses(photoIDs: photos.map(\.id))
        let todo = photos.filter { p in
            guard let a = analyses[p.id] else { return true }
            return a.version != CleanupAnalyzer.version || a.editVersion != p.editVersion
        }
        summary.reused = photos.count - todo.count
        var p = Progress(done: 0, total: todo.count)
        progress(p)

        // 2. Analyse (workers pull the next photo).
        let load = loadImage ?? { photo in
            let url = SecurityScopeManager.shared.accessibleURL(for: photo, catalog: catalog)
            return CleanupAnalyzer.image(for: photo, url: url)
        }
        var next = 0
        var unreadable = 0
        let state = NSLock()
        DispatchQueue.concurrentPerform(iterations: max(1, min(workers, todo.count))) { _ in
            while true {
                state.lock()
                guard next < todo.count, !isCancelled else { state.unlock(); return }
                let photo = todo[next]
                next += 1
                state.unlock()
                autoreleasepool {
                    let result = load(photo).map { CleanupAnalyzer.analyze($0).analysis }
                    state.lock()
                    if let result {
                        analyses[photo.id] = Catalog.StoredCleanupAnalysis(version: CleanupAnalyzer.version,
                                                                           editVersion: photo.editVersion, analysis: result)
                    } else {
                        unreadable += 1
                    }
                    p.done += 1
                    p.currentFile = photo.fileName
                    let snapshot = p
                    state.unlock()
                    if let result { try? catalog.saveCleanupAnalysis(result, photoID: photo.id, editVersion: photo.editVersion) }
                    progress(snapshot)
                }
            }
        }
        summary.unreadable = unreadable
        summary.analysed = todo.count - unreadable
        if isCancelled { summary.cancelled = true; return summary }
        p.currentFile = nil
        progress(p)

        // 3. Verdicts. Unreadable photos keep whatever they had.
        let measured = photos.filter { analyses[$0.id] != nil }
        let ids = measured.map(\.id)
        let tags = try catalog.cleanupTagIDs()
        let unpicked = measured.filter { $0.flag != .pick }
        if options.checks.contains(.blurry), let tag = tags[.blurry] {
            let flagged = Set(unpicked.filter { analyses[$0.id]!.analysis.sharpness < options.blurThreshold }.map(\.id))
            try catalog.applyCleanupVerdicts(tagID: tag, photoIDs: ids, flagged: flagged)
            summary.flagged[.blurry] = flagged.count
        }
        if options.checks.contains(.cropped), let tag = tags[.cropped] {
            let flagged = Set(unpicked.filter { analyses[$0.id]!.analysis.cropScore >= options.cropThreshold }.map(\.id))
            try catalog.applyCleanupVerdicts(tagID: tag, photoIDs: ids, flagged: flagged)
            summary.flagged[.cropped] = flagged.count
        }
        if options.checks.contains(.similar), let tag = tags[.similar] {
            let mine = try catalog.userTagValues(tagID: tag, photoIDs: ids)
            let items = measured.map { photo in
                let a = analyses[photo.id]!.analysis
                return CleanupGroupingItem(id: photo.id, date: photo.captureDate ?? photo.importDate, fileName: photo.fileName,
                                           feature: a.feature, flag: photo.flag, rating: photo.rating,
                                           kept: mine[photo.id] == CleanupTags.no, quality: a.quality, sharpness: a.sharpness)
            }
            let groups = CleanupGrouping.groups(items, maxDistance: options.similarDistance, maxGap: options.maxGapSeconds)
            try catalog.replaceCleanupGroups(groups, scope: ids)
            // Everything but each group's keeper is a duplicate.
            let picked = Set(measured.filter { $0.flag == .pick }.map(\.id))
            let flagged = Set(groups.flatMap { g in g.photoIDs.filter { $0 != g.bestID && !picked.contains($0) } })
            try catalog.applyCleanupVerdicts(tagID: tag, photoIDs: ids, flagged: flagged)
            summary.flagged[.similar] = flagged.count
            summary.groups = groups.count
        }
        return summary
    }
}
