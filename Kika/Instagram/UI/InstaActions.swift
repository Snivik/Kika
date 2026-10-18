//
//  InstaActions.swift
//  Kika
//
//  Instagram plan actions for the sidebar and the board: catalog writes with errors reported to the window.
//  The catalog posts `.insta`; `AppModel` reloads `InstaStore`.
//

import Foundation

enum InstaActions {
    private static var store: InstaStore { .shared }

    /// The folder's plan (created if needed), revealed under its folder and shown on the board.
    static func showPlan(folderID: Int64, model: AppModel) {
        do {
            let id = try model.catalog.createInstaPlan(folderID: folderID)
            store.load(model.catalog)   // the row must exist before it is selected
            FolderSidebarState.shared.reveal(folderID, in: model.folders)
            FolderSidebarState.shared.setExpanded(folderID, true)
            if model.mode != .library { model.mode = .library }
            model.selectSidebarItem(.plan(id))
            if store.posts.isEmpty { newPost(.post, model: model) }   // a new plan starts with one post
        } catch {
            model.report(error)
        }
    }

    static func deletePlan(_ plan: InstaPlan, model: AppModel) {
        do { try model.catalog.deleteInstaPlan(id: plan.id) } catch { model.report(error) }
    }

    /// Appends a post or story set to the plan on the board.
    @discardableResult
    static func newPost(_ kind: InstaKind, photoIDs: [Int64] = [], model: AppModel) -> Int64? {
        guard let planID = model.selectedPlanID else { return nil }
        do {
            let id = try model.catalog.createInstaPost(planID: planID, kind: kind)
            if !photoIDs.isEmpty { try model.catalog.addInstaSlides(postID: id, photoIDs: photoIDs) }
            store.revealPostID = id
            return id
        } catch {
            model.report(error)
            return nil
        }
    }

    static func update(_ post: InstaPost, model: AppModel) {
        do { try model.catalog.updateInstaPost(post) } catch { model.report(error) }
    }

    static func deletePost(_ post: InstaPost, model: AppModel) {
        do { try model.catalog.deleteInstaPost(id: post.id) } catch { model.report(error) }
    }

    static func movePost(_ post: InstaPost, by delta: Int, model: AppModel) {
        guard let i = store.posts.firstIndex(where: { $0.id == post.id }) else { return }
        do { try model.catalog.moveInstaPost(id: post.id, to: i + delta) } catch { model.report(error) }
    }

    /// One new slide (stories: frame) per photo at `index` (nil = the end).
    static func addSlides(_ photoIDs: [Int64], to post: InstaPost, at index: Int? = nil, model: AppModel) {
        do { try model.catalog.addInstaSlides(postID: post.id, photoIDs: photoIDs, at: index) } catch { model.report(error) }
    }

    static func addEmptySlide(_ layout: InstaLayout, to post: InstaPost, model: AppModel) {
        do { try model.catalog.addInstaSlide(postID: post.id, layout: layout) } catch { model.report(error) }
    }

    /// Photos dropped on a cell: they fill it and the cells after it.
    static func fill(slide: InstaSlide, from cell: Int, with photoIDs: [Int64], model: AppModel) {
        do { try model.catalog.setInstaCells(slideID: slide.id, from: cell, photoIDs: photoIDs) } catch { model.report(error) }
    }

    static func clear(slide: InstaSlide, cell: Int, model: AppModel) {
        do { try model.catalog.clearInstaCell(slideID: slide.id, cell: cell) } catch { model.report(error) }
    }

    static func setLayout(_ layout: InstaLayout, of slide: InstaSlide, model: AppModel) {
        do { try model.catalog.setInstaSlideLayout(slideID: slide.id, layout: layout) } catch { model.report(error) }
    }

    static func setSpan(_ span: Int, of slide: InstaSlide, model: AppModel) {
        do { try model.catalog.setInstaSlideSpan(slideID: slide.id, span: span) } catch { model.report(error) }
    }

    static func setBackground(_ hex: String, of slide: InstaSlide, model: AppModel) {
        do { try model.catalog.setInstaSlideStyle(slideID: slide.id, background: hex, gap: slide.gap) } catch { model.report(error) }
    }

    /// Where photos sit in their cells: shown at once, saved to the catalog.
    static func setTransforms(_ transforms: [Int: InstaTransform], slideID: Int64, model: AppModel) {
        guard !transforms.isEmpty else { return }
        store.setTransforms(slideID: slideID, transforms)
        do { try model.catalog.setInstaCellTransforms(slideID: slideID, transforms) } catch { model.report(error) }
    }

    /// Centred, filling, unrotated: every cell of the slide.
    static func resetFraming(_ slide: InstaSlide, model: AppModel) {
        setTransforms(Dictionary(uniqueKeysWithValues: slide.cells.map { ($0.index, InstaTransform()) }), slideID: slide.id, model: model)
    }

    /// Opens the Adjust Photos editor on the slide.
    static func adjust(_ slide: InstaSlide) {
        guard !slide.cells.isEmpty else { return }
        store.editingSlideID = slide.id
    }

    static func moveSlide(_ slideID: Int64, to post: InstaPost, at index: Int, model: AppModel) {
        do { try model.catalog.moveInstaSlide(id: slideID, toPost: post.id, index: index) } catch { model.report(error) }
    }

    static func deleteSlide(_ slide: InstaSlide, model: AppModel) {
        do { try model.catalog.deleteInstaSlide(id: slide.id) } catch { model.report(error) }
    }

    /// Shows the post on its plan board (calendar click).
    static func open(_ post: InstaPost, model: AppModel) {
        if model.mode != .library { model.mode = .library }
        model.selectSidebarItem(.plan(post.planID))
        store.revealPostID = post.id
    }

    /// Plans the post for `day`, keeping its time of day (18:00 if it had no date); nil clears the date.
    static func schedule(postID: Int64, on day: Date?, model: AppModel) {
        guard var post = store.allPosts.first(where: { $0.id == postID }), !post.isLocked else { return }
        if let day {
            let cal = Calendar.current
            let time = post.scheduledAt.map { cal.dateComponents([.hour, .minute], from: $0) } ?? DateComponents(hour: 18, minute: 0)
            post.scheduledAt = cal.date(bySettingHour: time.hour ?? 18, minute: time.minute ?? 0, second: 0, of: day)
        } else {
            post.scheduledAt = nil
        }
        post.slides = []   // updateInstaPost saves the post's own fields only
        update(post, model: model)
    }

    /// Selects the photos of a slide (or a whole post) in the pool grid.
    static func reveal(_ photoIDs: [Int64], model: AppModel) {
        let shown = photoIDs.filter { model.index(of: $0) != nil }
        guard let first = shown.first else { return }
        model.selection = Set(shown)
        model.focusedPhotoID = first
    }
}
