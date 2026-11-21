//
//  CleanupActions.swift
//  Kika
//
//  What you decide in Clean Up, written as YOUR tag values (they always win over the workflow's, so a later run
//  never brings a decided photo back):
//    - Keep:   your value "false" on the check's tag; a photo you'd rejected here is unflagged again.
//    - Reject: your value "true" + the Reject flag. Files are never touched; Library › Rejected lists them for
//              Remove from Catalog….
//    - Review Again: clears your value (the workflow's suggestion shows again).
//  A similar group: the marked photos are kept, the rest rejected, in one go.
//

import Foundation

enum CleanupActions {
    static func keep(_ ids: [Int64], check: CleanupCheck, model: AppModel) {
        guard let tag = tagID(check, model: model), !ids.isEmpty else { return }
        do {
            try model.catalog.setPhotoTag(tag, value: CleanupTags.no, for: ids)
            let rejected = ids.filter { id in CleanupStore.shared.photo(id)?.flag == .reject }
            if !rejected.isEmpty { try model.catalog.setFlag(.none, for: rejected) }
        } catch { model.report(error) }
    }

    static func reject(_ ids: [Int64], check: CleanupCheck, model: AppModel) {
        guard let tag = tagID(check, model: model), !ids.isEmpty else { return }
        do {
            try model.catalog.setPhotoTag(tag, value: CleanupTags.yes, for: ids)
            try model.catalog.setFlag(.reject, for: ids)
        } catch { model.report(error) }
    }

    /// Keeps `keep`, rejects the group's other photos.
    static func resolve(_ group: CleanupStore.ReviewGroup, keeping: Set<Int64>, model: AppModel) {
        let ids = group.photos.map(\.id)
        keep(ids.filter(keeping.contains), check: .similar, model: model)
        reject(ids.filter { !keeping.contains($0) }, check: .similar, model: model)
    }

    static func reviewAgain(_ ids: [Int64], check: CleanupCheck, model: AppModel) {
        guard let tag = tagID(check, model: model), !ids.isEmpty else { return }
        do { try model.catalog.setPhotoTag(tag, value: nil, for: ids) } catch { model.report(error) }
    }

    /// Whether a group member starts out marked to keep: your own decision if you made one, else picked photos,
    /// else the workflow's (no Duplicate value = the suggested keeper).
    static func isKeptByDefault(_ photo: Photo) -> Bool {
        let values = CleanupStore.shared.tagIDs[.similar].flatMap { TagStore.shared.photoValues[photo.id]?[$0] }
        if let mine = values?.mine { return mine.value != CleanupTags.yes }
        if photo.flag == .pick { return true }
        guard let effective = values?.effective else { return true }
        return effective.value != CleanupTags.yes
    }

    /// You already decided on this group member.
    static func isDecided(_ photoID: Int64) -> Bool {
        guard let tag = CleanupStore.shared.tagIDs[.similar] else { return false }
        return TagStore.shared.photoValues[photoID]?[tag]?.mine != nil
    }

    private static func tagID(_ check: CleanupCheck, model: AppModel) -> Int64? {
        if let id = CleanupStore.shared.tagIDs[check] { return id }
        do { return try model.catalog.cleanupTagIDs()[check] } catch { model.report(error); return nil }
    }
}

extension CleanupStore {
    /// A photo shown in Clean Up (groups, flagged or kept lists).
    func photo(_ id: Int64) -> Photo? {
        for g in groups { if let p = g.photos.first(where: { $0.id == id }) { return p } }
        for list in flagged.values { if let p = list.first(where: { $0.id == id }) { return p } }
        for list in kept.values { if let p = list.first(where: { $0.id == id }) { return p } }
        return nil
    }
}
