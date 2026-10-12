//
//  ImportSession.swift
//  sloproom
//
//  State of the Import Photos sheet (MainActor): source selection + sandbox grants, progressive
//  scan (file list first, then metadata / duplicate matches in chunks), check state, options,
//  destination + its preview (`ImportDestinationPlan`), the conflict prompt (Rename / Replace /
//  Skip), the running import and its recap (`ImportRecap`). Engine work lives in ImportEngine.swift.
//

import AppKit
import Foundation
import Observation

/// Photos of one capture day in the grid.
struct ImportSection: Identifiable {
    var id: String
    var title: String
    var items: [ImportCandidate]
}

/// Duplicate detection state of one candidate (the grid's status icon).
enum ImportMatchState {
    /// Not compared yet (metadata not read, or the destination is still being looked at).
    case processing
    /// Already in the catalog, or an identical file is already in its destination folder.
    case matched
    /// New.
    case unmatched
}

/// Photos that would collide with what is already there; the user picks Rename / Replace / Skip.
struct ImportConflictPrompt {
    /// Candidates whose target file name is taken in the destination.
    var fileConflicts: Int
    /// Candidates that match a catalog photo (included although detected as duplicates).
    var catalogDuplicates: Int
    /// Conflicting candidates (both kinds).
    var count: Int
    var examples: [String]
}

/// Recap shown when an import ends (also when nothing was imported).
struct ImportRecap {
    var result: ImportResult
    var mode: ImportMode
    var policy: ImportConflictPolicy?
    var sourceTitle: String
    var destinationPath: String?
    var folderName: String?
    /// Photos found in the source (after RAW + JPEG pairing).
    var found: Int
    /// Locked duplicates ("Don't import suspected duplicates").
    var skippedDuplicates: [String]
    /// Locked because an identical file is already in the destination (not in the catalog: adopted).
    var inDestination: [String]
    var unchecked: Int
    var unreadable: [String]
    /// Files that aren't photos (videos…) by extension.
    var ignored: [String: Int]

    var replaced: Int { result.replacedPhotoIDs.count }
    var added: Int { result.photoIDs.count - replaced - result.adoptedExisting.count }
    var succeeded: Bool { !result.photoIDs.isEmpty }
}

@Observable
final class ImportSession {
    let catalog: Catalog

    // MARK: Source
    private(set) var volumes: [ImportVolume] = []
    private(set) var recentFolder: RecentImportFolder? = ImportSources.recentFolder
    private(set) var sourceURL: URL?
    private(set) var sourceTitle = ""
    /// Volume id or recent-folder key of the selected source (for highlighting).
    private(set) var sourceID: String?

    // MARK: Scan
    private(set) var isScanning = false
    private(set) var scanStatus = ""
    private(set) var files: [ImportFile] = []
    /// Files in the source that aren't photos (videos…), by extension.
    private(set) var ignoredFiles: [String: Int] = [:]
    private(set) var metadata: [String: PhotoMetadata] = [:]
    /// Primary file ids already in the catalog.
    private(set) var duplicates: Set<String> = []
    /// Primary file id → the catalog photo it duplicates.
    private(set) var duplicateMatches: [String: Int64] = [:]
    /// Primary file ids compared with the catalog (metadata read, or unreadable).
    private(set) var checkedIDs: Set<String> = []
    private(set) var unreadable: Set<String> = []
    private(set) var candidates: [ImportCandidate] = []
    private(set) var sections: [ImportSection] = []
    /// Everything is checked unless the user unchecked it (new candidates start checked).
    var unchecked: Set<String> = [] { didSet { schedulePlan() } }

    // MARK: Options (remembered)
    var mode: ImportMode = ImportMode(rawValue: UserDefaults.standard.string(forKey: "import.mode") ?? "") ?? .copy {
        didSet {
            UserDefaults.standard.set(mode.rawValue, forKey: "import.mode")
            schedulePlan(destinationChanged: true)
        }
    }
    var pattern: DestinationPattern = DestinationPattern(rawValue: UserDefaults.standard.string(forKey: "import.pattern") ?? "") ?? .yearAndDay {
        didSet {
            UserDefaults.standard.set(pattern.rawValue, forKey: "import.pattern")
            schedulePlan(destinationChanged: true)
        }
    }
    var pairSidecars: Bool = UserDefaults.standard.object(forKey: "import.pairSidecars") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(pairSidecars, forKey: "import.pairSidecars")
            rebuildCandidates()
        }
    }
    var skipDuplicates: Bool = UserDefaults.standard.object(forKey: "import.skipDuplicates") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(skipDuplicates, forKey: "import.skipDuplicates")
            schedulePlan()
        }
    }
    private(set) var destination: Root?
    /// Why the destination can't be used (missing, no write access), nil = fine / unchecked.
    private(set) var destinationProblem: String?
    var targetFolderID: Int64?
    var newFolderName = ""
    /// Where the included photos land (copy mode), compared with the destination on disk.
    private(set) var destinationPlan: ImportDestinationPlan?
    private(set) var isPlanning = false
    /// Candidates with an identical file (name + size) already in their destination folder.
    private(set) var destinationIdentical: Set<String> = []

    // MARK: Import
    private(set) var isImporting = false
    /// Checking for conflicts before an import starts.
    private(set) var isPreparing = false
    private(set) var progress = ImportProgress()
    var errorMessage: String?
    /// Set when the import would collide with existing photos; the sheet asks Rename / Replace / Skip.
    var conflictPrompt: ImportConflictPrompt?
    /// The recap of the last import; the sheet shows it instead of the grid.
    var recap: ImportRecap?

    private var job: ImportJob?
    private var scanTask: Task<Void, Never>?
    private var scanGeneration = 0
    private var planTask: Task<Void, Never>?

    init(catalog: Catalog) {
        self.catalog = catalog
        // Remembered by path (root ids differ between catalogs).
        if let path = UserDefaults.standard.string(forKey: "import.destinationPath"),
           let root = (try? catalog.allRoots())?.first(where: { $0.path == path }) {
            setDestination(root)
        }
    }

    // MARK: - Derived

    func isIncluded(_ c: ImportCandidate) -> Bool {
        !unchecked.contains(c.id) && !isLocked(c)
    }
    /// Already in the catalog, or an identical file is already in its destination folder.
    func isDuplicate(_ c: ImportCandidate) -> Bool { duplicates.contains(c.id) || isInDestination(c) }
    func isInDestination(_ c: ImportCandidate) -> Bool { mode == .copy && destinationIdentical.contains(c.id) }
    func isLocked(_ c: ImportCandidate) -> Bool { skipDuplicates && isDuplicate(c) }
    var included: [ImportCandidate] { candidates.filter(isIncluded) }

    /// Still comparing with the destination folders (copy mode, destination chosen).
    private var isMatchingDestination: Bool {
        mode == .copy && destination != nil && destinationProblem == nil
    }

    func matchState(_ c: ImportCandidate) -> ImportMatchState {
        guard checkedIDs.contains(c.id) else { return .processing }
        if duplicates.contains(c.id) { return .matched }
        if isMatchingDestination, destinationPlan?.plannedIDs.contains(c.id) != true { return .processing }
        return isInDestination(c) ? .matched : .unmatched
    }

    /// The included photo's target file already exists in the destination (copy mode).
    func existsInDestination(_ c: ImportCandidate) -> Bool {
        mode == .copy && destinationPlan?.conflictIDs.contains(c.id) == true
    }

    /// Still comparing photos with the catalog / destination (Import waits, so no duplicate slips in).
    var isMatching: Bool {
        isScanning || (isMatchingDestination && candidates.contains { matchState($0) == .processing })
    }

    var canImport: Bool {
        guard !isImporting, !isPreparing, !isMatching, sourceURL != nil, !candidates.isEmpty,
              candidates.contains(where: isIncluded) else { return false }
        return mode == .addInPlace || (destination != nil && destinationProblem == nil)
    }

    // MARK: - Sources

    func refreshVolumes() {
        volumes = ImportSources.volumes()
        if let id = sourceID, sourceURL != nil, id.hasPrefix("/"), !volumes.contains(where: { $0.id == id }) {
            clearSource() // the selected card was ejected
        }
    }

    /// On open: jump straight into a card we already have access to.
    func autoSelectCard() {
        guard sourceURL == nil, !isImporting,
              let card = volumes.first(where: { $0.hasDCIM && ImportSources.grantedURL(forKey: $0.bookmarkKey) != nil }) else { return }
        open(volume: card)
    }

    func open(volume: ImportVolume) {
        if let url = ImportSources.grantedURL(forKey: volume.bookmarkKey) {
            scan(url, title: volume.name, id: volume.id)
            return
        }
        // Sandbox: the user must grant access once; point the panel at the card.
        guard let url = runOpenPanel(at: volume.url, prompt: "Allow Access",
                                     message: "Select “\(volume.name)” and click Allow Access so Sloproom can read the card. You only need to do this once per card.") else { return }
        ImportSources.remember(url, key: volume.bookmarkKey)
        scan(url, title: volume.name, id: volume.id)
    }

    func openRecentFolder() {
        guard let recent = recentFolder else { return }
        if let url = ImportSources.grantedURL(forKey: recent.key) {
            scan(url, title: recent.name, id: recent.key)
        } else {
            chooseFolder(startingAt: URL(fileURLWithPath: recent.path))
        }
    }

    func chooseFolder(startingAt start: URL? = nil) {
        guard let url = runOpenPanel(at: start ?? sourceURL, prompt: "Choose",
                                     message: "Choose a folder or card to import photos from.") else { return }
        let key = ImportSources.key(forPickedFolder: url)
        ImportSources.remember(url, key: key)
        let recent = RecentImportFolder(name: url.lastPathComponent, path: url.path, key: key)
        ImportSources.recentFolder = recent
        recentFolder = recent
        let volume = volumes.first { ImportSources.key(forPickedFolder: $0.url) == key || $0.bookmarkKey == key }
        scan(url, title: volume?.name ?? url.lastPathComponent, id: volume?.id ?? key)
    }

    /// Scans a folder the app can already read (no panel). Used by DevScript / container paths.
    func open(folder url: URL) {
        scan(url, title: url.lastPathComponent, id: "folder:" + url.path)
    }

    /// Uses a folder the app can already write to as destination (no panel). DevScript.
    func setDestination(folder url: URL) throws {
        setDestination(try SecurityScopeManager.shared.registerRoot(url: url, in: catalog))
    }

    private func runOpenPanel(at directory: URL?, prompt: String, message: String) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = prompt
        panel.message = message
        panel.directoryURL = directory
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func clearSource() {
        cancelScan()
        sourceURL = nil
        sourceID = nil
        sourceTitle = ""
        files = []; ignoredFiles = [:]; metadata = [:]; duplicates = []; duplicateMatches = [:]; checkedIDs = []
        unreadable = []; unchecked = []
        rebuildCandidates()
    }

    // MARK: - Scan

    func rescan() {
        guard let url = sourceURL, let id = sourceID else { return }
        scan(url, title: sourceTitle, id: id)
    }

    func cancelScan() {
        scanTask?.cancel()
        scanTask = nil
        scanGeneration += 1
        isScanning = false
    }

    private func scan(_ url: URL, title: String, id: String) {
        cancelScan()
        let generation = scanGeneration
        sourceURL = url
        sourceTitle = title
        sourceID = id
        files = []; ignoredFiles = [:]; metadata = [:]; duplicates = []; duplicateMatches = [:]; checkedIDs = []
        unreadable = []; unchecked = []
        errorMessage = nil
        rebuildCandidates()
        isScanning = true
        scanStatus = "Looking for photos…"

        let catalog = catalog
        scanTask = Task.detached(priority: .userInitiated) { [self] in
            let index = (try? DuplicateIndex(catalog: catalog)) ?? DuplicateIndex()
            let (found, ignored) = ImportScanner.scan(url, isCancelled: { Task.isCancelled }) { count in
                Task { @MainActor in self.update(generation) { $0.scanStatus = "Found \(count) photos…" } }
            }
            if Task.isCancelled { return }
            await MainActor.run { self.update(generation) { $0.files = found; $0.ignoredFiles = ignored; $0.rebuildCandidates() } }

            // Metadata + duplicate flags in chunks, so the grid fills in progressively.
            let chunkSize = 48
            for start in stride(from: 0, to: found.count, by: chunkSize) {
                if Task.isCancelled { return }
                let chunk = Array(found[start..<min(start + chunkSize, found.count)])
                let meta = ImportScanner.readMetadata(chunk)
                var matches: [String: Int64] = [:]
                for f in chunk { if let id = index.match(f, metadata: meta[f.id]) { matches[f.id] = id } }
                let bad = Set(chunk.map(\.id)).subtracting(meta.keys)
                let done = start + chunk.count
                await MainActor.run {
                    self.update(generation) { s in
                        s.metadata.merge(meta) { $1 }
                        s.duplicateMatches.merge(matches) { $1 }
                        s.duplicates.formUnion(matches.keys)
                        s.checkedIDs.formUnion(chunk.map(\.id))
                        s.unreadable.formUnion(bad)
                        s.scanStatus = "Reading \(done) of \(found.count)…"
                        s.rebuildCandidates()
                    }
                }
            }
            await MainActor.run { self.update(generation) { $0.isScanning = false; $0.scanStatus = "" } }
        }
    }

    /// Applies a scan result only if it belongs to the current scan.
    private func update(_ generation: Int, _ body: (ImportSession) -> Void) {
        guard generation == scanGeneration else { return }
        body(self)
    }

    private func rebuildCandidates() {
        let usable = unreadable.isEmpty ? files : files.filter { !unreadable.contains($0.id) }
        let cands = ImportScanner.candidates(from: usable, pairSidecars: pairSidecars)
        let cal = Calendar.current
        let dayFormat = Date.FormatStyle(date: .complete, time: .omitted)
        var byDay: [Date: [ImportCandidate]] = [:]
        var undated: [ImportCandidate] = []
        for c in cands {
            if let d = ImportScanner.date(of: c.primary, metadata: metadata[c.id]) {
                byDay[cal.startOfDay(for: d), default: []].append(c)
            } else {
                undated.append(c)
            }
        }
        var result = byDay.keys.sorted().map { day in
            ImportSection(id: "\(day.timeIntervalSince1970)", title: day.formatted(dayFormat),
                          items: byDay[day]!.sorted { $0.primary.fileName.localizedStandardCompare($1.primary.fileName) == .orderedAscending })
        }
        if !undated.isEmpty { result.append(ImportSection(id: "undated", title: "Unknown Date", items: undated)) }
        sections = result
        candidates = result.flatMap(\.items)
        schedulePlan()
    }

    // MARK: - Check state

    func toggle(_ c: ImportCandidate) {
        guard !isLocked(c) else { return }
        if unchecked.contains(c.id) { unchecked.remove(c.id) } else { unchecked.insert(c.id) }
    }

    func checkAll() { unchecked.removeAll() }
    func uncheckAll() { unchecked = Set(candidates.map(\.id)) }

    /// Section header checkbox: checks all of the section unless all are already checked.
    func toggleSection(_ s: ImportSection) {
        let ids = s.items.filter { !isLocked($0) }.map(\.id)
        if ids.allSatisfy({ !unchecked.contains($0) }) { unchecked.formUnion(ids) } else { unchecked.subtract(ids) }
    }

    // MARK: - Destination

    func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose where imported photos are copied to (e.g. a folder on your photo drive)."
        panel.directoryURL = destination?.url
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            setDestination(try SecurityScopeManager.shared.registerRoot(url: url, in: catalog))
        } catch {
            errorMessage = "Can't use \(url.path): \(error)"
        }
    }

    private func setDestination(_ root: Root) {
        destination = root
        UserDefaults.standard.set(root.path, forKey: "import.destinationPath")
        destinationProblem = nil
        schedulePlan(destinationChanged: true)   // photos show "comparing" until the new destination is read
        let catalog = catalog
        // Off-main: a sleeping external drive can take a while to answer.
        Task.detached(priority: .userInitiated) { [self] in
            SecurityScopeManager.shared.ensureAccess(forPath: root.path, rootID: root.id, catalog: catalog)
            let problem: String?
            if !FileManager.default.fileExists(atPath: root.path) {
                problem = "“\(root.path)” is not available. Connect the drive or choose another destination."
            } else {
                do { try ImportFiles.checkWriteAccess(root.url); problem = nil } catch { problem = "\(error)" }
            }
            await MainActor.run {
                guard self.destination?.id == root.id else { return }
                self.destinationProblem = problem
                self.schedulePlan(destinationChanged: true)
            }
        }
    }

    // MARK: - Destination preview

    /// Recomputes `destinationPlan` off-main (debounced; reads the destination folders).
    /// `destinationChanged`: another folder / pattern / mode — the old plan and the "identical file
    /// already there" matches no longer apply, so photos show as comparing again.
    private func schedulePlan(destinationChanged: Bool = false) {
        planTask?.cancel()
        if destinationChanged {
            destinationPlan = nil
            destinationIdentical = []
        }
        guard isMatchingDestination, let dest = destination, !candidates.isEmpty else {
            destinationPlan = nil
            destinationIdentical = []
            isPlanning = false
            return
        }
        isPlanning = true
        let (all, wanted, lock) = planInputs()
        let metadata = metadata, pattern = pattern
        planTask = Task { [self] in
            try? await Task.sleep(for: .milliseconds(150))
            if Task.isCancelled { return }
            let plan = await Task.detached(priority: .userInitiated) {
                ImportDestinationPlanner.plan(all, included: wanted, lockIdentical: lock, metadata: metadata,
                                              destination: dest.url, pattern: pattern)
            }.value
            if Task.isCancelled { return }
            apply(plan)
            isPlanning = false
        }
    }

    /// Candidates, the ones the user wants (checked, not catalog duplicates when skipping), and
    /// whether identical files in the destination are left out.
    private func planInputs() -> ([ImportCandidate], Set<String>, Bool) {
        let wanted = Set(candidates.filter { !unchecked.contains($0.id) && !(skipDuplicates && duplicates.contains($0.id)) }.map(\.id))
        return (candidates, wanted, skipDuplicates)
    }

    private func apply(_ plan: ImportDestinationPlan) {
        destinationPlan = plan
        destinationIdentical = plan.identicalIDs
    }

    // MARK: - Import

    /// Import button: checks for conflicts first (target files already in the destination, or
    /// catalog duplicates the user included); asks Rename / Replace / Skip if there are any.
    func requestImport() {
        guard canImport else { return }
        errorMessage = nil
        guard mode == .copy, let dest = destination else {
            promptOrStart(fileConflicts: [])
            return
        }
        isPreparing = true
        planTask?.cancel()
        let (all, wanted, lock) = planInputs()
        let metadata = metadata, pattern = pattern
        Task { [self] in
            let plan = await Task.detached(priority: .userInitiated) {
                ImportDestinationPlanner.plan(all, included: wanted, lockIdentical: lock, metadata: metadata,
                                              destination: dest.url, pattern: pattern)
            }.value
            isPreparing = false
            isPlanning = false
            apply(plan)
            promptOrStart(fileConflicts: included.filter { plan.conflictIDs.contains($0.id) })
        }
    }

    private func promptOrStart(fileConflicts: [ImportCandidate]) {
        let dups = included.filter { duplicates.contains($0.id) }
        let ids = Set(fileConflicts.map(\.id)).union(dups.map(\.id))
        guard !ids.isEmpty else {
            startImport(policy: .rename)
            return
        }
        let names = candidates.filter { ids.contains($0.id) }.map(\.primary.fileName)
        conflictPrompt = ImportConflictPrompt(fileConflicts: fileConflicts.count, catalogDuplicates: dups.count,
                                              count: ids.count, examples: Array(names.prefix(4)))
    }

    /// Starts the import; conflicts are resolved with `policy`. Ends with `recap` set.
    func startImport(policy: ImportConflictPolicy) {
        conflictPrompt = nil
        guard canImport, let sourceURL else { return }
        let items = included
        // Identical file already in the destination but not in the catalog: catalog that file.
        let adopt = mode == .copy ? candidates.filter { isLocked($0) && !duplicates.contains($0.id) && isInDestination($0) } : []
        let name = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        let itemIDs = Set(items.map(\.id))
        let matches = duplicateMatches.filter { itemIDs.contains($0.key) }
        let options = ImportOptions(mode: mode, destination: destination?.url, pattern: pattern,
                                    targetFolderID: targetFolderID, newFolderName: name.isEmpty ? nil : name,
                                    conflictPolicy: policy, duplicateMatches: matches,
                                    adoptExisting: Set(adopt.map(\.id)))
        if mode == .addInPlace {
            // The photos stay on the source, so it must become a root (security-scoped bookmark).
            do { try SecurityScopeManager.shared.registerRoot(url: sourceURL, in: catalog) } catch {
                errorMessage = "Can't add \(sourceURL.path) to the catalog: \(error)"
                return
            }
        }
        let hadConflicts = !matches.isEmpty || items.contains(where: existsInDestination)
        let locked = candidates.filter { isLocked($0) && duplicates.contains($0.id) }.map(\.primary.fileName)
        let uncheckedCount = candidates.filter { unchecked.contains($0.id) && !isLocked($0) }.count
        let unreadableNames = files.filter { unreadable.contains($0.id) }.map(\.fileName)
        let folderName = name.isEmpty ? targetFolderID.flatMap { id in (try? catalog.folder(id: id))?.name } : name
        let base = ImportRecap(result: ImportResult(importDate: Date()), mode: mode, policy: hadConflicts ? policy : nil,
                                 sourceTitle: sourceTitle, destinationPath: mode == .copy ? destination?.path : nil,
                                 folderName: folderName, found: candidates.count, skippedDuplicates: locked,
                                 inDestination: adopt.map(\.primary.fileName),
                                 unchecked: uncheckedCount, unreadable: unreadableNames, ignored: ignoredFiles)
        cancelScan()
        planTask?.cancel()
        errorMessage = nil
        isImporting = true
        progress = ImportProgress()
        let job = ImportJob()
        self.job = job
        let metadata = metadata
        let catalog = catalog
        Task.detached(priority: .userInitiated) { [self] in
            var lastUpdate = Date.distantPast
            do {
                let result = try job.run(items + adopt, metadata: metadata, options: options, catalog: catalog) { p in
                    let now = Date()
                    guard now.timeIntervalSince(lastUpdate) > 0.08 || p.currentFile == nil else { return }
                    lastUpdate = now
                    Task { @MainActor in if self.isImporting { self.progress = p } }
                }
                if !result.replacedPhotoIDs.isEmpty {
                    // Replaced files: previews (of the photo and its virtual copies) are stale.
                    let ids = (try? catalog.idsIncludingVirtualCopies(result.replacedPhotoIDs)) ?? result.replacedPhotoIDs
                    PreviewService.shared.discard(photoIDs: ids)
                }
                ImportJob.warmPreviews(photoIDs: result.photoIDs)
                await MainActor.run {
                    var summary = base
                    summary.result = result
                    self.finish(summary)
                }
            } catch {
                await MainActor.run { self.fail(error) }
            }
        }
    }

    func cancelImport() { job?.cancel() }

    private func finish(_ summary: ImportRecap) {
        isImporting = false
        job = nil
        self.recap = summary
    }

    /// "Import More" on the recap: back to the grid with a fresh scan (catalog matches updated).
    func returnFromRecap() {
        recap = nil
        rescan()
    }

    private func fail(_ error: Error) {
        isImporting = false
        job = nil
        errorMessage = "\(error)"
    }
}
