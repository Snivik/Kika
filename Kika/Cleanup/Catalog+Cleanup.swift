//
//  Catalog+Cleanup.swift
//  Kika
//
//  Clean Up storage (CleanupModels.swift):
//    cleanup_analysis(photo_id PK, version, edit_version, sharpness, crop_score, crop_reason, quality, feature BLOB,
//                     analyzed_at)                    what the analyser measured (re-done when either version changes)
//    cleanup_groups(photo_id PK, group_id, position, is_best)   similar shots; group_id = smallest photo id
//  Both cascade with their photo. Results themselves are tag values (Blurry / Cropped / Duplicate) by
//  `CleanupTags.author`: "true" when flagged, no value otherwise (so the Tags sidebar's To Review counts only
//  flagged photos). Writes post `.photoTags(ids)`.
//

import Foundation

nonisolated extension Catalog {
    /// Creates the tables (once per catalog). Cheap; idempotent.
    func ensureCleanup() throws {
        try ensureTags()
        try applyMigration(named: "cleanup.v1", sql: """
            CREATE TABLE cleanup_analysis(
                photo_id INTEGER PRIMARY KEY REFERENCES photos(id) ON DELETE CASCADE,
                version INTEGER NOT NULL,
                edit_version INTEGER NOT NULL,
                sharpness REAL NOT NULL,
                crop_score REAL NOT NULL,
                crop_reason TEXT,
                quality REAL NOT NULL,
                feature BLOB,
                analyzed_at REAL NOT NULL
            );
            CREATE TABLE cleanup_groups(
                photo_id INTEGER PRIMARY KEY REFERENCES photos(id) ON DELETE CASCADE,
                group_id INTEGER NOT NULL,
                position INTEGER NOT NULL,
                is_best INTEGER NOT NULL DEFAULT 0
            );
            CREATE INDEX idx_cleanup_groups_group ON cleanup_groups(group_id, position);
            """)
    }

    // MARK: Analysis cache

    nonisolated struct StoredCleanupAnalysis: Sendable {
        var version: Int
        var editVersion: Int
        var analysis: CleanupAnalysis
    }

    /// Stored analyses of `photoIDs` (all when nil).
    func cleanupAnalyses(photoIDs: [Int64]? = nil) throws -> [Int64: StoredCleanupAnalysis] {
        try ensureCleanup()
        var out: [Int64: StoredCleanupAnalysis] = [:]
        let sql = "SELECT photo_id, version, edit_version, sharpness, crop_score, crop_reason, quality, feature FROM cleanup_analysis"
        func map(_ r: SQLRow) {
            out[r.int(0)] = StoredCleanupAnalysis(
                version: Int(r.int(1)), editVersion: Int(r.int(2)),
                analysis: CleanupAnalysis(sharpness: r.double(3), cropScore: r.double(4), cropReason: r.stringOrNil(5),
                                          quality: r.double(6), feature: r.data(7).map(CleanupAnalyzer.decode) ?? []))
        }
        if let photoIDs {
            for chunk in photoIDs.chunked(500) {
                let marks = Array(repeating: "?", count: chunk.count).joined(separator: ",")
                _ = try db.query(sql + " WHERE photo_id IN (\(marks))", chunk) { map($0) }
            }
        } else {
            _ = try db.query(sql) { map($0) }
        }
        return out
    }

    /// How many photos have an analysis.
    func cleanupAnalysedCount() throws -> Int {
        try ensureCleanup()
        return Int(try db.scalarInt("SELECT COUNT(*) FROM cleanup_analysis") ?? 0)
    }

    func saveCleanupAnalysis(_ a: CleanupAnalysis, photoID: Int64, editVersion: Int, version: Int = CleanupAnalyzer.version) throws {
        try ensureCleanup()
        try db.run("""
            INSERT INTO cleanup_analysis(photo_id, version, edit_version, sharpness, crop_score, crop_reason, quality, feature, analyzed_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(photo_id) DO UPDATE SET version = excluded.version, edit_version = excluded.edit_version,
                sharpness = excluded.sharpness, crop_score = excluded.crop_score, crop_reason = excluded.crop_reason,
                quality = excluded.quality, feature = excluded.feature, analyzed_at = excluded.analyzed_at
            """, [photoID, version, editVersion, a.sharpness, a.cropScore, a.cropReason.map { $0 as any SQLBindable } ?? SQLValue.null,
                  a.quality, a.feature.isEmpty ? SQLValue.null : CleanupAnalyzer.encode(a.feature), Date()])
    }

    // MARK: Tags

    /// The tag of each check, created when missing (found by name, case-insensitive). A same-named tag of the
    /// user's gets "true" / "false" added to its values and photos allowed, so the workflow can write to it.
    func cleanupTagIDs() throws -> [CleanupCheck: Int64] {
        try ensureCleanup()
        var out: [CleanupCheck: Int64] = [:]
        let tags = try allTags()
        for check in CleanupCheck.allCases {
            if var tag = tags.first(where: { $0.name.lowercased() == check.tagName.lowercased() }) {
                let missing = [CleanupTags.yes, CleanupTags.no].filter { v in !tag.values.contains { $0.lowercased() == v } }
                if !missing.isEmpty || !tag.appliesToPhotos {
                    tag.values += missing
                    tag.appliesToPhotos = true
                    try updateTag(tag)
                }
                out[check] = tag.id
            } else {
                out[check] = try createTag(name: check.tagName, color: check.tagColor)
            }
        }
        return out
    }

    /// Existing clean-up tags only (nothing created).
    func existingCleanupTagIDs() throws -> [CleanupCheck: Int64] {
        let tags = try allTags()
        var out: [CleanupCheck: Int64] = [:]
        for check in CleanupCheck.allCases {
            if let tag = tags.first(where: { $0.name.lowercased() == check.tagName.lowercased() }) { out[check] = tag.id }
        }
        return out
    }

    /// Writes the workflow's verdicts on `photoIDs`: "true" on `flagged`, no workflow value on the rest. The
    /// user's own values are never touched (they always win).
    func applyCleanupVerdicts(tagID: Int64, photoIDs: [Int64], flagged: Set<Int64>) throws {
        let yes = photoIDs.filter(flagged.contains)
        let no = photoIDs.filter { !flagged.contains($0) }
        // Only rewrite rows that change, so `set_at` keeps meaning "when it was first flagged".
        var current: Set<Int64> = []
        for chunk in photoIDs.chunked(500) {
            let marks = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            _ = try db.query("SELECT photo_id FROM photo_tags WHERE tag_id = ? AND author = ? AND value = ? AND photo_id IN (\(marks))",
                             [tagID, CleanupTags.author, CleanupTags.yes] + chunk) { current.insert($0.int(0)) }
        }
        let add = yes.filter { !current.contains($0) }
        let remove = no.filter { current.contains($0) }
        if !add.isEmpty { try setPhotoTag(tagID, value: CleanupTags.yes, author: CleanupTags.author, for: add) }
        if !remove.isEmpty { try setPhotoTag(tagID, value: nil, author: CleanupTags.author, for: remove) }
    }

    /// Your own values of a tag on `photoIDs`.
    func userTagValues(tagID: Int64, photoIDs: [Int64]) throws -> [Int64: String] {
        var out: [Int64: String] = [:]
        for chunk in photoIDs.chunked(500) {
            let marks = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            _ = try db.query("SELECT photo_id, value FROM photo_tags WHERE tag_id = ? AND author = ? AND photo_id IN (\(marks))",
                             [tagID, TagAuthor.user] + chunk) { out[$0.int(0)] = $0.string(1) }
        }
        return out
    }

    /// Photos the workflow flagged that you kept: your value "false", the workflow's "true".
    func cleanupKeptPhotoIDs(tagID: Int64) throws -> [Int64] {
        try ensureCleanup()
        return try db.query("""
            SELECT u.photo_id FROM photo_tags u JOIN photo_tags w ON w.photo_id = u.photo_id AND w.tag_id = u.tag_id
            WHERE u.tag_id = ? AND u.author = ? AND u.value = ? AND w.author = ? AND w.value = ?
            ORDER BY u.set_at DESC
            """, [tagID, TagAuthor.user, CleanupTags.no, CleanupTags.author, CleanupTags.yes]) { $0.int(0) }
    }

    // MARK: Groups

    /// Replaces the stored groups of `scope` (every photo of the run) with `groups`.
    func replaceCleanupGroups(_ groups: [CleanupGroup], scope: [Int64]) throws {
        try ensureCleanup()
        try db.transaction {
            for chunk in scope.chunked(500) {
                let marks = Array(repeating: "?", count: chunk.count).joined(separator: ",")
                try db.run("DELETE FROM cleanup_groups WHERE photo_id IN (\(marks))", chunk)
            }
            for g in groups {
                for (i, id) in g.photoIDs.enumerated() {
                    try db.run("INSERT OR REPLACE INTO cleanup_groups(photo_id, group_id, position, is_best) VALUES (?, ?, ?, ?)",
                               [id, g.id, i, id == g.bestID])
                }
            }
        }
    }

    /// Every stored group of two or more photos still in the catalog, oldest first.
    func cleanupGroups() throws -> [CleanupGroup] {
        try ensureCleanup()
        var byGroup: [Int64: (ids: [Int64], best: Int64?)] = [:]
        var order: [Int64] = []
        _ = try db.query("""
            SELECT g.group_id, g.photo_id, g.is_best FROM cleanup_groups g JOIN photos p ON p.id = g.photo_id
            ORDER BY COALESCE(p.capture_date, p.import_date), g.group_id, g.position
            """) { r in
            let gid = r.int(0)
            if byGroup[gid] == nil { order.append(gid) }
            byGroup[gid, default: ([], nil)].ids.append(r.int(1))
            if r.bool(2) { byGroup[gid]?.best = r.int(1) }
        }
        return order.compactMap { gid in
            guard let g = byGroup[gid], g.ids.count >= 2 else { return nil }
            return CleanupGroup(id: gid, photoIDs: g.ids, bestID: g.best ?? g.ids[0])
        }
    }
}

nonisolated extension Array {
    /// Consecutive slices of at most `size` elements.
    func chunked(_ size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
