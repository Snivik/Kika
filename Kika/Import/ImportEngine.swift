//
//  ImportEngine.swift
//  Kika
//
//  UI-free SD card / folder import engine (also used by Tools/sdimport_check.swift):
//    1. `ImportScanner.enumerate` lists supported photos under a source (recursive, no hidden files).
//    2. `ImportScanner.candidates` pairs RAW + JPEG with the same base name (JPEG = sidecar).
//    3. `ImportScanner.readMetadata` reads EXIF (header only, parallel) for the grid / duplicates.
//    4. `DuplicateIndex` flags files already in the catalog (same path, or name + size + capture date)
//       and remembers which catalog photo matched.
//    5. `ImportDestinationPlanner` previews the destination: date folders (existing / new), photos
//       added to each, and conflicts (a file with the target name already exists).
//    6. `ImportJob.run` copies safely (`name.tmp` → verify size → exclusive rename; never overwrites
//       unless the conflict policy is `.replace`), inserts photos in batches with ONE import date,
//       adds them to a folder, reports progress and a per-photo recap.
//
//  The caller must already have sandbox access to the source and destination.
//

import Foundation
import CoreGraphics

// MARK: - Model

/// A photo file found in the source.
nonisolated struct ImportFile: Sendable, Hashable, Identifiable {
    var url: URL
    var fileSize: Int64
    var modificationDate: Date?
    var isRAW: Bool

    var id: String { url.path }
    var fileName: String { url.lastPathComponent }
}

/// One importable photo: the primary file plus an optional sidecar (JPEG next to a RAW).
nonisolated struct ImportCandidate: Sendable, Hashable, Identifiable {
    var primary: ImportFile
    var sidecar: ImportFile?

    var id: String { primary.id }
    var files: [ImportFile] { sidecar.map { [primary, $0] } ?? [primary] }
    var totalSize: Int64 { primary.fileSize + (sidecar?.fileSize ?? 0) }
}

nonisolated enum ImportMode: String, Sendable, CaseIterable, Identifiable {
    /// Copy files to the destination, then add the copies.
    case copy
    /// Add the files where they are (no copy).
    case addInPlace
    var id: String { rawValue }
    var title: String { self == .copy ? "Copy to Destination" : "Add in Place" }
}

/// Destination subfolder layout by capture date.
nonisolated enum DestinationPattern: String, Sendable, CaseIterable, Identifiable {
    case yearAndDay   // 2026/2026-08-01
    case day          // 2026-08-01
    case none
    var id: String { rawValue }

    var title: String {
        switch self {
        case .yearAndDay: "YYYY/YYYY-MM-DD"
        case .day: "YYYY-MM-DD"
        case .none: "None (flat)"
        }
    }

    /// Relative subfolder for `date` in the local calendar ("" for `.none`).
    func subpath(for date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        let y = String(format: "%04d", c.year ?? 0)
        let day = String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
        switch self {
        case .yearAndDay: return y + "/" + day
        case .day: return day
        case .none: return ""
        }
    }
}

nonisolated struct ImportOptions: Sendable {
    var mode: ImportMode = .copy
    /// Destination root directory (copy mode). Must be writable (read/write security scope).
    var destination: URL?
    var pattern: DestinationPattern = .yearAndDay
    /// Existing catalog folder to add the photos to (or the parent of `newFolderName`).
    var targetFolderID: Int64?
    /// Create a folder with this name (inside `targetFolderID` if set) and add the photos to it.
    var newFolderName: String?
    /// What to do with a photo that conflicts: its target file already exists in the destination,
    /// or it matches a catalog photo (`duplicateMatches`).
    var conflictPolicy: ImportConflictPolicy = .rename
    /// Candidate id → catalog photo it duplicates (from `DuplicateIndex.match`). Only candidates
    /// the user chose to import anyway belong here.
    var duplicateMatches: [String: Int64] = [:]
    /// Candidates whose identical file (same name + size) is already in their destination folder
    /// but not in the catalog: nothing is copied, the file already there is added to the catalog.
    var adoptExisting: Set<String> = []
}

nonisolated enum ImportConflictPolicy: String, Sendable, CaseIterable, Identifiable {
    /// Keep both: copy under a free name ("L1000123-1") and add a new photo.
    case rename
    /// Overwrite the existing file; the existing catalog photo (same path, or the duplicate it
    /// matched) is updated to the new copy and keeps its edits, flags and folders.
    case replace
    /// Leave conflicting photos out.
    case skip
    var id: String { rawValue }
}

nonisolated struct ImportProgress: Sendable {
    var filesDone = 0
    var filesTotal = 0
    var bytesDone: Int64 = 0
    var bytesTotal: Int64 = 0
    var photosAdded = 0
    var currentFile: String?
    var elapsed: TimeInterval = 0

    var fraction: Double {
        bytesTotal > 0 ? Double(bytesDone) / Double(bytesTotal)
            : filesTotal > 0 ? Double(filesDone) / Double(filesTotal) : 0
    }
    /// Bytes per second (nil until there's enough data).
    var rate: Double? { elapsed > 0.5 && bytesDone > 0 ? Double(bytesDone) / elapsed : nil }
    var eta: TimeInterval? { rate.map { Double(bytesTotal - bytesDone) / $0 } }
}

nonisolated struct ImportResult: Sendable {
    var importDate: Date
    var photoIDs: [Int64] = []
    /// Folder the photos were added to (new or existing), if any.
    var folderID: Int64?
    var filesCopied = 0
    var bytesCopied: Int64 = 0
    var wasCancelled = false
    /// Per-file problems that didn't stop the import.
    var failures: [String] = []
    /// "L1000123.DNG → L1000123-1.DNG" (conflict policy `.rename`).
    var renamed: [String] = []
    /// Existing catalog photos updated to the new copy (policy `.replace`); their previews are stale.
    var replacedPhotoIDs: [Int64] = []
    /// File names left out because of a conflict (policy `.skip`).
    var skippedConflicts: [String] = []
    /// Destination subfolders ("2026/2026-09-19") with the number of photos copied into each.
    var destinationFolders: [String: Int] = [:]
    /// Destination subfolders this import created.
    var createdFolders: [String] = []
    /// File names catalogued from the identical copy already in the destination (`adoptExisting`).
    var adoptedExisting: [String] = []
    /// Set when the import stopped early (e.g. no write access). Photos copied before that are
    /// still catalogued.
    var stopError: ImportError?
    var elapsed: TimeInterval = 0
}

nonisolated enum ImportError: LocalizedError, CustomStringConvertible {
    case noWriteAccess(String)
    case noDestination
    case sizeMismatch(String)
    case io(String, Int32)

    var errorDescription: String? { description }
    var description: String {
        switch self {
        case .noWriteAccess(let path):
            "Кика doesn't have write access to “\(path)”; enable User Selected File: Read/Write (or pick a folder you can write to)."
        case .noDestination: "Choose a destination folder first."
        case .sizeMismatch(let name): "Copy of \(name) is incomplete (size mismatch)."
        case .io(let what, let code): "\(what): \(String(cString: strerror(code)))"
        }
    }

    static func isPermission(_ error: Error) -> Bool {
        if case ImportError.noWriteAccess = error { return true }
        if case ImportError.io(_, let code) = error { return [EACCES, EPERM, EROFS].contains(code) }
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain,
           [NSFileWriteNoPermissionError, NSFileWriteVolumeReadOnlyError, NSFileReadNoPermissionError].contains(ns.code) {
            return true
        }
        if ns.domain == NSPOSIXErrorDomain, [EACCES, EPERM, EROFS].contains(Int32(ns.code)) { return true }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? Error { return isPermission(underlying) }
        return false
    }
}

// MARK: - Scanning

nonisolated enum ImportScanner {
    /// Recursively lists supported photos under `directory` (hidden files and packages skipped;
    /// videos and other files ignored), sorted by path. `progress` gets the running count.
    static func enumerate(_ directory: URL, isCancelled: () -> Bool = { false },
                          progress: (Int) -> Void = { _ in }) -> [ImportFile] {
        scan(directory, isCancelled: isCancelled, progress: progress).files
    }

    /// `enumerate`, plus the visible regular files that were left out (videos, sidecars like
    /// .XMP / .THM…), counted by upper-cased extension ("MOV": 17).
    static func scan(_ directory: URL, isCancelled: () -> Bool = { false },
                     progress: (Int) -> Void = { _ in }) -> (files: [ImportFile], ignored: [String: Int]) {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let e = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: keys,
                                                     options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return ([], [:]) }
        var files: [ImportFile] = []
        var ignored: [String: Int] = [:]
        for case let url as URL in e {
            if isCancelled() { break }
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
            guard PhotoMetadataReader.isSupportedImage(url: url) else {
                let ext = url.pathExtension.uppercased()
                ignored[ext.isEmpty ? "(no extension)" : ext, default: 0] += 1
                continue
            }
            files.append(ImportFile(url: url, fileSize: Int64(v.fileSize ?? 0), modificationDate: v.contentModificationDate,
                                    isRAW: PhotoMetadataReader.isRAW(url: url)))
            if files.count % 100 == 0 { progress(files.count) }
        }
        progress(files.count)
        return (files.sorted { $0.url.path < $1.url.path }, ignored)
    }

    static let videoExtensions: Set<String> = ["MOV", "MP4", "M4V", "AVI", "MTS", "M2TS", "3GP", "MXF", "INSV", "LRV"]

    /// Candidates in input order. With `pairSidecars`, a JPEG (or other non-RAW) with the same
    /// directory + base name (case-insensitive) as a RAW becomes that RAW's sidecar.
    static func candidates(from files: [ImportFile], pairSidecars: Bool) -> [ImportCandidate] {
        guard pairSidecars else { return files.map { ImportCandidate(primary: $0) } }
        func key(_ f: ImportFile) -> String { f.url.deletingPathExtension().path.lowercased() }
        let rawKeys = Set(files.filter(\.isRAW).map(key))
        var sidecars: [String: ImportFile] = [:]
        for f in files where !f.isRAW && rawKeys.contains(key(f)) {
            // Prefer JPEG over HEIC/TIFF if several.
            let isJPEG = ["jpg", "jpeg"].contains(f.url.pathExtension.lowercased())
            if sidecars[key(f)] == nil || isJPEG { sidecars[key(f)] = f }
        }
        let sidecarIDs = Set(sidecars.values.map(\.id))
        return files.compactMap { f in
            if sidecarIDs.contains(f.id) { return nil }
            return ImportCandidate(primary: f, sidecar: f.isRAW ? sidecars[key(f)] : nil)
        }
    }

    /// Reads metadata of `files` in parallel. Unreadable files are absent from the result.
    static func readMetadata(_ files: [ImportFile]) -> [String: PhotoMetadata] {
        var results = [PhotoMetadata?](repeating: nil, count: files.count)
        results.withUnsafeMutableBufferPointer { buf in
            nonisolated(unsafe) let base = buf.baseAddress! // each iteration writes its own slot
            DispatchQueue.concurrentPerform(iterations: files.count) { i in
                base[i] = PhotoMetadataReader.read(url: files[i].url)
            }
        }
        var out: [String: PhotoMetadata] = [:]
        for (f, m) in zip(files, results) { if let m { out[f.id] = m } }
        PhotoMetadataReader.adoptSidecarOffsets(&out)   // RAW without zone offset: use its JPEG's
        return out
    }

    /// Date used for grouping / destination folders.
    static func date(of file: ImportFile, metadata: PhotoMetadata?) -> Date? {
        metadata?.captureDate ?? file.modificationDate
    }
}

/// Snapshot of the catalog for "already imported" detection. Build once per scan (off-main).
nonisolated struct DuplicateIndex: Sendable {
    /// Catalog path → photo id (0 = imported in this session, id unknown).
    private var paths: [String: Int64] = [:]
    /// "lowercased file name|size" -> (photo id, capture date) of catalog photos.
    private var fingerprints: [String: [(id: Int64, date: Date?)]] = [:]

    init(catalog: Catalog) throws {
        for f in try catalog.importFingerprints() {
            paths[f.path] = f.id
            fingerprints["\(f.fileName.lowercased())|\(f.fileSize)", default: []].append((f.id, f.captureDate))
        }
    }

    init() {}

    /// True if a photo with the same path is catalogued, or one with the same file name + size
    /// and (when both are known) a capture date within a second.
    func isDuplicate(_ file: ImportFile, metadata: PhotoMetadata?) -> Bool { match(file, metadata: metadata) != nil }

    /// The catalog photo `file` duplicates (see `isDuplicate`), nil if none.
    func match(_ file: ImportFile, metadata: PhotoMetadata?) -> Int64? {
        if let id = paths[file.url.standardizedFileURL.path] { return id }
        guard let entries = fingerprints["\(file.fileName.lowercased())|\(file.fileSize)"] else { return nil }
        guard let date = metadata?.captureDate else { return entries.first?.id }
        return entries.first { e in e.date.map { abs($0.timeIntervalSince(date)) < 1 } ?? true }?.id
    }

    /// Remember files imported in this session (so re-scans before a catalog reload still match).
    mutating func add(_ file: ImportFile, metadata: PhotoMetadata?) {
        paths[file.url.standardizedFileURL.path] = 0
        fingerprints["\(file.fileName.lowercased())|\(file.fileSize)", default: []].append((0, metadata?.captureDate))
    }
}

// MARK: - File operations

nonisolated enum ImportFiles {
    /// Throws `ImportError.noWriteAccess` if files can't be created in `directory` (creates it).
    static func checkWriteAccess(_ directory: URL) throws {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw ImportError.isPermission(error) ? ImportError.noWriteAccess(directory.path) : error
        }
        let probe = directory.appendingPathComponent(".kika-write-check-\(UUID().uuidString)").path
        let fd = open(probe, O_WRONLY | O_CREAT | O_EXCL, 0o644)
        guard fd >= 0 else {
            let code = errno
            throw [EACCES, EPERM, EROFS].contains(code) ? ImportError.noWriteAccess(directory.path)
                : ImportError.io("Can't write to \(directory.path)", code)
        }
        close(fd)
        unlink(probe)
    }

    /// Picks a base name so that `base.<ext>` for every extension (and its `.tmp`) is free in
    /// `directory`: "L1000123", then "L1000123-1", "-2", … Keeps RAW + JPEG pairs matching.
    static func uniqueBaseName(_ base: String, extensions: [String], in directory: URL) -> String {
        let fm = FileManager.default
        for n in 0... {
            let candidate = n == 0 ? base : "\(base)-\(n)"
            let taken = extensions.contains { ext in
                let name = ext.isEmpty ? candidate : candidate + "." + ext
                let path = directory.appendingPathComponent(name).path
                return fm.fileExists(atPath: path) || fm.fileExists(atPath: path + ".tmp")
            }
            if !taken { return candidate }
        }
        return base
    }

    /// True if `base.<ext>` exists in `directory` for any of `extensions`.
    static func exists(_ base: String, extensions: [String], in directory: URL) -> Bool {
        uniqueBaseName(base, extensions: extensions, in: directory) != base
    }

    /// Copies `source` to `destination` via `destination.tmp` (exclusive create), fsyncs,
    /// verifies the size, preserves dates, then renames without ever overwriting (unless
    /// `replace`: then an existing file is atomically replaced). On any failure or cancellation
    /// the temp file is removed. `onBytes` gets each chunk's byte count.
    static func copy(_ source: URL, to destination: URL, replace: Bool = false, isCancelled: () -> Bool = { false },
                     onBytes: (Int64) -> Void = { _ in }) throws -> Int64 {
        let tmp = destination.path + ".tmp"
        let src = open(source.path, O_RDONLY)
        guard src >= 0 else { throw ImportError.io("Can't read \(source.lastPathComponent)", errno) }
        defer { close(src) }
        _ = fcntl(src, F_NOCACHE, 1) // big sequential read: don't pollute the page cache

        let dst = open(tmp, O_WRONLY | O_CREAT | O_EXCL, 0o644)
        guard dst >= 0 else {
            let code = errno
            if [EACCES, EPERM, EROFS].contains(code) { throw ImportError.noWriteAccess(destination.deletingLastPathComponent().path) }
            throw ImportError.io("Can't create \(tmp)", code)
        }
        var ok = false
        defer { if !ok { unlink(tmp) } }

        let chunk = 8 << 20
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: chunk, alignment: 16384)
        defer { buffer.deallocate() }
        var total: Int64 = 0
        do {
            defer { close(dst) }
            while true {
                if isCancelled() { throw CancellationError() }
                let n = read(src, buffer, chunk)
                if n < 0 { throw ImportError.io("Read error in \(source.lastPathComponent)", errno) }
                if n == 0 { break }
                var written = 0
                while written < n {
                    let w = write(dst, buffer + written, n - written)
                    if w < 0 {
                        let code = errno
                        if [EACCES, EPERM, EROFS].contains(code) { throw ImportError.noWriteAccess(destination.deletingLastPathComponent().path) }
                        throw ImportError.io("Write error in \(destination.lastPathComponent)", code)
                    }
                    written += w
                }
                total += Int64(n)
                onBytes(Int64(n))
            }
            if fsync(dst) != 0 { throw ImportError.io("Can't flush \(destination.lastPathComponent)", errno) }
        }

        // Verify against the source's size on disk.
        var stSrc = stat(), stTmp = stat()
        guard fstat(src, &stSrc) == 0, stat(tmp, &stTmp) == 0, stSrc.st_size == stTmp.st_size, Int64(stTmp.st_size) == total else {
            throw ImportError.sizeMismatch(source.lastPathComponent)
        }
        // Keep the camera's file dates (Finder / other tools rely on them).
        let attrs = (try? FileManager.default.attributesOfItem(atPath: source.path)) ?? [:]
        var keep: [FileAttributeKey: Any] = [:]
        if let d = attrs[.creationDate] { keep[.creationDate] = d }
        if let d = attrs[.modificationDate] { keep[.modificationDate] = d }
        if !keep.isEmpty { try? FileManager.default.setAttributes(keep, ofItemAtPath: tmp) }

        if replace {
            guard rename(tmp, destination.path) == 0 else {
                throw ImportError.io("Can't replace \(destination.lastPathComponent)", errno)
            }
        } else {
            try renameExclusive(tmp, to: destination.path)
        }
        ok = true
        return total
    }

    /// `rename` that fails with EEXIST instead of overwriting. `renamex_np(RENAME_EXCL)` is atomic
    /// but APFS / HFS+ only: exFAT / FAT cards and drives (and SMB shares) answer ENOTSUP, so
    /// there the name is reserved first with an exclusive create and the temp file renamed over
    /// that empty placeholder.
    static func renameExclusive(_ from: String, to: String) throws {
        if renamex_np(from, to, UInt32(RENAME_EXCL)) == 0 { return }
        let code = errno
        guard code == ENOTSUP || code == EINVAL || code == ENOTTY else {
            throw ImportError.io("Can't rename to \((to as NSString).lastPathComponent)", code)
        }
        let placeholder = open(to, O_WRONLY | O_CREAT | O_EXCL, 0o644)
        guard placeholder >= 0 else {
            throw ImportError.io("Can't create \((to as NSString).lastPathComponent)", errno)
        }
        close(placeholder)
        guard rename(from, to) == 0 else {
            let code = errno
            unlink(to)
            throw ImportError.io("Can't rename to \((to as NSString).lastPathComponent)", code)
        }
    }
}

// MARK: - Destination preview

/// One folder of the destination preview (Lightroom's merged tree).
nonisolated struct ImportDestinationFolder: Sendable, Hashable, Identifiable {
    /// Relative to the destination ("2026", "2026/2026-09-19"; "" = the destination itself).
    var path: String
    var name: String
    var depth: Int
    var exists: Bool
    /// Visible files already directly inside it (only counted for folders the import adds to).
    var existingFiles: Int
    /// Photos the import adds to it (with its subfolders). 0 = an existing folder left untouched.
    var adding: Int
    /// Of those, photos whose file name is already taken there.
    var conflicts: Int
    /// Photos left out because an identical file (same name + size) is already there.
    var identical: Int = 0
    var id: String { path }
    var parentPath: String? { path.isEmpty ? nil : (path as NSString).deletingLastPathComponent }
}

nonisolated struct ImportDestinationPlan: Sendable {
    /// Destination first, then its subfolders depth-first in name order: every folder the import
    /// adds to or creates, plus the existing folders next to them (`adding == 0`).
    var folders: [ImportDestinationFolder] = []
    /// Imported candidates whose target file name (primary or sidecar) is already taken.
    var conflictIDs: Set<String> = []
    /// Candidates (all of them, imported or not) whose target folder already holds an identical
    /// primary file (same name, case-insensitive, and size): duplicates on disk.
    var identicalIDs: Set<String> = []
    /// Candidates whose metadata was known when planning (their target folder is final).
    var plannedIDs: Set<String> = []
}

nonisolated extension DestinationPattern {
    /// Folder levels below the destination (2026/2026-09-01 → 2).
    var depth: Int {
        switch self {
        case .yearAndDay: 2
        case .day: 1
        case .none: 0
        }
    }
}

nonisolated enum ImportDestinationPlanner {
    /// Where `candidates` would land under `destination` with `pattern`, compared with what is on
    /// disk. `included` = the candidates the user wants (nil = all); with `lockIdentical` those
    /// with an identical file in place are left out of the counts (they won't be copied). Reads
    /// each folder once (call off-main: drives can be slow).
    static func plan(_ candidates: [ImportCandidate], included: Set<String>? = nil, lockIdentical: Bool = false,
                     metadata: [String: PhotoMetadata], destination: URL,
                     pattern: DestinationPattern, now: Date = Date(),
                     isCancelled: () -> Bool = { false }) -> ImportDestinationPlan {
        let fm = FileManager.default
        var plan = ImportDestinationPlan()

        struct Listing { var files: [String: Int64]; var folders: [String] }
        var listings: [String: Listing?] = [:]
        /// Visible files (lower-cased name → size) and subfolders of `path` (nil = no such folder).
        func listing(_ path: String) -> Listing? {
            if let cached = listings[path] { return cached }
            let url = path.isEmpty ? destination : destination.appendingPathComponent(path, isDirectory: true)
            let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey]
            var result: Listing?
            if let urls = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) {
                var l = Listing(files: [:], folders: [])
                for u in urls {
                    let v = try? u.resourceValues(forKeys: Set(keys))
                    if v?.isDirectory == true { l.folders.append(u.lastPathComponent) }
                    else { l.files[u.lastPathComponent.lowercased()] = Int64(v?.fileSize ?? 0) }
                }
                result = l
            }
            listings[path] = result
            return result
        }

        var bySub: [String: [ImportCandidate]] = [:]
        for c in candidates {
            let meta = metadata[c.id]
            if meta != nil { plan.plannedIDs.insert(c.id) }
            bySub[pattern.subpath(for: ImportScanner.date(of: c.primary, metadata: meta) ?? now), default: []].append(c)
        }

        var nodes: [String: ImportDestinationFolder] = [:]
        func node(_ path: String) -> ImportDestinationFolder {
            if let n = nodes[path] { return n }
            let l = listing(path)
            let url = path.isEmpty ? destination : destination.appendingPathComponent(path, isDirectory: true)
            let n = ImportDestinationFolder(path: path, name: path.isEmpty ? destination.lastPathComponent : (path as NSString).lastPathComponent,
                                            depth: path.isEmpty ? 0 : path.split(separator: "/").count,
                                            exists: l != nil || fm.fileExists(atPath: url.path),
                                            existingFiles: l?.files.count ?? 0, adding: 0, conflicts: 0)
            nodes[path] = n
            return n
        }

        for (sub, items) in bySub {
            if isCancelled() { break }
            let taken = listing(sub)?.files ?? [:]
            let identical = items.filter { taken[$0.primary.fileName.lowercased()] == $0.primary.fileSize }
            plan.identicalIDs.formUnion(identical.map(\.id))
            let identicalIDs = Set(identical.map(\.id))
            let imported = items.filter { c in
                (included?.contains(c.id) ?? true) && !(lockIdentical && identicalIDs.contains(c.id))
            }
            let conflicting = imported.filter { c in c.files.contains { taken[$0.fileName.lowercased()] != nil } }
            plan.conflictIDs.formUnion(conflicting.map(\.id))
            let lockedHere = lockIdentical ? identical.filter { included?.contains($0.id) ?? true }.count : 0
            guard !imported.isEmpty || lockedHere > 0 else { continue }
            // The folder and every ancestor up to the destination.
            var path = sub
            while true {
                var n = node(path)
                n.adding += imported.count
                n.conflicts += conflicting.count
                n.identical += lockedHere
                nodes[path] = n
                if path.isEmpty { break }
                path = (path as NSString).deletingLastPathComponent
            }
        }
        _ = node("")

        // Existing folders next to the touched ones (one level down from each touched folder,
        // down to the pattern's depth), so the user sees where the new photos land.
        for n in nodes.values where n.depth < pattern.depth && n.exists {
            for name in listing(n.path)?.folders ?? [] {
                let path = n.path.isEmpty ? name : n.path + "/" + name
                guard nodes[path] == nil else { continue }
                nodes[path] = ImportDestinationFolder(path: path, name: name, depth: n.depth + 1, exists: true,
                                                      existingFiles: 0, adding: 0, conflicts: 0)
            }
        }

        plan.folders = nodes.values.sorted { a, b in
            a.path.isEmpty ? !b.path.isEmpty : b.path.isEmpty ? false : a.path.localizedStandardCompare(b.path) == .orderedAscending
        }
        return plan
    }
}

// MARK: - Job

/// One import run. `run` is synchronous — call it off the main thread; `cancel()` from anywhere
/// (stops after the current chunk; what was copied so far is still added to the catalog).
nonisolated final class ImportJob: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }

    static let insertBatchSize = 24

    /// Imports `candidates` (metadata keyed by primary file path; missing entries are read here).
    /// `progress` is called often from the calling thread — throttle / hop to main yourself.
    func run(_ candidates: [ImportCandidate], metadata: [String: PhotoMetadata], options: ImportOptions,
             catalog: Catalog, importDate: Date = Date(),
             progress: (ImportProgress) -> Void = { _ in }) throws -> ImportResult {
        let start = Date()
        var result = ImportResult(importDate: importDate)
        var p = ImportProgress()
        p.filesTotal = candidates.reduce(0) { $0 + $1.files.count }
        p.bytesTotal = options.mode == .copy ? candidates.reduce(0) { $0 + $1.totalSize } : 0

        if options.mode == .copy {
            guard let dest = options.destination else { throw ImportError.noDestination }
            try ImportFiles.checkWriteAccess(dest)
        }

        var batch: [Photo] = []
        func flush() throws {
            guard !batch.isEmpty else { return }
            result.photoIDs += try catalog.insertPhotos(batch)
            p.photosAdded = result.photoIDs.count
            batch.removeAll()
        }
        /// Queues a new photo, or with `.replace` updates the photo already at its path / the
        /// catalog duplicate it matched (keeping that photo's edits, flags and folders).
        func add(_ photo: Photo, match: Int64?) throws {
            guard options.conflictPolicy == .replace,
                  let existing = try catalog.photoID(path: photo.path) ?? match.flatMap({ $0 > 0 ? $0 : nil }) else {
                batch.append(photo)
                return
            }
            try catalog.replaceImportedPhoto(id: existing, with: photo)
            result.replacedPhotoIDs.append(existing)
            result.photoIDs.append(existing)
            p.photosAdded = result.photoIDs.count
        }

        // Destination subfolders this run creates (removed again at the end if left empty).
        var createdDirectories: [URL] = []
        func makeDirectory(_ dir: URL, in dest: URL) throws {
            let fm = FileManager.default
            var missing: [URL] = []
            // Plain paths: `standardizedFileURL` drops /private only for paths that exist.
            var u = dir
            let stop = dest.path
            while u.path.count > stop.count, u.path.hasPrefix(stop), !fm.fileExists(atPath: u.path) {
                missing.append(u)
                u = u.deletingLastPathComponent()
            }
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            createdDirectories += missing.reversed()
        }

        struct SkipConflict: Error {}

        for c in candidates {
            if isCancelled { result.wasCancelled = true; break }
            p.currentFile = c.primary.fileName
            p.elapsed = Date().timeIntervalSince(start)
            progress(p)
            let meta = metadata[c.id] ?? PhotoMetadataReader.read(url: c.primary.url, sidecar: c.sidecar?.url)
            let match = options.duplicateMatches[c.id]

            switch options.mode {
            case .addInPlace:
                p.filesDone += c.files.count
                if match != nil, options.conflictPolicy == .skip {
                    result.skippedConflicts.append(c.primary.fileName)
                    continue
                }
                guard let meta else { result.failures.append("\(c.primary.fileName): not a readable image"); continue }
                try add(Photo(url: c.primary.url, metadata: meta, importDate: importDate,
                              sidecarPath: c.sidecar?.url.standardizedFileURL.path), match: match)

            case .copy:
                let dest = options.destination!
                let date = ImportScanner.date(of: c.primary, metadata: meta) ?? importDate
                let sub = options.pattern.subpath(for: date)
                let dir = sub.isEmpty ? dest : dest.appendingPathComponent(sub, isDirectory: true)
                if options.adoptExisting.contains(c.id) {
                    // Already copied earlier (identical file in place): catalog that file, copy nothing.
                    p.filesDone += c.files.count
                    p.bytesDone += c.totalSize
                    let target = dir.appendingPathComponent(c.primary.fileName)
                    let size = (try? target.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
                    guard size == c.primary.fileSize, try catalog.photoID(path: target.standardizedFileURL.path) == nil,
                          var m = meta ?? PhotoMetadataReader.read(url: target) else { continue }
                    m.fileSize = c.primary.fileSize
                    let sidecar = c.sidecar.map { dir.appendingPathComponent($0.fileName) }
                        .flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0.standardizedFileURL.path : nil }
                    batch.append(Photo(url: target, metadata: m, importDate: importDate, sidecarPath: sidecar))
                    result.adoptedExisting.append(c.primary.fileName)
                    if batch.count >= Self.insertBatchSize { try flush() }
                    continue
                }
                var copied: [URL] = []
                var fresh: [URL] = []   // files that didn't exist before (removed again on failure)
                let bytesBefore = p.bytesDone
                do {
                    try makeDirectory(dir, in: dest)
                    let original = c.primary.url.deletingPathExtension().lastPathComponent
                    let extensions = c.files.map(\.url.pathExtension)
                    var base = original
                    var replacing = false
                    let fileConflict = ImportFiles.exists(original, extensions: extensions, in: dir)
                    if fileConflict || match != nil {
                        switch options.conflictPolicy {
                        case .skip: throw SkipConflict()
                        case .replace: replacing = fileConflict
                        case .rename:
                            if fileConflict {
                                base = ImportFiles.uniqueBaseName(original, extensions: extensions, in: dir)
                                let ext = c.primary.url.pathExtension
                                result.renamed.append("\(c.primary.fileName) → \(ext.isEmpty ? base : base + "." + ext)")
                            }
                        }
                    }
                    for f in c.files {
                        let ext = f.url.pathExtension
                        let target = dir.appendingPathComponent(ext.isEmpty ? base : base + "." + ext)
                        let existed = replacing && FileManager.default.fileExists(atPath: target.path)
                        _ = try ImportFiles.copy(f.url, to: target, replace: existed, isCancelled: { isCancelled }) { bytes in
                            p.bytesDone += bytes
                            p.elapsed = Date().timeIntervalSince(start)
                            progress(p)
                        }
                        copied.append(target)
                        if !existed { fresh.append(target) }
                    }
                    p.filesDone += copied.count
                    result.filesCopied += copied.count
                    result.bytesCopied += c.totalSize
                    result.destinationFolders[sub, default: 0] += 1
                } catch is SkipConflict {
                    result.skippedConflicts.append(c.primary.fileName)
                    p.filesDone += c.files.count
                    p.bytesDone = bytesBefore + c.totalSize
                    continue
                } catch {
                    // All or nothing per photo: remove this candidate's fresh copies (never sources,
                    // never files it replaced — those are complete copies).
                    for url in fresh { unlink(url.path) }
                    copied = []
                    if error is CancellationError {
                        result.wasCancelled = true
                    } else if ImportError.isPermission(error) {
                        result.stopError = .noWriteAccess(dest.path)
                    } else {
                        result.failures.append("\(c.primary.fileName): \(error)")
                        p.filesDone += c.files.count
                        p.bytesDone = bytesBefore + c.totalSize
                    }
                }
                guard let primaryURL = copied.first else { break } // failed / cancelled (handled below)
                var m = meta ?? PhotoMetadataReader.read(url: primaryURL, sidecar: copied.count > 1 ? copied[1] : nil)
                m?.fileSize = c.primary.fileSize
                guard let m else { result.failures.append("\(c.primary.fileName): not a readable image"); continue }
                try add(Photo(url: primaryURL, metadata: m, importDate: importDate,
                              sidecarPath: copied.count > 1 ? copied[1].standardizedFileURL.path : nil), match: match)
            }
            if result.wasCancelled || result.stopError != nil { break }
            if batch.count >= Self.insertBatchSize { try flush() }
        }
        try flush()

        // Date folders that stayed empty (every copy into them failed / was cancelled) go away again.
        if let dest = options.destination {
            for dir in createdDirectories.reversed() { rmdir(dir.path) }   // deepest first; non-empty ones stay
            result.createdFolders = createdDirectories
                .filter { FileManager.default.fileExists(atPath: $0.path) }
                .map { String($0.path.dropFirst(dest.path.count + 1)) }
        }

        // Folder membership.
        if !result.photoIDs.isEmpty {
            var folderID = options.targetFolderID
            if let name = options.newFolderName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
                folderID = try catalog.createFolder(name: name, parentID: options.targetFolderID)
            }
            if let folderID {
                try catalog.addPhotos(result.photoIDs, toFolder: folderID)
                result.folderID = folderID
            }
        }
        result.elapsed = Date().timeIntervalSince(start)
        p.elapsed = result.elapsed
        p.currentFile = nil
        progress(p)
        return result
    }

    /// Queues a background preview build job (thumbnails only) for freshly imported photos.
    /// Low priority (the grid's visible requests go first); progress shows in `PreviewActivityView`.
    static func warmPreviews(photoIDs: [Int64]) {
        PreviewService.shared.build(photoIDs: photoIDs, levels: [.thumbnail], title: "Building thumbnails for imported photos")
    }
}
