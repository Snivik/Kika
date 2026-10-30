//
//  DeviceMove.swift
//  Kika
//
//  Move to Device (engine; Tools/devices_check.swift): copies photos' files (+ sidecars) into a
//  destination folder, typically on another device (laptop → photo drive / NAS), byte-compares every
//  copy with its original, then points the catalog at the copy (`Catalog.relocatePhotos`). Edits,
//  flags, tags, folders, virtual copies and previews are keyed by photo id, so they all stay. Optionally
//  moves the originals to the Trash afterwards.
//
//  - Photo by photo: a cancel or failure leaves every photo pointing at a complete, verified file.
//  - Both devices must be connected: a photo whose file isn't reachable is skipped ("not connected").
//  - Names are kept; a different file with the same name gets "-1", "-2"… (as Import). An identical
//    file already at the target (an interrupted move) is used as is, unless another catalogued photo
//    is there (a duplicate: skipped, nothing trashed).
//  - Virtual copies move with their master (they share its file).
//

import Foundation

/// Folder layout under the destination.
nonisolated enum DeviceMoveLayout: String, CaseIterable, Identifiable, Sendable {
    case yearAndDay, day, sameFolders, flat
    var id: String { rawValue }

    var title: String {
        switch self {
        case .yearAndDay: DestinationPattern.yearAndDay.title
        case .day: DestinationPattern.day.title
        case .sameFolders: "Same Folders as Now"
        case .flat: DestinationPattern.none.title
        }
    }

    var help: String {
        switch self {
        case .yearAndDay, .day: "Date folders by capture date, like Import (e.g. 2026/2026-10-21)"
        case .sameFolders: "Keep each file's folders below its current drive folder (e.g. Trip/Day 1)"
        case .flat: "Every file directly in the destination folder"
        }
    }

    /// Folder under the destination for `photo` ("" = the destination itself). Date layouts use the
    /// capture date, else the import date. Same Folders: the file's folder relative to `rootPath`
    /// (its covering root); without a root, the file's own folder name.
    func subpath(for photo: Photo, rootPath: String?, calendar: Calendar = .current) -> String {
        switch self {
        case .yearAndDay: return DestinationPattern.yearAndDay.subpath(for: photo.captureDate ?? photo.importDate, calendar: calendar)
        case .day: return DestinationPattern.day.subpath(for: photo.captureDate ?? photo.importDate, calendar: calendar)
        case .flat: return ""
        case .sameFolders:
            let dir = Catalog.normalizedPath((photo.path as NSString).deletingLastPathComponent)
            if let rootPath {
                let root = Catalog.normalizedPath(rootPath)
                if dir == root { return "" }
                if Catalog.path(dir, isUnderRoot: root) { return String(dir.dropFirst(root == "/" ? 1 : root.count + 1)) }
            }
            return (dir as NSString).lastPathComponent
        }
    }
}

nonisolated struct DeviceMoveOptions: Sendable {
    /// Must be writable (read/write security scope started by the caller).
    var destination: URL
    var layout: DeviceMoveLayout = .yearAndDay
    /// Move the originals (+ sidecars) to the Trash once their copies are verified and catalogued.
    var trashOriginals = false
}

nonisolated enum DeviceMoveSkipReason: Sendable, Equatable, CustomStringConvertible {
    /// The file's device isn't connected.
    case notConnected(String)
    /// The device is connected but the file isn't there.
    case missing
    /// Its target is where it already is.
    case alreadyThere
    /// Another catalogued photo is an identical file at the target.
    case duplicate(String)
    case failed(String)

    var description: String {
        switch self {
        case .notConnected(let device): "\(device) is not connected"
        case .missing: "the file is missing"
        case .alreadyThere: "already in the destination"
        case .duplicate(let path): "the same file is already in the catalog at \(path)"
        case .failed(let why): why
        }
    }
}

nonisolated struct DeviceMoveSkip: Sendable {
    var photoID: Int64
    var fileName: String
    var reason: DeviceMoveSkipReason
}

nonisolated struct DeviceMoveProgress: Sendable, Equatable {
    var done = 0
    var total = 0
    var bytesDone: Int64 = 0
    var bytesTotal: Int64 = 0
}

nonisolated struct DeviceMoveResult: Sendable {
    /// Masters now pointing at their new file.
    var moved: [Int64] = []
    /// `moved` + their virtual copies (their previews should retry: they may have been offline).
    var updatedPhotoIDs: Set<Int64> = []
    var targets: [URL] = []
    var skipped: [DeviceMoveSkip] = []
    /// Originals (and sidecars) moved to the Trash.
    var trashed = 0
    /// File names that couldn't be moved to the Trash (still at their old place).
    var trashFailures: [String] = []
    var bytes: Int64 = 0
    var wasCancelled = false
    /// Why the job stopped early (destination gone / not writable).
    var stopError: String?

    var summary: String {
        func photos(_ n: Int) -> String { n == 1 ? "1 photo" : "\(n) photos" }
        var parts = ["Moved \(photos(moved.count)) (\(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)))"]
        if !skipped.isEmpty { parts.append("\(skipped.count) skipped") }
        if trashed > 0 { parts.append("\(trashed) original file\(trashed == 1 ? "" : "s") in the Trash") }
        if wasCancelled { parts.append("cancelled") }
        return parts.joined(separator: ", ") + "."
    }
}

nonisolated enum DeviceMoveError: Error, CustomStringConvertible {
    case read(String, Int32)
    var description: String {
        switch self {
        case .read(let name, let code): "Can't read \(name): \(String(cString: strerror(code)))"
        }
    }
}

nonisolated final class DeviceMoveJob: @unchecked Sendable {
    let catalog: Catalog
    let photoIDs: [Int64]
    let options: DeviceMoveOptions
    /// Moves an original to the Trash (harnesses replace it so they don't fill the user's Trash).
    var trashItem: @Sendable (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }

    private let lock = NSLock()
    private var cancelled = false

    init(catalog: Catalog, photoIDs: [Int64], options: DeviceMoveOptions) {
        self.catalog = catalog
        self.photoIDs = photoIDs
        self.options = options
    }

    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

    /// The distinct masters of `ids` in order (a virtual copy stands for its master's file).
    static func masters(of ids: [Int64], catalog: Catalog) throws -> [Photo] {
        let photos = try catalog.photos(ids: ids)
        var seen = Set<Int64>()
        let masterIDs = photos.map(\.masterOrSelfID).filter { seen.insert($0).inserted }
        var byID = Dictionary(photos.filter { !$0.isVirtualCopy }.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for m in try catalog.photos(ids: masterIDs.filter { byID[$0] == nil }) { byID[m.id] = m }
        return masterIDs.compactMap { byID[$0] }
    }

    /// Runs on the calling thread (call it off-main). `progress` is called after each chunk / photo.
    func run(progress: (DeviceMoveProgress) -> Void) -> DeviceMoveResult {
        var result = DeviceMoveResult()
        let masters: [Photo], roots: [Root]
        do {
            masters = try Self.masters(of: photoIDs, catalog: catalog)
            roots = try catalog.allRoots()
        } catch {
            result.stopError = "\(error)"
            return result
        }
        let mounted = PhotoDevice.mountedVolumePaths()
        var p = DeviceMoveProgress(total: masters.count, bytesTotal: masters.reduce(0) { $0 + $1.fileSize })
        progress(p)

        for photo in masters {
            if isCancelled { result.wasCancelled = true; break }
            guard FileManager.default.fileExists(atPath: options.destination.path) else {
                result.stopError = "“\(options.destination.path)” is no longer available. Reconnect the drive and move the rest again."
                break
            }
            let bytesBefore = p.bytesDone
            do {
                if let reason = try move(photo, roots: roots, mounted: mounted, result: &result,
                                         onBytes: { p.bytesDone += $0; progress(p) }) {
                    result.skipped.append(DeviceMoveSkip(photoID: photo.id, fileName: photo.fileName, reason: reason))
                }
            } catch is CancellationError {
                result.wasCancelled = true
                break
            } catch let error as ImportError where ImportError.isPermission(error) {
                result.stopError = error.description
                break
            } catch {
                result.skipped.append(DeviceMoveSkip(photoID: photo.id, fileName: photo.fileName, reason: .failed("\(error)")))
            }
            p.done += 1
            p.bytesDone = bytesBefore + photo.fileSize
            progress(p)
        }

        if !result.moved.isEmpty {
            result.updatedPhotoIDs = Set((try? catalog.idsIncludingVirtualCopies(result.moved)) ?? result.moved)
            catalog.postChange(.roots)
        }
        return result
    }

    /// Moves one master; returns why it was skipped, nil when moved. Throws to skip with an error
    /// (or stop: cancellation, no write access).
    private func move(_ photo: Photo, roots: [Root], mounted: Set<String>, result: inout DeviceMoveResult,
                      onBytes: (Int64) -> Void) throws -> DeviceMoveSkipReason? {
        let fm = FileManager.default
        let device = PhotoDevice(path: photo.path)
        SecurityScopeManager.shared.ensureAccess(forPath: photo.path, rootID: photo.rootID, catalog: catalog)
        let source = photo.url
        guard fm.fileExists(atPath: source.path) else {
            return device.isOnline(mounted: mounted) ? .missing : .notConnected(device.title)
        }
        let rootPath = roots.first { $0.id == photo.rootID }?.path ?? Catalog.coveringRoot(for: photo.path, in: roots)?.path
        let dir = options.destination.appendingPathComponent(options.layout.subpath(for: photo, rootPath: rootPath), isDirectory: true)
        var target = dir.appendingPathComponent(source.lastPathComponent)
        if Catalog.normalizedPath(target.path) == Catalog.normalizedPath(source.path) || Self.sameFile(source, target) {
            return .alreadyThere
        }
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            throw ImportError.isPermission(error) ? ImportError.noWriteAccess(dir.path) : error
        }
        let sidecar = photo.sidecarURL.flatMap { fm.fileExists(atPath: $0.path) ? $0 : nil }

        var created: [URL] = []
        var done = false
        defer { if !done { for url in created { try? fm.removeItem(at: url) } } }

        var adopt = false
        if fm.fileExists(atPath: target.path) {
            if try Self.sameContents(source, target) {
                if let other = try catalog.photoID(path: target.path), other != photo.id { return .duplicate(target.path) }
                adopt = true
            } else {
                let extensions = [source.pathExtension] + (sidecar.map { [$0.pathExtension] } ?? [])
                let base = ImportFiles.uniqueBaseName(source.deletingPathExtension().lastPathComponent, extensions: extensions, in: dir)
                target = dir.appendingPathComponent(base).appendingPathExtension(source.pathExtension)
            }
        }
        if !adopt {
            _ = try ImportFiles.copy(source, to: target, isCancelled: { isCancelled }, onBytes: onBytes)
            created.append(target)
            guard try Self.sameContents(source, target) else { return .failed("the copy doesn't match the original") }
        }

        var sidecarTarget: URL?
        if let sidecar {
            let t = target.deletingPathExtension().appendingPathExtension(sidecar.pathExtension)
            if Self.sameFile(sidecar, t) { return .alreadyThere }
            if fm.fileExists(atPath: t.path) {
                guard try Self.sameContents(sidecar, t) else { return .failed("“\(t.lastPathComponent)” already exists in \(dir.path)") }
            } else {
                _ = try ImportFiles.copy(sidecar, to: t, isCancelled: { isCancelled })
                created.append(t)
                guard try Self.sameContents(sidecar, t) else { return .failed("the copy of \(sidecar.lastPathComponent) doesn't match it") }
            }
            sidecarTarget = t
        }

        try catalog.relocatePhotos([PhotoRelocation(photoID: photo.id, path: target.path,
                                                    sidecarPath: sidecarTarget?.path ?? photo.sidecarPath)], notify: false)
        done = true
        result.moved.append(photo.id)
        result.targets.append(target)
        result.bytes += photo.fileSize

        if options.trashOriginals {
            for url in [source] + (sidecar.map { [$0] } ?? []) {
                do {
                    try trashItem(url)
                    result.trashed += 1
                } catch {
                    result.trashFailures.append(url.lastPathComponent)
                }
            }
        }
        return nil
    }

    // MARK: - Files

    /// Same file on disk (device + inode): e.g. a case-only difference on a case-insensitive volume.
    /// Trashing the "original" would then trash the copy.
    static func sameFile(_ a: URL, _ b: URL) -> Bool {
        var sa = stat(), sb = stat()
        guard stat(a.path, &sa) == 0, stat(b.path, &sb) == 0 else { return false }
        return sa.st_dev == sb.st_dev && sa.st_ino == sb.st_ino
    }

    /// Byte-for-byte comparison (uncached reads, so the copy is really read back from its disk).
    static func sameContents(_ a: URL, _ b: URL) throws -> Bool {
        let fa = open(a.path, O_RDONLY)
        guard fa >= 0 else { throw DeviceMoveError.read(a.lastPathComponent, errno) }
        defer { close(fa) }
        let fb = open(b.path, O_RDONLY)
        guard fb >= 0 else { throw DeviceMoveError.read(b.lastPathComponent, errno) }
        defer { close(fb) }
        _ = fcntl(fa, F_NOCACHE, 1)
        _ = fcntl(fb, F_NOCACHE, 1)
        var sa = stat(), sb = stat()
        guard fstat(fa, &sa) == 0, fstat(fb, &sb) == 0 else { throw DeviceMoveError.read(a.lastPathComponent, errno) }
        if sa.st_size != sb.st_size { return false }

        let chunk = 8 << 20
        let ba = UnsafeMutableRawPointer.allocate(byteCount: chunk, alignment: 16384)
        let bb = UnsafeMutableRawPointer.allocate(byteCount: chunk, alignment: 16384)
        defer { ba.deallocate(); bb.deallocate() }
        func readFully(_ fd: Int32, _ buffer: UnsafeMutableRawPointer, _ name: String) throws -> Int {
            var got = 0
            while got < chunk {
                let n = read(fd, buffer + got, chunk - got)
                if n < 0 { throw DeviceMoveError.read(name, errno) }
                if n == 0 { break }
                got += n
            }
            return got
        }
        while true {
            let na = try readFully(fa, ba, a.lastPathComponent)
            let nb = try readFully(fb, bb, b.lastPathComponent)
            if na != nb || memcmp(ba, bb, na) != 0 { return false }
            if na < chunk { return true }
        }
    }
}
