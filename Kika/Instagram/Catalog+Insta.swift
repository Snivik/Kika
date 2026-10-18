//
//  Catalog+Insta.swift
//  Kika
//
//  Instagram plans in the catalog (InstaModels.swift):
//    insta_plans(id, folder_id UNIQUE, created_at)                       one plan per folder
//    insta_posts(id, plan_id, kind, title, caption, aspect, scheduled_at, status, posted_at, sort_order, created_at)
//    insta_slides(id, post_id, sort_order, layout, span, background, gap)
//    insta_cells(slide_id, cell, photo_id, zoom, offset_x, offset_y, rotation)   PK (slide_id, cell)
//      zoom = InstaTransform.scale (insta.v2 added rotation)
//  Everything cascades: folder → plan → posts → slides → cells; removing a photo from the catalog empties
//  its cells. Every write posts `.insta`.
//

import Foundation

nonisolated enum InstaError: LocalizedError {
    case carouselFull(Int)
    var errorDescription: String? {
        switch self {
        case .carouselFull(let n): "A post can have at most \(InstaPost.maxCarouselSlides) slides (this would make \(n))."
        }
    }
}

nonisolated extension Catalog {
    /// Creates the tables (once per catalog). Cheap; idempotent.
    func ensureInsta() throws {
        try applyMigration(named: "insta.v1", sql: """
            CREATE TABLE insta_plans(
                id INTEGER PRIMARY KEY,
                folder_id INTEGER NOT NULL UNIQUE REFERENCES folders(id) ON DELETE CASCADE,
                created_at REAL NOT NULL
            );
            CREATE TABLE insta_posts(
                id INTEGER PRIMARY KEY,
                plan_id INTEGER NOT NULL REFERENCES insta_plans(id) ON DELETE CASCADE,
                kind TEXT NOT NULL,
                title TEXT NOT NULL,
                caption TEXT NOT NULL DEFAULT '',
                aspect TEXT NOT NULL,
                scheduled_at REAL NULL,
                status TEXT NOT NULL DEFAULT 'draft',
                posted_at REAL NULL,
                sort_order INTEGER NOT NULL DEFAULT 0,
                created_at REAL NOT NULL
            );
            CREATE INDEX idx_insta_posts_plan ON insta_posts(plan_id, sort_order);
            CREATE TABLE insta_slides(
                id INTEGER PRIMARY KEY,
                post_id INTEGER NOT NULL REFERENCES insta_posts(id) ON DELETE CASCADE,
                sort_order INTEGER NOT NULL DEFAULT 0,
                layout TEXT NOT NULL DEFAULT 'single',
                span INTEGER NOT NULL DEFAULT 1,
                background TEXT NOT NULL DEFAULT '#FFFFFF',
                gap REAL NOT NULL DEFAULT 0.015
            );
            CREATE INDEX idx_insta_slides_post ON insta_slides(post_id, sort_order);
            CREATE TABLE insta_cells(
                slide_id INTEGER NOT NULL REFERENCES insta_slides(id) ON DELETE CASCADE,
                cell INTEGER NOT NULL,
                photo_id INTEGER NOT NULL REFERENCES photos(id) ON DELETE CASCADE,
                zoom REAL NOT NULL DEFAULT 1,
                offset_x REAL NOT NULL DEFAULT 0,
                offset_y REAL NOT NULL DEFAULT 0,
                PRIMARY KEY (slide_id, cell)
            );
            CREATE INDEX idx_insta_cells_photo ON insta_cells(photo_id);
            """)
        try applyMigration(named: "insta.v2", sql: "ALTER TABLE insta_cells ADD COLUMN rotation REAL NOT NULL DEFAULT 0;")
    }

    // MARK: Plans

    func instaPlans() throws -> [InstaPlan] {
        try ensureInsta()
        return try db.query("SELECT id, folder_id, created_at FROM insta_plans ORDER BY id") {
            InstaPlan(id: $0.int(0), folderID: $0.int(1), createdAt: $0.date(2) ?? Date())
        }
    }

    /// The folder's plan, created if it has none. Returns its id.
    @discardableResult
    func createInstaPlan(folderID: Int64) throws -> Int64 {
        try ensureInsta()
        let id: Int64 = try db.transaction {
            if let existing = try db.scalarInt("SELECT id FROM insta_plans WHERE folder_id = ?", [folderID]) { return existing }
            try db.run("INSERT INTO insta_plans(folder_id, created_at) VALUES (?, ?)", [folderID, Date()])
            return db.lastInsertRowID
        }
        postChange(.insta)
        return id
    }

    /// Deletes the plan with its posts and stories (never photos).
    func deleteInstaPlan(id: Int64) throws {
        try ensureInsta()
        try db.run("DELETE FROM insta_plans WHERE id = ?", [id])
        postChange(.insta)
    }

    // MARK: Posts

    private static let postColumns = "id, plan_id, kind, title, caption, aspect, scheduled_at, status, posted_at, sort_order"

    private static func post(row r: SQLRow) -> InstaPost {
        let kind = InstaKind(rawValue: r.string(2)) ?? .post
        return InstaPost(id: r.int(0), planID: r.int(1), kind: kind, title: r.string(3), caption: r.string(4),
                         aspect: InstaAspect(rawValue: r.string(5)) ?? (kind == .story ? .story : .portrait),
                         scheduledAt: r.date(6), status: InstaStatus(rawValue: r.string(7)) ?? .draft,
                         postedAt: r.date(8), sortOrder: Int(r.int(9)))
    }

    /// The plan's posts and story sets in board order, with their slides and cells; nil = every plan's (calendar),
    /// by plan then board order.
    func instaPosts(planID: Int64?) throws -> [InstaPost] {
        try ensureInsta()
        let plan: [any SQLBindable] = [planID, planID]
        return try db.locked {
            var posts = try db.query("SELECT \(Self.postColumns) FROM insta_posts WHERE (? IS NULL OR plan_id = ?) ORDER BY plan_id, sort_order, id",
                                     plan, Self.post(row:))
            var slidesByPost: [Int64: [InstaSlide]] = [:]
            let slides = try db.query("""
                SELECT s.id, s.post_id, s.sort_order, s.layout, s.span, s.background, s.gap FROM insta_slides s
                JOIN insta_posts p ON p.id = s.post_id WHERE (? IS NULL OR p.plan_id = ?) ORDER BY s.sort_order, s.id
                """, plan) {
                InstaSlide(id: $0.int(0), postID: $0.int(1), sortOrder: Int($0.int(2)),
                           layout: InstaLayout(rawValue: $0.string(3)) ?? .single, span: max(1, Int($0.int(4))),
                           background: $0.string(5), gap: $0.double(6))
            }
            var cellsBySlide: [Int64: [InstaCell]] = [:]
            _ = try db.query("""
                SELECT c.slide_id, c.cell, c.photo_id, c.zoom, c.offset_x, c.offset_y, c.rotation FROM insta_cells c
                JOIN insta_slides s ON s.id = c.slide_id JOIN insta_posts p ON p.id = s.post_id
                WHERE (? IS NULL OR p.plan_id = ?) ORDER BY c.cell
                """, plan) { r in
                cellsBySlide[r.int(0), default: []].append(
                    InstaCell(index: Int(r.int(1)), photoID: r.int(2),
                              transform: InstaTransform(scale: r.double(3), offsetX: r.double(4), offsetY: r.double(5), rotation: r.double(6))))
            }
            for var slide in slides {
                slide.cells = cellsBySlide[slide.id] ?? []
                slidesByPost[slide.postID, default: []].append(slide)
            }
            for i in posts.indices { posts[i].slides = slidesByPost[posts[i].id] ?? [] }
            return posts
        }
    }

    /// Appends a post (4:5) or story set to the plan, titled "Post 3" / "Stories 2". Returns its id.
    @discardableResult
    func createInstaPost(planID: Int64, kind: InstaKind) throws -> Int64 {
        try ensureInsta()
        let id: Int64 = try db.transaction {
            let count = try db.scalarInt("SELECT COUNT(*) FROM insta_posts WHERE plan_id = ? AND kind = ?", [planID, kind.rawValue]) ?? 0
            let order = try db.scalarInt("SELECT COALESCE(MAX(sort_order) + 1, 0) FROM insta_posts WHERE plan_id = ?", [planID]) ?? 0
            try db.run("""
                INSERT INTO insta_posts(plan_id, kind, title, aspect, sort_order, created_at) VALUES (?, ?, ?, ?, ?, ?)
                """, [planID, kind.rawValue, "\(kind.title) \(count + 1)", (kind == .story ? InstaAspect.story : .portrait).rawValue,
                      order, Date()])
            return db.lastInsertRowID
        }
        postChange(.insta)
        return id
    }

    /// Saves the post's own fields (title, caption, aspect, date, status). Slides are edited separately.
    /// Becoming `.posted` stamps `posted_at`; leaving it clears it.
    func updateInstaPost(_ post: InstaPost) throws {
        try ensureInsta()
        let aspect = post.kind == .story ? InstaAspect.story : (post.aspect == .story ? .portrait : post.aspect)
        try db.run("""
            UPDATE insta_posts SET title = ?, caption = ?, aspect = ?, scheduled_at = ?, status = ?,
                posted_at = CASE WHEN ? = 'posted' THEN COALESCE(posted_at, ?) ELSE NULL END
            WHERE id = ?
            """, [post.title, post.caption, aspect.rawValue, post.scheduledAt, post.status.rawValue,
                  post.status.rawValue, Date(), post.id])
        postChange(.insta)
    }

    func deleteInstaPost(id: Int64) throws {
        try ensureInsta()
        try db.run("DELETE FROM insta_posts WHERE id = ?", [id])
        postChange(.insta)
    }

    /// Moves the post to `index` among its plan's posts (clamped).
    func moveInstaPost(id: Int64, to index: Int) throws {
        try ensureInsta()
        try db.transaction {
            guard let planID = try db.scalarInt("SELECT plan_id FROM insta_posts WHERE id = ?", [id]) else { return }
            var ids = try db.query("SELECT id FROM insta_posts WHERE plan_id = ? AND id != ? ORDER BY sort_order, id", [planID, id]) { $0.int(0) }
            ids.insert(id, at: min(max(index, 0), ids.count))
            for (order, pid) in ids.enumerated() { try db.run("UPDATE insta_posts SET sort_order = ? WHERE id = ?", [order, pid]) }
        }
        postChange(.insta)
    }

    // MARK: Slides

    private func postKind(slideID: Int64) throws -> InstaKind? {
        try db.queryFirst("SELECT p.kind FROM insta_slides s JOIN insta_posts p ON p.id = s.post_id WHERE s.id = ?", [slideID]) {
            InstaKind(rawValue: $0.string(0))
        } ?? nil
    }

    /// Slides of a post in order.
    private func slideIDs(postID: Int64, excluding: Int64? = nil) throws -> [Int64] {
        try db.query("SELECT id FROM insta_slides WHERE post_id = ? AND id IS NOT ? ORDER BY sort_order, id", [postID, excluding]) { $0.int(0) }
    }

    private func renumberSlides(_ ids: [Int64]) throws {
        for (order, id) in ids.enumerated() { try db.run("UPDATE insta_slides SET sort_order = ? WHERE id = ?", [order, id]) }
    }

    /// Carousel slides the post exports to now (splits count per strip).
    private func exportedSlideCount(postID: Int64) throws -> Int {
        Int(try db.scalarInt("SELECT COALESCE(SUM(span), 0) FROM insta_slides WHERE post_id = ?", [postID]) ?? 0)
    }

    private func requireCarouselRoom(postID: Int64, adding: Int) throws {
        guard try db.scalarInt("SELECT kind = 'post' FROM insta_posts WHERE id = ?", [postID]) == 1 else { return }
        let total = try exportedSlideCount(postID: postID) + adding
        if total > InstaPost.maxCarouselSlides { throw InstaError.carouselFull(total) }
    }

    /// Adds one single-photo slide per photo at `index` (nil = the end). Returns the new slide ids in order.
    @discardableResult
    func addInstaSlides(postID: Int64, photoIDs: [Int64], at index: Int? = nil) throws -> [Int64] {
        try ensureInsta()
        guard !photoIDs.isEmpty else { return [] }
        let created: [Int64] = try db.transaction {
            try requireCarouselRoom(postID: postID, adding: photoIDs.count)
            var ids = try slideIDs(postID: postID)
            var new: [Int64] = []
            for photoID in photoIDs {
                try db.run("INSERT INTO insta_slides(post_id) VALUES (?)", [postID])
                let slideID = db.lastInsertRowID
                try db.run("INSERT INTO insta_cells(slide_id, cell, photo_id) VALUES (?, 0, ?)", [slideID, photoID])
                new.append(slideID)
            }
            ids.insert(contentsOf: new, at: min(max(index ?? ids.count, 0), ids.count))
            try renumberSlides(ids)
            return new
        }
        postChange(.insta)
        return created
    }

    /// Adds an empty slide with `layout` at the end of the post. Returns its id.
    @discardableResult
    func addInstaSlide(postID: Int64, layout: InstaLayout) throws -> Int64 {
        try ensureInsta()
        let id: Int64 = try db.transaction {
            try requireCarouselRoom(postID: postID, adding: 1)
            let order = try db.scalarInt("SELECT COALESCE(MAX(sort_order) + 1, 0) FROM insta_slides WHERE post_id = ?", [postID]) ?? 0
            try db.run("INSERT INTO insta_slides(post_id, sort_order, layout) VALUES (?, ?, ?)", [postID, order, layout.rawValue])
            return db.lastInsertRowID
        }
        postChange(.insta)
        return id
    }

    /// Puts photos into the slide's cells starting at `cell`, replacing what was there (framing reset);
    /// photos beyond the layout's last cell are ignored. Returns how many were placed.
    @discardableResult
    func setInstaCells(slideID: Int64, from cell: Int, photoIDs: [Int64]) throws -> Int {
        try ensureInsta()
        let placed: Int = try db.transaction {
            guard let layout = try db.queryFirst("SELECT layout FROM insta_slides WHERE id = ?", [slideID], {
                InstaLayout(rawValue: $0.string(0)) ?? .single
            }) else { return 0 }
            let targets = Array(max(0, cell)..<layout.cellCount)
            for (i, photoID) in zip(targets, photoIDs) {
                try db.run("INSERT OR REPLACE INTO insta_cells(slide_id, cell, photo_id) VALUES (?, ?, ?)", [slideID, i, photoID])
            }
            return min(targets.count, photoIDs.count)
        }
        postChange(.insta)
        return placed
    }

    func clearInstaCell(slideID: Int64, cell: Int) throws {
        try ensureInsta()
        try db.run("DELETE FROM insta_cells WHERE slide_id = ? AND cell = ?", [slideID, cell])
        postChange(.insta)
    }

    /// Saves where photos sit in their cells (`InstaTransform.clamped`), in one transaction.
    func setInstaCellTransforms(slideID: Int64, _ transforms: [Int: InstaTransform]) throws {
        try ensureInsta()
        try db.transaction {
            for (cell, t) in transforms {
                let t = t.clamped
                try db.run("UPDATE insta_cells SET zoom = ?, offset_x = ?, offset_y = ?, rotation = ? WHERE slide_id = ? AND cell = ?",
                           [t.scale, t.offsetX, t.offsetY, t.rotation, slideID, cell])
            }
        }
        postChange(.insta)
    }

    /// Changes the layout; cells past the new layout's count are dropped, and a multi-cell layout ends a split.
    func setInstaSlideLayout(slideID: Int64, layout: InstaLayout) throws {
        try ensureInsta()
        try db.transaction {
            try db.run("UPDATE insta_slides SET layout = ?, span = CASE WHEN ? = 'single' THEN span ELSE 1 END WHERE id = ?",
                       [layout.rawValue, layout.rawValue, slideID])
            try db.run("DELETE FROM insta_cells WHERE slide_id = ? AND cell >= ?", [slideID, layout.cellCount])
        }
        postChange(.insta)
    }

    /// Splits a post slide's photo across `span` carousel slides (1 = no split). Only single-photo post
    /// slides split; the carousel limit counts every strip.
    func setInstaSlideSpan(slideID: Int64, span: Int) throws {
        try ensureInsta()
        try db.transaction {
            guard try postKind(slideID: slideID) == .post,
                  let row = try db.queryFirst("SELECT post_id, span, layout FROM insta_slides WHERE id = ?", [slideID], {
                      ($0.int(0), Int($0.int(1)), $0.string(2))
                  }), row.2 == InstaLayout.single.rawValue else { return }
            let span = min(max(span, 1), InstaPost.maxCarouselSlides)
            try requireCarouselRoom(postID: row.0, adding: span - row.1)
            try db.run("UPDATE insta_slides SET span = ? WHERE id = ?", [span, slideID])
        }
        postChange(.insta)
    }

    func setInstaSlideStyle(slideID: Int64, background: String, gap: Double) throws {
        try ensureInsta()
        try db.run("UPDATE insta_slides SET background = ?, gap = ? WHERE id = ?", [background, min(max(gap, 0), 0.2), slideID])
        postChange(.insta)
    }

    /// Moves a slide to `index` in `postID` (its own post or another one of the plan; clamped).
    func moveInstaSlide(id: Int64, toPost postID: Int64, index: Int) throws {
        try ensureInsta()
        try db.transaction {
            guard let from = try db.queryFirst("SELECT post_id, span FROM insta_slides WHERE id = ?", [id], { ($0.int(0), Int($0.int(1))) })
            else { return }
            if from.0 != postID {
                // Splits are carousel-only: a slide moved into stories becomes one frame.
                let toStory = try db.scalarInt("SELECT kind = 'story' FROM insta_posts WHERE id = ?", [postID]) == 1
                if !toStory { try requireCarouselRoom(postID: postID, adding: from.1) }
                if toStory { try db.run("UPDATE insta_slides SET span = 1 WHERE id = ?", [id]) }
                try db.run("UPDATE insta_slides SET post_id = ? WHERE id = ?", [postID, id])
                try renumberSlides(try slideIDs(postID: from.0))
            }
            var ids = try slideIDs(postID: postID, excluding: id)
            ids.insert(id, at: min(max(index, 0), ids.count))
            try renumberSlides(ids)
        }
        postChange(.insta)
    }

    func deleteInstaSlide(id: Int64) throws {
        try ensureInsta()
        try db.transaction {
            let postID = try db.scalarInt("SELECT post_id FROM insta_slides WHERE id = ?", [id])
            try db.run("DELETE FROM insta_slides WHERE id = ?", [id])
            if let postID { try renumberSlides(try slideIDs(postID: postID)) }
        }
        postChange(.insta)
    }

    // MARK: Usage

    /// Every photo used in a post or story set, with where (posts in board order). Grid badges and the
    /// "Instagram" filter (`PhotoFilter.insta`) use this.
    func instaUsage() throws -> [Int64: [InstaUsage]] {
        try ensureInsta()
        return try db.locked {
            // Number posts per (plan, kind) in board order.
            var numbers: [Int64: Int] = [:]
            var counters: [String: Int] = [:]
            _ = try db.query("SELECT id, plan_id, kind FROM insta_posts ORDER BY plan_id, sort_order, id") { r in
                let key = "\(r.int(1))/\(r.string(2))"
                counters[key, default: 0] += 1
                numbers[r.int(0)] = counters[key]
            }
            var usage: [Int64: [InstaUsage]] = [:]
            _ = try db.query("""
                SELECT DISTINCT c.photo_id, p.id, p.plan_id, p.kind, p.status, p.sort_order FROM insta_cells c
                JOIN insta_slides s ON s.id = c.slide_id JOIN insta_posts p ON p.id = s.post_id
                ORDER BY p.plan_id, p.sort_order, p.id
                """) { r in
                usage[r.int(0), default: []].append(InstaUsage(
                    planID: r.int(2), postID: r.int(1), kind: InstaKind(rawValue: r.string(3)) ?? .post,
                    number: numbers[r.int(1)] ?? 0, status: InstaStatus(rawValue: r.string(4)) ?? .draft))
            }
            return usage
        }
    }
}
