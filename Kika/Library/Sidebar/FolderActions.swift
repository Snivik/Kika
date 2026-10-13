//
//  FolderActions.swift
//  Kika
//
//  Folder management actions shared by the sidebar, the grid context menu, drag & drop and the
//  menu bar. All catalog errors surface through `model.report`.
//

import Foundation

/// Sidebar rows. "Picked" / "Rejected" and the tag value rows ("Blurry › true", "› To Review") are All
/// Photographs + a filter, so they need no extra `PhotoSource` cases.
enum SidebarItem: Hashable {
    case all
    case lastImport
    case picked
    case rejected
    case folder(Int64)
    case tag(Int64, TagMatch)
    /// Dates section: a year (month nil) or one month; photos without a capture date.
    case date(year: Int, month: Int?)
    case undated

    /// A row that is All Photographs + a filter; leaving it clears that filter.
    var isSmartSource: Bool {
        switch self {
        case .picked, .rejected, .tag: true
        default: false
        }
    }
}

extension AppModel {
    /// The sidebar row matching the current source + flag filter.
    var sidebarItem: SidebarItem {
        switch selectedSource {
        case .all:
            if filter.flag == .all, filter.minRating == 0, filter.tags.count == 1, let c = filter.tags.first {
                .tag(c.tagID, c.match)
            } else if !filter.tags.isEmpty || filter.minRating > 0 {
                .all
            } else {
                switch filter.flag {
                case .picked: .picked
                case .rejected: .rejected
                default: .all
                }
            }
        case .lastImport: .lastImport
        case .folder(let id, _): .folder(id)
        case .captureDate(let year, let month): .date(year: year, month: month)
        case .undated: .undated
        }
    }

    /// Shows the sidebar row. Leaving Picked / Rejected (or picking All Photographs) clears the
    /// flag filter they set.
    func selectSidebarItem(_ item: SidebarItem) {
        guard item != sidebarItem else { return }
        let leavingSmartSource = sidebarItem.isSmartSource
        switch item {
        case .picked, .rejected:
            filter = PhotoFilter(flag: item == .picked ? .picked : .rejected)
            selectedSource = .all
        case .tag(let id, let match):
            filter = PhotoFilter(tags: [TagCondition(tagID: id, match: match)])
            selectedSource = .all
        case .all:
            if leavingSmartSource { filter = PhotoFilter() }
            selectedSource = .all
        case .lastImport:
            if leavingSmartSource { filter = PhotoFilter() }
            selectedSource = .lastImport
        case .folder(let id):
            if leavingSmartSource { filter = PhotoFilter() }
            selectedSource = .folder(id: id, includeSubfolders: includeSubfolders)
        case .date(let year, let month):
            if leavingSmartSource { filter = PhotoFilter() }
            selectedSource = .captureDate(year: year, month: month)
        case .undated:
            if leavingSmartSource { filter = PhotoFilter() }
            selectedSource = .undated
        }
    }

    /// The folder shown in the grid, if any.
    var shownFolderID: Int64? {
        if case .folder(let id, _) = selectedSource { return id }
        return nil
    }
}

enum FolderActions {
    private static var state: FolderSidebarState { .shared }

    /// Creates "Untitled Folder" (made unique among siblings) under `parentID`, optionally
    /// containing `photoIDs`, reveals it and starts the inline rename. The grid keeps showing
    /// the current source so photos can be dragged onto the new folder right away.
    @discardableResult
    static func newFolder(parentID: Int64?, photoIDs: [Int64] = [], model: AppModel) -> Int64? {
        let catalog = model.catalog
        do {
            let name = try catalog.uniqueFolderName("Untitled Folder", parentID: parentID)
            let id = try catalog.createFolder(name: name, parentID: parentID)
            if !photoIDs.isEmpty { try catalog.addPhotos(photoIDs, toFolder: id) }
            if let parentID { state.reveal(parentID, in: model.folders) }
            state.renamingFolderID = id
            state.scrollTarget = id
            return id
        } catch {
            model.report(error)
            return nil
        }
    }

    /// ⇧⌘N: a sibling of the folder shown in the grid, or a top-level folder.
    static func newFolderFromMenu(model: AppModel) {
        let parent = model.shownFolderID.flatMap { id in model.folders.first { $0.id == id }?.parentID }
        newFolder(parentID: parent, model: model)
    }

    static func rename(_ id: Int64, to name: String, model: AppModel) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, model.folders.first(where: { $0.id == id })?.name != trimmed else { return }
        do { try model.catalog.renameFolder(id: id, to: trimmed) } catch { model.report(error) }
    }

    static func requestDelete(_ id: Int64, model: AppModel) {
        guard let folder = model.folders.first(where: { $0.id == id }) else { return }
        let subfolders = FolderTree.subtreeIDs(of: id, in: model.folders).count - 1
        state.pendingDeletion = PendingFolderDeletion(folder: folder, subfolderCount: subfolders)
    }

    static func delete(_ id: Int64, model: AppModel) {
        do { try model.catalog.deleteFolder(id: id) } catch { model.report(error) }
    }

    static func move(_ id: Int64, to destination: FolderDropPlanner.Destination, model: AppModel) {
        do {
            try model.catalog.moveFolder(id: id, toParent: destination.parentID, index: destination.index)
            if let parent = destination.parentID { state.reveal(parent, in: model.folders) }
        } catch {
            model.report(error)
        }
    }

    /// Folders the grid is currently showing photos of: the shown folder, plus its subtree when
    /// "Include Subfolders" is on. Empty when not viewing a folder.
    static func shownFolderIDs(model: AppModel) -> [Int64] {
        guard case .folder(let id, let includeSubfolders) = model.selectedSource else { return [] }
        return includeSubfolders ? Array(FolderTree.subtreeIDs(of: id, in: model.folders)) : [id]
    }

    /// Adds photos to `folderID`; with `move`, also removes them from the shown folder(s).
    static func addPhotos(_ ids: [Int64], to folderID: Int64, move: Bool, model: AppModel) {
        let sources = move ? shownFolderIDs(model: model) : []
        do {
            if sources.isEmpty {
                try model.catalog.addPhotos(ids, toFolder: folderID)
            } else {
                try model.catalog.movePhotos(ids, fromFolders: sources, to: folderID)
            }
        } catch {
            model.report(error)
        }
    }

    /// Non-destructive: takes photos out of the shown folder (and its subfolders when they are shown).
    static func removeFromShownFolder(_ ids: [Int64], model: AppModel) {
        let sources = shownFolderIDs(model: model)
        guard !sources.isEmpty, !ids.isEmpty else { return }
        do { try model.catalog.removePhotos(ids, fromFolders: sources) } catch { model.report(error) }
    }

    /// Removes photos from the catalog (never deletes files; masters take their virtual copies
    /// along) and deletes their previews. Callers confirm first.
    static func removeFromCatalog(_ ids: [Int64], model: AppModel) {
        VirtualCopyActions.removeFromCatalog(ids, model: model)
    }
}
