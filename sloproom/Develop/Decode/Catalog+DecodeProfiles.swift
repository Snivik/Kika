//
//  Catalog+DecodeProfiles.swift
//  sloproom
//
//  Decode profiles in the catalog:
//    decode_profiles(id, name, camera_make, camera_model, params JSON, notes, sort_order, created_at, updated_at)
//    decode_defaults(camera_make, camera_model, profile_id)   — ('', '') = the global default
//
//  Every mutation reloads `DecodeProfileRegistry.shared`, bumps `edit_version` of the edited RAW
//  photos whose resolved decode actually changed (their cached previews regenerate) and posts
//  `.decodeProfiles` (+ `.photosUpdated` for those photos). Unedited photos need nothing: their
//  thumbnails are the camera JPEG and Develop resolves live.
//

import Foundation

nonisolated extension Catalog {
    /// Creates the tables and seeds the starter profiles (once per catalog). Cheap; idempotent.
    func ensureDecodeProfiles() throws {
        try applyMigration(named: "decode.profiles.v1", sql: """
            CREATE TABLE decode_profiles(
                id INTEGER PRIMARY KEY,
                name TEXT NOT NULL,
                camera_make TEXT NULL,
                camera_model TEXT NULL,
                params TEXT NOT NULL DEFAULT '{}',
                notes TEXT NOT NULL DEFAULT '',
                sort_order INTEGER NOT NULL DEFAULT 0,
                created_at REAL NOT NULL DEFAULT 0,
                updated_at REAL NOT NULL DEFAULT 0
            );
            CREATE TABLE decode_defaults(
                camera_make TEXT NOT NULL DEFAULT '',
                camera_model TEXT NOT NULL DEFAULT '',
                profile_id INTEGER NOT NULL REFERENCES decode_profiles(id) ON DELETE CASCADE,
                PRIMARY KEY (camera_make, camera_model)
            );
            """)
        let now = Date().timeIntervalSince1970
        try applyMigration(named: "decode.profiles.seed.v1", sql: """
            INSERT INTO decode_profiles(name, params, notes, sort_order, created_at, updated_at) VALUES
            ('Flat for Editing', '{"boost":0}', 'Apple''s base curve off: linear, low-contrast start for heavy editing.', 0, \(now), \(now)),
            ('Clean High ISO', '{"colorNoiseReduction":0.9,"luminanceNoiseReduction":0.8,"sharpness":0.6}', 'Stronger noise reduction, softer sharpening.', 1, \(now), \(now)),
            ('Maximum Detail', '{"colorNoiseReduction":0.25,"detail":0.5,"luminanceNoiseReduction":0,"moireReduction":0,"sharpness":1}', 'No luminance noise reduction or moiré suppression: every bit of fine detail (and noise).', 2, \(now), \(now)),
            ('Previous Highlights (before Oct 2026)', '{"highlightNeutralEnd":0.75,"highlightNeutralStart":0.2}', 'How Sloproom handled bright highlights before the decode profiles: bright saturated colours (sunset skin) fade towards white.', 3, \(now), \(now));
            """)
    }

    // MARK: Reading

    func allDecodeProfiles() throws -> [DecodeProfile] {
        try db.query("SELECT id, name, camera_make, camera_model, params, notes, sort_order FROM decode_profiles ORDER BY sort_order, id") {
            let camera = CameraKey(make: $0.stringOrNil(2), model: $0.stringOrNil(3))
            return DecodeProfile(id: $0.int(0), name: $0.string(1), params: Self.decodeParams($0.string(4)),
                                 camera: camera.isEmpty ? nil : camera, sortOrder: Int($0.int(6)), notes: $0.string(5))
        }
    }

    /// Global default (nil = built-in) and camera defaults.
    func decodeDefaults() throws -> (global: Int64?, cameras: [CameraKey: Int64]) {
        var global: Int64?
        var cameras: [CameraKey: Int64] = [:]
        try db.query("SELECT camera_make, camera_model, profile_id FROM decode_defaults") { r in
            let key = CameraKey(make: r.string(0), model: r.string(1))
            if key.isEmpty { global = r.int(2) } else { cameras[key] = r.int(2) }
        }
        return (global, cameras)
    }

    /// Cameras in the catalog (master photos only) with their photo counts, most used first.
    func decodeCameras() throws -> [(camera: CameraKey, count: Int)] {
        try db.query("""
            SELECT camera_make, camera_model, COUNT(*) FROM photos
            WHERE master_id IS NULL AND (camera_make IS NOT NULL OR camera_model IS NOT NULL)
            GROUP BY camera_make, camera_model ORDER BY COUNT(*) DESC
            """) { (CameraKey(make: $0.stringOrNil(0), model: $0.stringOrNil(1)), Int($0.int(2))) }
            .filter { !$0.camera.isEmpty }
    }

    /// Loads profiles + defaults into `DecodeProfileRegistry.shared` (creating the tables if needed).
    func reloadDecodeRegistry() throws {
        try ensureDecodeProfiles()
        let profiles = try allDecodeProfiles()
        let defaults = try decodeDefaults()
        DecodeProfileRegistry.shared.replace(profiles: profiles, globalDefault: defaults.global, cameraDefaults: defaults.cameras)
    }

    /// Edited photos (incl. virtual copies) whose decode chain goes through `profileID`.
    func photosUsingDecodeProfile(_ profileID: Int64) throws -> [Int64] {
        try editedRAWDecodeRows().filter {
            DecodeProfileRegistry.shared.chainProfileIDs($0.decode, camera: $0.camera).contains(profileID)
        }.map(\.id)
    }

    // MARK: Writing

    @discardableResult
    func createDecodeProfile(name: String, params: DecodeParams, camera: CameraKey? = nil, notes: String = "") throws -> Int64 {
        try mutateDecodeProfiles {
            let next = try db.scalarInt("SELECT COALESCE(MAX(sort_order) + 1, 0) FROM decode_profiles") ?? 0
            let now = Date()
            try db.run("""
                INSERT INTO decode_profiles(name, camera_make, camera_model, params, notes, sort_order, created_at, updated_at)
                VALUES (?,?,?,?,?,?,?,?)
                """, [name, camera?.make, camera?.model, DecodeProfileRegistry.json(params), notes, next, now, now])
            return db.lastInsertRowID
        }
    }

    func updateDecodeProfile(_ profile: DecodeProfile) throws {
        try mutateDecodeProfiles {
            try db.run("""
                UPDATE decode_profiles SET name = ?, camera_make = ?, camera_model = ?, params = ?, notes = ?, sort_order = ?, updated_at = ?
                WHERE id = ?
                """, [profile.name, profile.camera?.make, profile.camera?.model, DecodeProfileRegistry.json(profile.params),
                      profile.notes, profile.sortOrder, Date(), profile.id])
        }
    }

    /// Deletes a profile; defaults pointing at it go too. Photos that chose it lose the reference
    /// (cleared here, since SQLite may reuse the highest id) and fall back to the global / camera defaults.
    func deleteDecodeProfile(id: Int64) throws {
        try mutateDecodeProfiles {
            try db.run("DELETE FROM decode_defaults WHERE profile_id = ?", [id])
            try db.run("DELETE FROM decode_profiles WHERE id = ?", [id])
            try clearDecodeProfileReferences(id)
        }
    }

    @discardableResult
    func duplicateDecodeProfile(id: Int64) throws -> Int64? {
        guard let p = try allDecodeProfiles().first(where: { $0.id == id }) else { return nil }
        return try createDecodeProfile(name: uniqueDecodeProfileName(p.name + " Copy"), params: p.params, camera: p.camera, notes: p.notes)
    }

    func setGlobalDecodeDefault(_ profileID: Int64?) throws {
        try setDecodeDefault(CameraKey(make: "", model: ""), profileID)
    }

    func setCameraDecodeDefault(_ camera: CameraKey, profileID: Int64?) throws {
        guard !camera.isEmpty else { return }
        try setDecodeDefault(camera, profileID)
    }

    /// Imports every profile of a `.sloproomdecode` file (names made unique). Returns the new ids.
    @discardableResult
    func importDecodeProfiles(_ file: DecodeProfileFile) throws -> [Int64] {
        try db.transaction {
            try file.profiles.map { e in
                let cam = CameraKey(make: e.cameraMake, model: e.cameraModel)
                return try createDecodeProfile(name: try uniqueDecodeProfileName(e.name), params: e.params,
                                               camera: cam.isEmpty ? nil : cam, notes: e.notes ?? "")
            }
        }
    }

    func uniqueDecodeProfileName(_ base: String) throws -> String {
        let names = Set(try allDecodeProfiles().map { $0.name.lowercased() })
        let trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        let start = trimmed.isEmpty ? "Profile" : trimmed
        if !names.contains(start.lowercased()) { return start }
        var n = 2
        while names.contains("\(start) \(n)".lowercased()) { n += 1 }
        return "\(start) \(n)"
    }

    // MARK: - Private

    private func setDecodeDefault(_ key: CameraKey, _ profileID: Int64?) throws {
        try mutateDecodeProfiles {
            if let profileID {
                try db.run("INSERT OR REPLACE INTO decode_defaults(camera_make, camera_model, profile_id) VALUES (?,?,?)",
                           [key.make, key.model, profileID])
            } else {
                try db.run("DELETE FROM decode_defaults WHERE camera_make = ? AND camera_model = ?", [key.make, key.model])
            }
        }
    }

    /// Runs a profile mutation, reloads the registry and invalidates the photos whose resolved
    /// decode changed (comparing each photo's old settings under the old profiles with its new
    /// settings under the new ones).
    @discardableResult
    private func mutateDecodeProfiles<T>(_ body: () throws -> T) throws -> T {
        try ensureDecodeProfiles()
        let (value, changed): (T, [Int64]) = try db.transaction {
            let before = DecodeProfileRegistry.shared.snapshot()
            let rowsBefore = Dictionary(try editedRAWDecodeRows().map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            let value = try body()
            try reloadDecodeRegistry()
            let after = DecodeProfileRegistry.shared
            let changed = try editedRAWDecodeRows().filter { row in
                guard let old = rowsBefore[row.id] else { return false }
                return before.resolve(old.decode, camera: old.camera).params != after.resolve(row.decode, camera: row.camera).params
            }.map(\.id)
            for chunk in stride(from: 0, to: changed.count, by: 500).map({ Array(changed[$0..<min($0 + 500, changed.count)]) }) {
                let marks = chunk.map { _ in "?" }.joined(separator: ",")
                try db.run("UPDATE photos SET edit_version = edit_version + 1 WHERE id IN (\(marks))", chunk)
            }
            return (value, changed)
        }
        if !changed.isEmpty { postChange(.photosUpdated(Set(changed))) }
        postChange(.decodeProfiles)
        return value
    }

    private func clearDecodeProfileReferences(_ id: Int64) throws {
        let rows = try db.query("""
            SELECT id, edit_settings FROM photos
            WHERE edit_settings IS NOT NULL AND json_extract(edit_settings, '$.decode.profileID') = ?
            """, [id]) { ($0.int(0), $0.string(1)) }
        for (photoID, json) in rows {
            guard var settings = EditSettings.fromJSON(json) else { continue }
            settings.decode.profileID = nil
            try db.run("UPDATE photos SET edit_settings = ? WHERE id = ?", [settings.isEmpty ? nil : settings.jsonString(), photoID])
        }
    }

    /// (id, camera, decode section) of every edited RAW photo.
    private func editedRAWDecodeRows() throws -> [(id: Int64, camera: CameraKey?, decode: DecodeSettings)] {
        try db.query("""
            SELECT id, path, camera_make, camera_model, json_extract(edit_settings, '$.decode') FROM photos
            WHERE edit_settings IS NOT NULL
            """) { r -> (Int64, CameraKey?, DecodeSettings)? in
            guard RenderPipeline.isRAW(url: URL(fileURLWithPath: r.string(1))) else { return nil }
            let cam = CameraKey(make: r.stringOrNil(2), model: r.stringOrNil(3))
            let decode = r.stringOrNil(4).flatMap { $0.data(using: .utf8) }
                .flatMap { try? JSONDecoder().decode(DecodeSettings.self, from: $0) } ?? DecodeSettings()
            return (r.int(0), cam.isEmpty ? nil : cam, decode)
        }.compactMap { $0 }
    }

    private static func decodeParams(_ json: String) -> DecodeParams {
        json.data(using: .utf8).flatMap { try? JSONDecoder().decode(DecodeParams.self, from: $0) } ?? DecodeParams()
    }
}

nonisolated extension DecodeProfileRegistry {
    /// An independent copy of the current state (to compare before / after a change).
    func snapshot() -> DecodeProfileRegistry {
        let copy = DecodeProfileRegistry()
        copy.replace(profiles: profiles, globalDefault: globalDefault?.id, cameraDefaults: cameraDefaults)
        return copy
    }
}
