//
//  Catalog+Devices.swift
//  Kika
//
//  Devices (PhotoDevice.swift) in the catalog: photos per device, the folders holding photos on each
//  device (folder filter), and relocating photos after their files were copied to another place
//  (Move to Device: DeviceMove.swift). The device filter of `photos(in:filter:sort:)` is `PhotoFilter.device`.
//

import Foundation

nonisolated enum RelocateError: Error, CustomStringConvertible {
    case pathInUse(String)

    var description: String {
        switch self {
        case .pathInUse(let path): "Another photo in the catalog is already at “\(path)”."
        }
    }
}

/// New location of a master photo's file (and sidecar). Its virtual copies follow.
nonisolated struct PhotoRelocation: Hashable, Sendable {
    var photoID: Int64
    var path: String
    var sidecarPath: String?
}

nonisolated extension Catalog {
    /// Every device holding catalogued files, This Mac first.
    func deviceSummaries() throws -> [DeviceSummary] {
        try db.query("""
            SELECT \(PhotoDevice.sqlVolumeName(column: "path")) AS vol, COUNT(*), COALESCE(SUM(file_size), 0)
            FROM photos WHERE master_id IS NULL GROUP BY vol
            """) { r in
            DeviceSummary(device: r.stringOrNil(0).map(PhotoDevice.volume) ?? .thisMac, photoCount: Int(r.int(1)), bytes: r.int(2))
        }.sorted { $0.device < $1.device }
    }

    /// Folders that directly hold at least one photo on each device.
    func folderIDsByDevice() throws -> [PhotoDevice: Set<Int64>] {
        let rows = try db.query("""
            SELECT DISTINCT fp.folder_id, \(PhotoDevice.sqlVolumeName(column: "p.path"))
            FROM folder_photos fp JOIN photos p ON p.id = fp.photo_id
            """) { ($0.int(0), $0.stringOrNil(1).map(PhotoDevice.volume) ?? PhotoDevice.thisMac) }
        var result: [PhotoDevice: Set<Int64>] = [:]
        for (folder, device) in rows { result[device, default: []].insert(folder) }
        return result
    }

    /// Points master photos (and their virtual copies) at their files' new places: path, file name,
    /// sidecar and covering root, one transaction. Refuses a path another master already has.
    /// Posts `.roots` (paths and root ids changed, like Relink) unless `notify` is false.
    func relocatePhotos(_ moves: [PhotoRelocation], notify: Bool = true) throws {
        guard !moves.isEmpty else { return }
        try db.transaction {
            let roots = try allRoots()
            for move in moves {
                if try db.scalarInt("SELECT id FROM photos WHERE path = ? AND master_id IS NULL AND id != ?", [move.path, move.photoID]) != nil {
                    throw RelocateError.pathInUse(move.path)
                }
                try db.run("""
                    UPDATE photos SET path = ?, file_name = ?, sidecar_path = ?, root_id = ?
                    WHERE id = ? OR master_id = ?
                    """, [move.path, (move.path as NSString).lastPathComponent, move.sidecarPath,
                          Self.coveringRoot(for: move.path, in: roots)?.id, move.photoID, move.photoID])
            }
        }
        if notify { postChange(.roots) }
    }
}
