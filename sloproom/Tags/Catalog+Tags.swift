//
//  Catalog+Tags.swift
//  sloproom
//
//  Tags in the catalog (TagModels.swift):
//    tags(id, name UNIQUE NOCASE, color, vals JSON array, photos, folders, sort_order, created_at)
//    photo_tags(photo_id, tag_id, author, value, set_at)   PK (photo_id, tag_id, author)
//    folder_tags(folder_id, tag_id, author, value, set_at) PK (folder_id, tag_id, author)
//  Rows cascade with their photo / folder / tag. Definitions post `.tags`; values `.photoTags(ids)` /
//  `.folderTags`. `tagSQL` turns `TagCondition`s into WHERE clauses for `photos(in:filter:sort:)`.
//

import Foundation

nonisolated extension Catalog {
    /// Creates the tables (once per catalog). Cheap; idempotent.
    func ensureTags() throws {
        try applyMigration(named: "tags.v1", sql: """
            CREATE TABLE tags(
                id INTEGER PRIMARY KEY,
                name TEXT NOT NULL UNIQUE COLLATE NOCASE,
                color TEXT NOT NULL DEFAULT 'blue',
                vals TEXT NOT NULL DEFAULT '["true","false"]',
                photos INTEGER NOT NULL DEFAULT 1,
                folders INTEGER NOT NULL DEFAULT 0,
                sort_order INTEGER NOT NULL DEFAULT 0,
                created_at REAL NOT NULL DEFAULT 0
            );
            CREATE TABLE photo_tags(
                photo_id INTEGER NOT NULL REFERENCES photos(id) ON DELETE CASCADE,
                tag_id INTEGER NOT NULL REFERENCES tags(id) ON DELETE CASCADE,
                author TEXT NOT NULL,
                value TEXT NOT NULL,
                set_at REAL NOT NULL DEFAULT 0,
                PRIMARY KEY (photo_id, tag_id, author)
            );
            CREATE INDEX idx_photo_tags_tag ON photo_tags(tag_id, value);
            CREATE TABLE folder_tags(
                folder_id INTEGER NOT NULL REFERENCES folders(id) ON DELETE CASCADE,
                tag_id INTEGER NOT NULL REFERENCES tags(id) ON DELETE CASCADE,
                author TEXT NOT NULL,
                value TEXT NOT NULL,
                set_at REAL NOT NULL DEFAULT 0,
                PRIMARY KEY (folder_id, tag_id, author)
            );
            """)
    }

    // MARK: Definitions

    func allTags() throws -> [Tag] {
        try ensureTags()
        return try db.query("SELECT id, name, color, vals, photos, folders, sort_order FROM tags ORDER BY sort_order, name COLLATE NOCASE") {
            Tag(id: $0.int(0), name: $0.string(1), color: TagColor(rawValue: $0.string(2)) ?? .blue,
                values: Self.tagValues(json: $0.string(3)), appliesToPhotos: $0.bool(4), appliesToFolders: $0.bool(5),
                sortOrder: Int($0.int(6)))
        }
    }

    @discardableResult
    func createTag(name: String, color: TagColor, values: [String] = Tag.defaultValues,
                   photos: Bool = true, folders: Bool = false) throws -> Int64 {
        try ensureTags()
        let id: Int64 = try db.transaction {
            let order = Int(try db.scalarInt("SELECT COALESCE(MAX(sort_order) + 1, 0) FROM tags") ?? 0)
            try db.run("INSERT INTO tags(name, color, vals, photos, folders, sort_order, created_at) VALUES (?, ?, ?, ?, ?, ?, ?)",
                       [Self.cleanTagName(name), color.rawValue, Self.tagValuesJSON(values), photos, folders, order, Date()])
            return db.lastInsertRowID
        }
        postChange(.tags)
        return id
    }

    /// Saves a tag's name, colour, values and scope. Values no longer allowed are removed from photos and
    /// folders, as are photo / folder values when the tag stops applying to them.
    func updateTag(_ tag: Tag) throws {
        let values = Self.cleanTagValues(tag.values)
        let placeholders = Array(repeating: "?", count: values.count).joined(separator: ",")
        try db.transaction {
            try db.run("UPDATE tags SET name = ?, color = ?, vals = ?, photos = ?, folders = ? WHERE id = ?",
                       [Self.cleanTagName(tag.name), tag.color.rawValue, Self.tagValuesJSON(values),
                        tag.appliesToPhotos, tag.appliesToFolders, tag.id])
            let args: [any SQLBindable] = [tag.id] + values
            try db.run("DELETE FROM photo_tags WHERE tag_id = ? AND value NOT IN (\(placeholders))", args)
            try db.run("DELETE FROM folder_tags WHERE tag_id = ? AND value NOT IN (\(placeholders))", args)
            if !tag.appliesToPhotos { try db.run("DELETE FROM photo_tags WHERE tag_id = ?", [tag.id]) }
            if !tag.appliesToFolders { try db.run("DELETE FROM folder_tags WHERE tag_id = ?", [tag.id]) }
        }
        postChange(.tags)
    }

    func deleteTag(_ id: Int64) throws {
        try db.run("DELETE FROM tags WHERE id = ?", [id])
        postChange(.tags)
    }

    /// How many photos / folders would lose a value if `tag` were saved (for the editor's warning).
    func tagValuesLost(by tag: Tag) throws -> (photos: Int, folders: Int) {
        let values = Self.cleanTagValues(tag.values)
        let placeholders = Array(repeating: "?", count: values.count).joined(separator: ",")
        let args: [any SQLBindable] = [tag.id] + values
        let photos = tag.appliesToPhotos
            ? try db.scalarInt("SELECT COUNT(DISTINCT photo_id) FROM photo_tags WHERE tag_id = ? AND value NOT IN (\(placeholders))", args) ?? 0
            : try db.scalarInt("SELECT COUNT(DISTINCT photo_id) FROM photo_tags WHERE tag_id = ?", [tag.id]) ?? 0
        let folders = tag.appliesToFolders
            ? try db.scalarInt("SELECT COUNT(DISTINCT folder_id) FROM folder_tags WHERE tag_id = ? AND value NOT IN (\(placeholders))", args) ?? 0
            : try db.scalarInt("SELECT COUNT(DISTINCT folder_id) FROM folder_tags WHERE tag_id = ?", [tag.id]) ?? 0
        return (Int(photos), Int(folders))
    }

    /// "Untitled Tag", "Untitled Tag 2", …
    func uniqueTagName(_ base: String = "Untitled Tag") throws -> String {
        let taken = Set(try allTags().map { $0.name.lowercased() })
        if !taken.contains(base.lowercased()) { return base }
        var n = 2
        while taken.contains("\(base) \(n)".lowercased()) { n += 1 }
        return "\(base) \(n)"
    }

    // MARK: Values

    /// Sets (or with nil, clears) `author`'s value of a tag on photos.
    func setPhotoTag(_ tagID: Int64, value: String?, author: String = TagAuthor.user, for photoIDs: some Collection<Int64>) throws {
        guard !photoIDs.isEmpty else { return }
        try ensureTags()
        let now = Date()
        try db.transaction {
            for id in photoIDs {
                if let value {
                    try db.run("""
                        INSERT INTO photo_tags(photo_id, tag_id, author, value, set_at) VALUES (?, ?, ?, ?, ?)
                        ON CONFLICT(photo_id, tag_id, author) DO UPDATE SET value = excluded.value, set_at = excluded.set_at
                        """, [id, tagID, author, value, now])
                } else {
                    try db.run("DELETE FROM photo_tags WHERE photo_id = ? AND tag_id = ? AND author = ?", [id, tagID, author])
                }
            }
        }
        postChange(.photoTags(Set(photoIDs)))
    }

    /// Makes the latest workflow value of each tag (or only `tagID`) the user's own, on photos that have one and no
    /// user value yet. Returns how many values were confirmed.
    @discardableResult
    func confirmSuggestedPhotoTags(for photoIDs: some Collection<Int64>, tagID: Int64? = nil) throws -> Int {
        guard !photoIDs.isEmpty else { return 0 }
        let now = Date()
        let confirmed: Int = try db.transaction {
            var n = 0
            for id in photoIDs {
                n += try db.run("""
                    INSERT INTO photo_tags(photo_id, tag_id, author, value, set_at)
                    SELECT w.photo_id, w.tag_id, ?, w.value, ? FROM photo_tags w
                    WHERE w.photo_id = ? AND w.author <> ? \(tagID == nil ? "" : "AND w.tag_id = ?")
                      AND w.set_at = (SELECT MAX(x.set_at) FROM photo_tags x
                                      WHERE x.photo_id = w.photo_id AND x.tag_id = w.tag_id AND x.author <> ?)
                      AND NOT EXISTS (SELECT 1 FROM photo_tags u WHERE u.photo_id = w.photo_id AND u.tag_id = w.tag_id AND u.author = ?)
                    GROUP BY w.tag_id
                    """, [TagAuthor.user, now, id, TagAuthor.user] + (tagID.map { [$0] } ?? []) + [TagAuthor.user, TagAuthor.user])
            }
            return n
        }
        if confirmed > 0 { postChange(.photoTags(Set(photoIDs))) }
        return confirmed
    }

    /// Every photo tag value: photo → tag → values by author.
    func photoTagValues() throws -> [Int64: [Int64: TagValues]] {
        try ensureTags()
        var out: [Int64: [Int64: TagValues]] = [:]
        try db.query("SELECT photo_id, tag_id, author, value, set_at FROM photo_tags") { r in
            out[r.int(0), default: [:]][r.int(1), default: TagValues()].byAuthor
                .append(TagValue(author: r.string(2), value: r.string(3), setAt: r.date(4) ?? .distantPast))
        }
        return out
    }

    /// Sets (or with nil, clears) `author`'s value of a tag on folders.
    func setFolderTag(_ tagID: Int64, value: String?, author: String = TagAuthor.user, for folderIDs: some Collection<Int64>) throws {
        guard !folderIDs.isEmpty else { return }
        try ensureTags()
        let now = Date()
        try db.transaction {
            for id in folderIDs {
                if let value {
                    try db.run("""
                        INSERT INTO folder_tags(folder_id, tag_id, author, value, set_at) VALUES (?, ?, ?, ?, ?)
                        ON CONFLICT(folder_id, tag_id, author) DO UPDATE SET value = excluded.value, set_at = excluded.set_at
                        """, [id, tagID, author, value, now])
                } else {
                    try db.run("DELETE FROM folder_tags WHERE folder_id = ? AND tag_id = ? AND author = ?", [id, tagID, author])
                }
            }
        }
        postChange(.folderTags)
    }

    /// Every folder tag value: folder → tag → values by author.
    func folderTagValues() throws -> [Int64: [Int64: TagValues]] {
        try ensureTags()
        var out: [Int64: [Int64: TagValues]] = [:]
        try db.query("SELECT folder_id, tag_id, author, value, set_at FROM folder_tags") { r in
            out[r.int(0), default: [:]][r.int(1), default: TagValues()].byAuthor
                .append(TagValue(author: r.string(2), value: r.string(3), setAt: r.date(4) ?? .distantPast))
        }
        return out
    }

    // MARK: Filtering

    /// WHERE clause (photos aliased `p`) + arguments for one condition.
    static func tagSQL(_ c: TagCondition) -> (sql: String, args: [any SQLBindable]) {
        let user = TagAuthor.user
        switch c.match {
        case .value(let v):
            // The row that is the effective value: the user's, else the latest workflow row.
            return ("""
                EXISTS (SELECT 1 FROM photo_tags t WHERE t.photo_id = p.id AND t.tag_id = ? AND t.value = ?
                    AND t.rowid = (SELECT e.rowid FROM photo_tags e WHERE e.photo_id = p.id AND e.tag_id = t.tag_id
                                   ORDER BY e.author = ? DESC, e.set_at DESC LIMIT 1))
                """, [c.tagID, v, user])
        case .toReview(let v):
            return ("""
                EXISTS (SELECT 1 FROM photo_tags w WHERE w.photo_id = p.id AND w.tag_id = ? AND w.author <> ?\(v == nil ? "" : " AND w.value = ?"))
                AND NOT EXISTS (SELECT 1 FROM photo_tags u WHERE u.photo_id = p.id AND u.tag_id = ? AND u.author = ?)
                """, [c.tagID, user] + (v.map { [$0] } ?? []) + [c.tagID, user])
        }
    }

    // MARK: Helpers

    static func cleanTagName(_ name: String) -> String {
        let s = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? "Untitled Tag" : s
    }

    /// Trimmed, non-empty, unique (case-insensitive, first spelling wins); falls back to true / false.
    static func cleanTagValues(_ values: [String]) -> [String] {
        var seen = Set<String>()
        let out = values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
        return out.isEmpty ? Tag.defaultValues : out
    }

    static func tagValuesJSON(_ values: [String]) -> String {
        let data = (try? JSONEncoder().encode(cleanTagValues(values))) ?? Data()
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    static func tagValues(json: String) -> [String] {
        cleanTagValues((try? JSONDecoder().decode([String].self, from: Data(json.utf8))) ?? [])
    }
}
