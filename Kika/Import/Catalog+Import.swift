//
//  Catalog+Import.swift
//  Kika
//
//  Catalog queries used by the SD card / folder importer.
//

import Foundation

nonisolated struct ImportFingerprint: Sendable, Hashable {
    var id: Int64
    var path: String
    var fileName: String
    var fileSize: Int64
    var captureDate: Date?
}

/// `replaceImportedPhoto`: the new path already belongs to another photo.
nonisolated struct ImportPathTakenError: LocalizedError, CustomStringConvertible {
    var path: String
    var description: String { "Another photo in the catalog is already at “\(path)”." }
    var errorDescription: String? { description }
}

nonisolated extension Catalog {
    /// Path, file name, size and capture date of every photo (for duplicate detection). Masters
    /// only: virtual copies share their master's file.
    func importFingerprints() throws -> [ImportFingerprint] {
        try db.query("SELECT id, path, file_name, file_size, capture_date FROM photos WHERE master_id IS NULL", []) {
            ImportFingerprint(id: $0.int(0), path: $0.string(1), fileName: $0.string(2), fileSize: $0.int(3), captureDate: $0.date(4))
        }
    }

    /// Import with "Replace": points the master `id` (and its virtual copies, which share its file)
    /// at `photo`'s file and refreshes the file metadata and import date. Edits, flags, ratings and
    /// folders stay. Throws if another photo already has `photo.path`.
    func replaceImportedPhoto(id: Int64, with photo: Photo) throws {
        try db.transaction {
            if let other = try photoID(path: photo.path), other != id {
                throw ImportPathTakenError(path: photo.path)
            }
            let roots = try allRoots()
            let rootID = photo.rootID ?? Self.coveringRoot(for: photo.path, in: roots)?.id
            try db.run("""
                UPDATE photos SET path = ?, root_id = ?, file_name = ?, file_size = ?, capture_date = ?, import_date = ?,
                    width = ?, height = ?, orientation = ?, camera_make = ?, camera_model = ?, lens = ?, iso = ?,
                    shutter = ?, aperture = ?, focal_length = ?, sidecar_path = ?
                WHERE id = ? OR master_id = ?
                """, [
                    photo.path, rootID, photo.fileName, photo.fileSize, photo.captureDate, photo.importDate,
                    photo.width, photo.height, photo.orientation, photo.cameraMake, photo.cameraModel, photo.lens, photo.iso,
                    photo.shutter, photo.aperture, photo.focalLength, photo.sidecarPath, id, id,
                ])
        }
        postChange(.photosInsertedOrRemoved)   // import date changed: Previous Import must reload
    }
}
