//
//  TagStore.swift
//  sloproom
//
//  Main-actor mirror of the catalog's tags for the UI: definitions, every photo's and folder's values
//  (whole catalog; a few rows per tagged photo), and sidebar counts. `AppModel` reloads it on `.tags` /
//  `.photoTags` / `.folderTags` and when the catalog is replaced.
//

import Foundation
import Observation

@Observable
final class TagStore {
    static let shared = TagStore()

    private(set) var tags: [Tag] = []
    private(set) var photoValues: [Int64: [Int64: TagValues]] = [:]
    private(set) var folderValues: [Int64: [Int64: TagValues]] = [:]
    /// Sidebar counts per tag: effective value → photos, and photos to review.
    private(set) var counts: [Int64: (values: [String: Int], toReview: Int)] = [:]

    /// The tag editor sheet: a new tag (nil id) or an existing one.
    var editing: Tag?
    /// Deletion awaiting confirmation.
    var pendingDeletion: Tag?

    var photoTags: [Tag] { tags.filter(\.appliesToPhotos) }
    var folderTags: [Tag] { tags.filter(\.appliesToFolders) }
    func tag(_ id: Int64) -> Tag? { tags.first { $0.id == id } }

    func load(_ catalog: Catalog) {
        reloadTags(catalog)
        reloadPhotoValues(catalog)
        reloadFolderValues(catalog)
    }

    func reloadTags(_ catalog: Catalog) {
        tags = (try? catalog.allTags()) ?? []
    }

    func reloadPhotoValues(_ catalog: Catalog) {
        photoValues = (try? catalog.photoTagValues()) ?? [:]
        var c: [Int64: (values: [String: Int], toReview: Int)] = [:]
        for byTag in photoValues.values {
            for (tagID, v) in byTag {
                if let e = v.effective { c[tagID, default: ([:], 0)].values[e.value, default: 0] += 1 }
                if v.needsReview { c[tagID, default: ([:], 0)].toReview += 1 }
            }
        }
        counts = c
    }

    func reloadFolderValues(_ catalog: Catalog) {
        folderValues = (try? catalog.folderTagValues()) ?? [:]
    }

    /// Tags whose effective value lights a dot, in tag order (grid cells, filmstrip, folder rows).
    func dots(_ values: [Int64: TagValues]?) -> [(tag: Tag, value: TagValue, isMine: Bool)] {
        guard let values, !values.isEmpty else { return [] }
        return tags.compactMap { tag in
            guard let v = values[tag.id], let e = v.effective, Tag.isShown(e.value) else { return nil }
            return (tag, e, v.mine != nil)
        }
    }

    /// The user's value shared by every photo in `ids` (nil if none or mixed).
    func commonMine(_ tagID: Int64, photos ids: [Int64]) -> String? {
        let mine = Set(ids.map { photoValues[$0]?[tagID]?.mine?.value })
        return mine.count == 1 ? mine.first ?? nil : nil
    }

    /// How many of `ids` have a workflow value without a user value (any tag).
    func reviewCount(photos ids: [Int64]) -> Int {
        ids.filter { id in photoValues[id]?.values.contains(where: \.needsReview) ?? false }.count
    }
}
