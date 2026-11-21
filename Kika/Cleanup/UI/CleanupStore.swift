//
//  CleanupStore.swift
//  Kika
//
//  Main-actor state of Clean Up (engine: Cleanup/): the options (remembered), runs (one at a time; queued runs
//  start when it ends — imports queue theirs), the run sheet, and what's up for review:
//    - similar groups with a photo whose Duplicate value is to review,
//    - Blurry / Cropped photos the workflow flagged ("true") without a value of yours,
//    - photos you kept (your "false" over the workflow's "true"), to send back to review.
//  Reloads on tag, flag, edit and photo changes. `AppModel` calls `load(_:)` with the catalog.
//

import Foundation
import Observation

@Observable
final class CleanupStore {
    static let shared = CleanupStore()

    // MARK: Options (UserDefaults)

    var options: CleanupOptions = CleanupStore.loadOptions() {
        didSet { if let data = try? JSONEncoder().encode(options) { UserDefaults.standard.set(data, forKey: "cleanup.options") } }
    }
    /// Run the checks on every import (on the imported photos).
    var runOnImport = UserDefaults.standard.bool(forKey: "cleanup.onImport") {
        didSet { UserDefaults.standard.set(runOnImport, forKey: "cleanup.onImport") }
    }

    private static func loadOptions() -> CleanupOptions {
        guard let data = UserDefaults.standard.data(forKey: "cleanup.options"),
              let o = try? JSONDecoder().decode(CleanupOptions.self, from: data) else { return CleanupOptions() }
        return o
    }

    // MARK: Runs

    nonisolated struct Run: Identifiable {
        let id = UUID()
        /// "All Photographs", "Folder “Trip”", "Imported photos".
        var title: String
        var photoIDs: [Int64]
        var options: CleanupOptions
    }

    /// The run in progress.
    private(set) var current: Run?
    private(set) var progress = CleanupJob.Progress()
    /// Runs waiting for the current one.
    private(set) var queue: [Run] = []
    /// The last finished run and what it found.
    private(set) var lastResult: (title: String, summary: CleanupJob.Summary, finishedAt: Date)?
    @ObservationIgnored private var job: CleanupJob?

    var isRunning: Bool { current != nil }

    /// The run sheet: the folders to preselect (empty = All Photographs).
    var sheet: RunSheetRequest?
    nonisolated struct RunSheetRequest: Identifiable {
        let id = UUID()
        var folderIDs: Set<Int64>
    }

    func presentRunSheet(folderIDs: Set<Int64> = []) { sheet = RunSheetRequest(folderIDs: folderIDs) }

    // MARK: Review

    nonisolated struct ReviewGroup: Identifiable {
        var group: CleanupGroup
        var photos: [Photo]
        var id: Int64 { group.id }
    }

    private(set) var groups: [ReviewGroup] = []
    private(set) var flagged: [CleanupCheck: [Photo]] = [:]
    private(set) var kept: [CleanupCheck: [Photo]] = [:]
    private(set) var tagIDs: [CleanupCheck: Int64] = [:]
    /// What the analyser measured, for the photos shown.
    private(set) var details: [Int64: CleanupAnalysis] = [:]
    /// Photos analysed so far (whole catalog).
    private(set) var analysedCount = 0

    /// Groups + flagged photos waiting for you (sidebar badge).
    var reviewCount: Int { groups.count + (flagged[.blurry]?.count ?? 0) + (flagged[.cropped]?.count ?? 0) }

    @ObservationIgnored private var catalog: Catalog?
    @ObservationIgnored private var observer: NSObjectProtocol?
    @ObservationIgnored private var reloadScheduled = false

    private init() {}

    func load(_ catalog: Catalog) {
        job?.cancel()
        queue = []
        self.catalog = catalog
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = NotificationCenter.default.addObserver(forName: Catalog.didChange, object: catalog, queue: .main) { note in
            guard let change = Catalog.change(from: note) else { return }
            switch change {
            case .photoTags, .photosUpdated, .photosInsertedOrRemoved, .tags:
                MainActor.assumeIsolated { CleanupStore.shared.scheduleReload() }
            default:
                break
            }
        }
        reload()
    }

    func scheduleReload() {
        guard !reloadScheduled else { return }
        reloadScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [self] in
            reloadScheduled = false
            reload()
        }
    }

    func reload() {
        guard let catalog else { return }
        do {
            tagIDs = try catalog.existingCleanupTagIDs()
            analysedCount = try catalog.cleanupAnalysedCount()
            var flagged: [CleanupCheck: [Photo]] = [:], kept: [CleanupCheck: [Photo]] = [:]
            let sort = PhotoSort(key: .captureDate, ascending: true)
            for (check, tag) in tagIDs {
                let review = PhotoFilter(tags: [TagCondition(tagID: tag, match: .toReview(CleanupTags.yes))])
                flagged[check] = try catalog.photos(in: .all, filter: review, sort: sort).filter { $0.masterID == nil }
                kept[check] = try catalog.photos(ids: catalog.cleanupKeptPhotoIDs(tagID: tag))
            }
            // A group is up for review while one of its photos has a Duplicate value to review.
            let pending = Set(flagged[.similar]?.map(\.id) ?? [])
            let stored = try catalog.cleanupGroups().filter { $0.photoIDs.contains(where: pending.contains) }
            let photos = Dictionary(try catalog.photos(ids: stored.flatMap(\.photoIDs)).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            groups = stored.map { g in ReviewGroup(group: g, photos: g.photoIDs.compactMap { photos[$0] }) }.filter { $0.photos.count >= 2 }
            self.flagged = flagged
            self.kept = kept
            let shown = groups.flatMap { $0.photos.map(\.id) } + flagged.values.flatMap { $0.map(\.id) } + kept.values.flatMap { $0.map(\.id) }
            details = try catalog.cleanupAnalyses(photoIDs: Array(Set(shown))).mapValues(\.analysis)
        } catch {
            print("Clean Up: \(error)")
        }
    }

    // MARK: Running

    /// Queues a run (starts at once when idle).
    func run(title: String, photoIDs: [Int64], options: CleanupOptions? = nil) {
        guard !photoIDs.isEmpty else { return }
        queue.append(Run(title: title, photoIDs: photoIDs, options: options ?? self.options))
        startNext()
    }

    /// Runs the checks on photos that were just imported (if turned on).
    func importFinished(photoIDs: [Int64]) {
        guard runOnImport else { return }
        run(title: "Imported photos", photoIDs: photoIDs)
    }

    func cancel() {
        queue = []
        job?.cancel()
    }

    private func startNext() {
        guard current == nil, let catalog, !queue.isEmpty else { return }
        let run = queue.removeFirst()
        let job = CleanupJob()
        self.job = job
        current = run
        progress = CleanupJob.Progress(total: run.photoIDs.count)
        Task.detached(priority: .utility) {
            var last = Date.distantPast
            let result = Result {
                try job.run(photoIDs: run.photoIDs, options: run.options, catalog: catalog, progress: { p in
                    let now = Date()
                    guard now.timeIntervalSince(last) > 0.1 || p.done == p.total else { return }
                    last = now
                    Task { @MainActor in if CleanupStore.shared.current?.id == run.id { CleanupStore.shared.progress = p } }
                })
            }
            await MainActor.run { CleanupStore.shared.finish(run, result) }
        }
    }

    private func finish(_ run: Run, _ result: Result<CleanupJob.Summary, Error>) {
        guard current?.id == run.id else { return }
        current = nil
        job = nil
        switch result {
        case .success(let summary): lastResult = (run.title, summary, Date())
        case .failure(let error): print("Clean Up failed: \(error)")
        }
        reload()
        startNext()
    }

    /// "Analysing 12 of 340…" / "Saving results…".
    var progressText: String {
        guard let current else { return "" }
        if progress.total == 0 || (progress.done == progress.total && progress.currentFile == nil) {
            return "\(current.title): saving results…"
        }
        return "\(current.title): analysing \(progress.done.formatted()) of \(progress.total.formatted())…"
    }

    /// One line about the last run ("Found 4 groups of similar shots, 3 blurry, 1 cropped in 340 photos").
    var lastResultText: String? {
        guard let r = lastResult else { return nil }
        let s = r.summary
        if s.cancelled { return "\(r.title): stopped." }
        var parts: [String] = []
        if let g = s.flagged[.similar] { parts.append("\(s.groups) group\(s.groups == 1 ? "" : "s") of similar shots (\(g) extra)") }
        if let b = s.flagged[.blurry] { parts.append("\(b) blurry") }
        if let c = s.flagged[.cropped] { parts.append("\(c) cropped") }
        var text = "\(r.title): \(parts.isEmpty ? "nothing checked" : parts.joined(separator: ", ")) in \(s.photos.formatted()) photo\(s.photos == 1 ? "" : "s")."
        if s.unreadable > 0 { text += " \(s.unreadable) couldn't be read (offline?)." }
        return text
    }
}
