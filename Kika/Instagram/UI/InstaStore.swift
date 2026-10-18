//
//  InstaStore.swift
//  Kika
//
//  Main-actor mirror of the catalog's Instagram plans for the UI: every plan (sidebar rows), where each photo
//  is used (grid badges), the posts of the plan on the board, and every plan's posts (the calendar). `AppModel` reloads it on `.insta` and on
//  changes that cascade into plans (folders deleted, photos removed), and when the catalog is replaced.
//

import Foundation
import Observation

@Observable
final class InstaStore {
    static let shared = InstaStore()

    private(set) var plans: [InstaPlan] = []
    /// Photo id → the posts / story sets it is in (whole catalog).
    private(set) var usage: [Int64: [InstaUsage]] = [:]
    /// Posts and story sets of `shownPlanID`, in board order.
    private(set) var posts: [InstaPost] = []
    private(set) var shownPlanID: Int64?
    /// Every plan's posts and story sets (Calendar).
    private(set) var allPosts: [InstaPost] = []
    /// The photos in `posts`, plus the first photo of every post (calendar thumbnails). Not from the pool grid,
    /// which may filter them out (e.g. "Not Used").
    private(set) var photos: [Int64: Photo] = [:]
    /// The month the calendar shows (any date in it).
    var calendarMonth = Date()

    /// Deletions awaiting confirmation.
    var pendingPlanDeletion: InstaPlan?
    var pendingPostDeletion: InstaPost?
    /// The slide open in the Adjust Photos editor.
    var editingSlideID: Int64?
    /// A post just created on the board: scrolled into view and its title focused once.
    var revealPostID: Int64?

    func plan(_ id: Int64) -> InstaPlan? { plans.first { $0.id == id } }
    func plan(forFolder folderID: Int64) -> InstaPlan? { plans.first { $0.folderID == folderID } }
    func post(_ id: Int64) -> InstaPost? { posts.first { $0.id == id } }

    func load(_ catalog: Catalog) {
        do {
            plans = try catalog.instaPlans()
            usage = try catalog.instaUsage()
        } catch {
            print("Instagram plans: \(error)")
            plans = []
            usage = [:]
        }
        if let id = shownPlanID, plan(id) == nil { shownPlanID = nil }
        allPosts = (try? catalog.instaPosts(planID: nil)) ?? []
        reloadPosts(catalog)
    }

    /// The plan on the board (nil = none). Loads its posts.
    func show(planID: Int64?, catalog: Catalog) {
        guard planID != shownPlanID else { return }
        shownPlanID = planID
        reloadPosts(catalog)
    }

    private func reloadPosts(_ catalog: Catalog) {
        posts = shownPlanID.map { (try? catalog.instaPosts(planID: $0)) ?? [] } ?? []
        reloadPhotos(catalog)   // also the calendar's first photos, with or without a plan on the board
    }

    /// Re-reads the board's photos (after edits: thumbnails follow `editVersion`).
    func reloadPhotos(_ catalog: Catalog) {
        let ids = Array(Set(posts.flatMap(\.photoIDs) + allPosts.compactMap(\.photoIDs.first)))
        let loaded = (try? catalog.photos(ids: ids)) ?? []
        photos = Dictionary(loaded.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    /// Shows new transforms right away (the catalog write follows; its reload brings the same values).
    func setTransforms(slideID: Int64, _ transforms: [Int: InstaTransform]) {
        for p in posts.indices {
            guard let s = posts[p].slides.firstIndex(where: { $0.id == slideID }) else { continue }
            for c in posts[p].slides[s].cells.indices {
                if let t = transforms[posts[p].slides[s].cells[c].index] { posts[p].slides[s].cells[c].transform = t.clamped }
            }
            return
        }
    }

    func slide(_ id: Int64) -> (post: InstaPost, slide: InstaSlide, index: Int)? {
        for post in posts {
            if let i = post.slides.firstIndex(where: { $0.id == id }) { return (post, post.slides[i], i) }
        }
        return nil
    }

    func cell(slideID: Int64, index: Int) -> InstaCell? {
        for post in posts { if let s = post.slides.first(where: { $0.id == slideID }) { return s.cell(index) } }
        return nil
    }

    /// Short labels of the posts a photo is in ("P1 S2"), for grid badges; nil when unused.
    func usageLabel(_ photoID: Int64) -> String? {
        guard let uses = usage[photoID], !uses.isEmpty else { return nil }
        return uses.map(\.label).joined(separator: " ")
    }

    func usageHelp(_ photoID: Int64) -> String {
        guard let uses = usage[photoID] else { return "" }
        let names = uses.map { u in
            let title = posts.first { $0.id == u.postID }?.title ?? "\(u.kind.title) \(u.number)"
            return u.status == .draft ? title : "\(title) (\(u.status.title.lowercased()))"
        }
        return "Used on Instagram: " + names.joined(separator: ", ")
    }
}
