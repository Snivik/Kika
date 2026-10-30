//
//  devices_check.swift
//  Headless test of devices: path → device, the device filter, folders per device, relocating photos
//  and the Move to Device job (copy, verify, catalog update, name conflicts, identical files, duplicates,
//  same-file guard, trash, missing files, cancel).
//
//    Tools/harness.sh /private/tmp/claude-501/out-devices/devices_check Tools/devices_check.swift \
//        Kika/Devices/Catalog+Devices.swift Kika/Devices/DeviceMove.swift Kika/Import/ImportEngine.swift Kika/Import/Catalog+Import.swift \
//        Kika/VirtualCopies/Catalog+VirtualCopies.swift
//    /private/tmp/claude-501/out-devices/devices_check [out-dir]
//
//  Uses synthetic files (random bytes) in out-dir; "devices" are folders there (a harness can't mount
//  volumes), the device filter is tested on catalogued /Volumes paths without files.
//

import Foundation

@main
struct DevicesCheck {
    nonisolated(unsafe) static var failures = 0

    static func check(_ ok: Bool, _ what: String) {
        print(ok ? "  PASS" : "  FAIL", what)
        if !ok { failures += 1 }
    }

    static func main() async throws {
        let args = CommandLine.arguments
        let outDir = URL(fileURLWithPath: args.count > 1 ? args[1] : "/private/tmp/claude-501/out-devices")
        let dir = outDir.appendingPathComponent("devices-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        try deviceModel(dir)
        try moveJob(dir)

        print(failures == 0 ? "ALL PASS" : "\(failures) FAILURE(S)")
        if failures > 0 { exit(1) }
    }

    // MARK: - Devices, filter, folders

    static func deviceModel(_ dir: URL) throws {
        print("Devices")
        check(PhotoDevice(path: "/Users/me/Pictures/a.RW2") == .thisMac, "home folder → This Mac")
        check(PhotoDevice(path: "/private/tmp/a.RW2") == .thisMac, "/private/tmp → This Mac")
        check(PhotoDevice(path: "/Volumes/T9/Lightroom/a.RW2") == .volume("T9"), "/Volumes/T9/… → T9")
        check(PhotoDevice(path: "/Volumes/My Drive/a.RW2") == .volume("My Drive"), "volume names with spaces")
        check([PhotoDevice.volume("b"), .volume("A"), .thisMac].sorted() == [.thisMac, .volume("A"), .volume("b")], "This Mac first, then by name")

        let catalog = try Catalog.open(at: dir.appendingPathComponent("filter-catalog"))
        let paths = ["/Users/me/Pictures/1.RW2", "/Users/me/Pictures/2.RW2",
                     "/Volumes/T9/2026/3.RW2", "/Volumes/T9/2026/4.RW2", "/Volumes/T9/5.RW2",
                     "/Volumes/T90/6.RW2",            // prefix trap: not T9
                     "/Volumes/T9 2/7.RW2",           // nor this
                     "/Volumes/NAS/Photos/8.RW2"]
        let ids = try catalog.insertPhotos(paths.enumerated().map { i, path in
            var p = Photo(path: path)
            p.fileSize = Int64(100 * (i + 1))
            return p
        })
        _ = try catalog.createVirtualCopies(of: [ids[2]])   // copies aren't counted as files

        let summaries = try catalog.deviceSummaries()
        check(summaries.map(\.device) == [.thisMac, .volume("NAS"), .volume("T9"), .volume("T9 2"), .volume("T90")], "summaries: devices in order, got \(summaries.map(\.device.title))")
        let t9 = summaries.first { $0.device == .volume("T9") }
        check(t9?.photoCount == 3 && t9?.bytes == 300 + 400 + 500, "summaries: T9 counts files (masters) and bytes")

        func shown(_ device: PhotoDevice?) throws -> Set<String> {
            Set(try catalog.photos(in: .all, filter: PhotoFilter(device: device)).filter { !$0.isVirtualCopy }.map(\.path))
        }
        check(try shown(.volume("T9")) == Set(paths[2...4]), "filter T9: only T9, not T90 / T9 2")
        check(try shown(.thisMac) == Set(paths[0...1]), "filter This Mac")
        check(try shown(.volume("NAS")) == [paths[7]], "filter NAS")
        check(try catalog.photos(in: .all, filter: PhotoFilter(device: .volume("T9"))).count == 4, "filter keeps virtual copies of matching masters")
        check(try shown(nil).count == paths.count, "no device filter: everything")

        let trips = try catalog.createFolder(name: "Trips")
        let italy = try catalog.createFolder(name: "Italy", parentID: trips)
        let home = try catalog.createFolder(name: "Home")
        try catalog.addPhotos([ids[2], ids[0]], toFolder: italy)
        try catalog.addPhotos([ids[1]], toFolder: home)
        let byDevice = try catalog.folderIDsByDevice()
        check(byDevice[.volume("T9")] == [italy] && byDevice[.thisMac] == [italy, home], "folders per device (direct photos)")
        check(byDevice[.volume("NAS")] == nil, "a device with no foldered photos has no folders")

        print("Relocate")
        let copies = try catalog.virtualCopyIDs(ofMasters: [ids[2]])
        try catalog.relocatePhotos([PhotoRelocation(photoID: ids[2], path: "/Volumes/NAS/Photos/3.RW2", sidecarPath: nil)])
        check(try catalog.photo(id: ids[2])?.path == "/Volumes/NAS/Photos/3.RW2", "master relocated")
        check(try catalog.photos(ids: Array(copies)).allSatisfy { $0.path == "/Volumes/NAS/Photos/3.RW2" && $0.fileName == "3.RW2" }, "virtual copies follow their master")
        var refused = false
        do { try catalog.relocatePhotos([PhotoRelocation(photoID: ids[3], path: paths[7], sidecarPath: nil)]) } catch RelocateError.pathInUse { refused = true }
        check(try refused && catalog.photo(id: ids[3])?.path == paths[3], "relocating onto another master's path is refused, nothing changes")
        let root = try catalog.upsertRoot(path: "/Volumes/NAS/Photos", bookmark: nil)
        try catalog.relocatePhotos([PhotoRelocation(photoID: ids[4], path: "/Volumes/NAS/Photos/5.RW2", sidecarPath: nil)])
        check(try catalog.photo(id: ids[4])?.rootID == root, "relocated photo gets its covering root")
    }

    // MARK: - Move job

    static func write(_ url: URL, bytes: Int = 50_000, seed: UInt8) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var data = Data(count: bytes)
        data.withUnsafeMutableBytes { b in for i in 0..<bytes { b[i] = UInt8(truncatingIfNeeded: i &* 31) &+ seed } }
        try data.write(to: url)
    }

    static func moveJob(_ dir: URL) throws {
        print("Move to Device")
        let fm = FileManager.default
        let laptop = dir.appendingPathComponent("Laptop/Pictures")
        let drive = dir.appendingPathComponent("Drive/Photos")
        try fm.createDirectory(at: drive, withIntermediateDirectories: true)
        let catalog = try Catalog.open(at: dir.appendingPathComponent("move-catalog"))
        _ = try catalog.upsertRoot(path: laptop.path, bookmark: nil)
        let driveRoot = try catalog.upsertRoot(path: drive.path, bookmark: nil)

        let day = DateComponents(calendar: .current, year: 2026, month: 10, day: 21, hour: 12).date!
        func add(_ rel: String, seed: UInt8, sidecar: Bool = false, size: Int = 50_000) throws -> Int64 {
            let url = laptop.appendingPathComponent(rel)
            try write(url, bytes: size, seed: seed)
            var p = Photo(path: url.path)
            p.fileSize = Int64(size)
            p.captureDate = day
            if sidecar {
                let jpg = url.deletingPathExtension().appendingPathExtension("JPG")
                try write(jpg, bytes: 3_000, seed: seed &+ 100)
                p.sidecarPath = jpg.path
            }
            return try catalog.insertPhoto(p)
        }
        let a = try add("Trip/Day 1/A.RW2", seed: 1, sidecar: true)
        let b = try add("Trip/Day 1/B.RW2", seed: 2)
        let c = try add("Trip/C.RW2", seed: 3)
        let missing = try add("Trip/Gone.RW2", seed: 4)
        try fm.removeItem(atPath: try catalog.photo(id: missing)!.path)

        var settings = EditSettings()
        settings.tone.exposure = 0.7
        let version = try catalog.saveEditSettings(settings, for: a)
        try catalog.setRating(4, for: [a])
        let folder = try catalog.createFolder(name: "Trip")
        try catalog.addPhotos([a, b, c], toFolder: folder)
        let copy = try catalog.createVirtualCopies(of: [a])[0].id

        // A different file named B.RW2 already in the date folder → B-1.RW2.
        let dated = drive.appendingPathComponent("2026/2026-10-21")
        try write(dated.appendingPathComponent("B.RW2"), seed: 99)

        let trashed = TrashLog()
        let job = DeviceMoveJob(catalog: catalog, photoIDs: [copy, b, missing],   // the copy stands for A
                                options: DeviceMoveOptions(destination: drive, layout: .yearAndDay, trashOriginals: true))
        job.trashItem = { url in trashed.add(url.lastPathComponent); try FileManager.default.removeItem(at: url) }
        var last = DeviceMoveProgress()
        let result = job.run { last = $0 }

        check(Set(result.moved) == [a, b], "moved A (via its virtual copy) and B, got \(result.moved)")
        check(result.updatedPhotoIDs == [a, b, copy], "updated ids include the virtual copy")
        check(result.skipped.map(\.photoID) == [missing] && result.skipped.first?.reason == .missing, "missing file skipped as missing")
        check(last.done == 3 && last.total == 3, "progress reaches the end")
        let pa = try catalog.photo(id: a)!, pb = try catalog.photo(id: b)!, pc = try catalog.photo(id: copy)!
        check(pa.path == dated.appendingPathComponent("A.RW2").path, "A in the date folder")
        check(pa.sidecarPath == dated.appendingPathComponent("A.JPG").path && fm.fileExists(atPath: pa.sidecarPath!), "sidecar moved next to it")
        check(pb.path == dated.appendingPathComponent("B-1.RW2").path && pb.fileName == "B-1.RW2", "name conflict with a different file → B-1")
        check(try DeviceMoveJob.sameContents(URL(fileURLWithPath: pb.path), dated.appendingPathComponent("B.RW2")) == false, "the other B.RW2 is untouched")
        check(pa.rootID == driveRoot && pb.rootID == driveRoot, "moved photos use the drive's root")
        check(pa.editVersion == version && pa.editSettings.tone.exposure == 0.7 && pa.rating == 4, "edits, edit version and rating kept")
        check(pc.path == pa.path && pc.isVirtualCopy, "virtual copy points at the moved file")
        check(try Set(catalog.folderIDs(containing: a)) == [folder], "folder membership kept")
        check(trashed.names == ["A.RW2", "A.JPG", "B.RW2"] && result.trashed == 3, "originals + sidecar trashed after the copy, got \(trashed.names)")
        check(!fm.fileExists(atPath: laptop.appendingPathComponent("Trip/Day 1/A.RW2").path), "original gone")
        check(fm.fileExists(atPath: laptop.appendingPathComponent("Trip/C.RW2").path), "photos not asked for stay")
        check(try catalog.photos(in: .all, filter: PhotoFilter(device: .thisMac)).count == 5, "harness paths are all This Mac")

        print("Same folders, identical files, duplicates, same file")
        // C: an identical file is already at its target (an interrupted move) → used, not copied again.
        let mirror = dir.appendingPathComponent("Drive/Mirror")
        try fm.createDirectory(at: mirror.appendingPathComponent("Trip"), withIntermediateDirectories: true)
        try fm.copyItem(atPath: try catalog.photo(id: c)!.path, toPath: mirror.appendingPathComponent("Trip/C.RW2").path)
        let keep = DeviceMoveJob(catalog: catalog, photoIDs: [c], options: DeviceMoveOptions(destination: mirror, layout: .sameFolders))
        let r2 = keep.run { _ in }
        check(try r2.moved == [c] && catalog.photo(id: c)?.path == mirror.appendingPathComponent("Trip/C.RW2").path, "same folders: Trip/C.RW2, identical file adopted")
        check(fm.fileExists(atPath: laptop.appendingPathComponent("Trip/C.RW2").path), "without Trash the original stays")

        // A duplicate: another master is catalogued at the identical target → skipped, nothing changes.
        let d = try add("Dup/D.RW2", seed: 5)
        let dupTarget = mirror.appendingPathComponent("D.RW2")
        try fm.copyItem(atPath: try catalog.photo(id: d)!.path, toPath: dupTarget.path)
        var other = Photo(path: dupTarget.path)
        other.fileSize = 50_000
        _ = try catalog.insertPhoto(other)
        let r3 = DeviceMoveJob(catalog: catalog, photoIDs: [d], options: DeviceMoveOptions(destination: mirror, layout: .flat, trashOriginals: true)).run { _ in }
        if case .duplicate? = r3.skipped.first?.reason { check(r3.moved.isEmpty, "duplicate in the catalog: skipped") } else { check(false, "duplicate in the catalog: skipped, got \(r3.skipped.map(\.reason))") }
        check(fm.fileExists(atPath: try catalog.photo(id: d)!.path), "duplicate's original not trashed")

        // Same file under another spelling (case-insensitive volume): never "adopt" and trash it.
        let e = try add("Case/E.RW2", seed: 6)
        let lower = URL(fileURLWithPath: laptop.path.replacingOccurrences(of: "/Laptop/", with: "/laptop/")).appendingPathComponent("Case")
        let r4 = DeviceMoveJob(catalog: catalog, photoIDs: [e], options: DeviceMoveOptions(destination: lower, layout: .flat, trashOriginals: true)).run { _ in }
        check(r4.skipped.first?.reason == .alreadyThere && r4.trashed == 0, "same file (case-only path difference) → already there, not trashed")
        check(fm.fileExists(atPath: try catalog.photo(id: e)!.path), "its file is intact")

        print("Cancel and stop")
        let big = try add("Big/F.RW2", seed: 7, size: 24 << 20)
        let g = try add("Big/G.RW2", seed: 8)
        let cancelJob = DeviceMoveJob(catalog: catalog, photoIDs: [big, g], options: DeviceMoveOptions(destination: drive, layout: .flat))
        let r5 = cancelJob.run { p in if p.bytesDone > 0 { cancelJob.cancel() } }
        check(r5.wasCancelled && r5.moved.isEmpty, "cancel during a copy stops")
        check(!fm.fileExists(atPath: drive.appendingPathComponent("F.RW2").path) && !fm.fileExists(atPath: drive.appendingPathComponent("F.RW2.tmp").path), "no partial file left")
        check(try catalog.photo(id: big)?.path == laptop.appendingPathComponent("Big/F.RW2").path, "cancelled photo still points at its original")

        let gone = DeviceMoveJob(catalog: catalog, photoIDs: [g], options: DeviceMoveOptions(destination: dir.appendingPathComponent("Unplugged"))).run { _ in }
        check(gone.stopError != nil && gone.moved.isEmpty, "destination not available → stops with a message")

        print("Layouts")
        var p = Photo(path: "/Volumes/T9/Lightroom/Trip/Day 1/X.RW2")
        p.captureDate = day
        check(DeviceMoveLayout.yearAndDay.subpath(for: p, rootPath: nil) == "2026/2026-10-21", "year and day")
        check(DeviceMoveLayout.day.subpath(for: p, rootPath: nil) == "2026-10-21", "day")
        check(DeviceMoveLayout.sameFolders.subpath(for: p, rootPath: "/Volumes/T9/Lightroom") == "Trip/Day 1", "same folders below the root")
        check(DeviceMoveLayout.sameFolders.subpath(for: p, rootPath: "/Volumes/T9/Lightroom/Trip/Day 1") == "", "file at the root → destination itself")
        check(DeviceMoveLayout.sameFolders.subpath(for: p, rootPath: nil) == "Day 1", "no root → the file's folder name")
        p.captureDate = nil
        p.importDate = DateComponents(calendar: .current, year: 2025, month: 1, day: 2, hour: 12).date!
        check(DeviceMoveLayout.yearAndDay.subpath(for: p, rootPath: nil) == "2025/2025-01-02", "no capture date → import date")
    }
}

final class TrashLog: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var names: [String] = []
    func add(_ name: String) { lock.lock(); names.append(name); lock.unlock() }
}
