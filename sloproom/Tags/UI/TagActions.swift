//
//  TagActions.swift
//  sloproom
//
//  Tag operations from menus, the sidebar, the filter bar and the Develop panel. Values are set as the
//  user (`TagAuthor.user`); workflow values are only confirmed or overridden. Errors go to `model.report`.
//

import Foundation

enum TagActions {
    static func setPhotos(_ ids: [Int64], tag: Int64, value: String?, model: AppModel) {
        do { try model.catalog.setPhotoTag(tag, value: value, for: ids) } catch { model.report(error) }
    }

    static func confirmSuggested(_ ids: [Int64], tag: Int64? = nil, model: AppModel) {
        do { try model.catalog.confirmSuggestedPhotoTags(for: ids, tagID: tag) } catch { model.report(error) }
    }

    static func setFolders(_ ids: [Int64], tag: Int64, value: String?, model: AppModel) {
        do { try model.catalog.setFolderTag(tag, value: value, for: ids) } catch { model.report(error) }
    }

    /// Opens the editor for a new tag ("Untitled Tag", next colour).
    static func newTag(model: AppModel, forFolders: Bool = false) {
        let store = TagStore.shared
        let name = (try? model.catalog.uniqueTagName()) ?? "Untitled Tag"
        let color = TagColor.allCases[store.tags.count % TagColor.allCases.count]
        store.editing = Tag(id: 0, name: name, color: color, values: Tag.defaultValues,
                            appliesToPhotos: true, appliesToFolders: forFolders, sortOrder: 0)
    }

    static func save(_ tag: Tag, model: AppModel) {
        do {
            if tag.id == 0 {
                try model.catalog.createTag(name: tag.name, color: tag.color, values: tag.values,
                                            photos: tag.appliesToPhotos, folders: tag.appliesToFolders)
            } else {
                try model.catalog.updateTag(tag)
            }
        } catch { model.report(error) }
    }

    static func delete(_ tag: Tag, model: AppModel) {
        do { try model.catalog.deleteTag(tag.id) } catch { model.report(error) }
    }
}

extension AppModel {
    /// Drops filter conditions on tags that no longer exist or values a tag no longer has (after `.tags`).
    func pruneTagFilter() {
        let tags = TagStore.shared.tags
        let kept = filter.tags.filter { c in
            guard let tag = tags.first(where: { $0.id == c.tagID }) else { return false }
            switch c.match {
            case .value(let v), .toReview(let v?): return tag.values.contains(v)
            case .toReview(nil): return true
            }
        }
        if kept != filter.tags { filter.tags = kept }
    }
}
