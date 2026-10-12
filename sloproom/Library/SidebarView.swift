//
//  SidebarView.swift
//  sloproom
//
//  Sections (each can be hidden from its header, remembered): Library sources (All / Previous Import /
//  Picked / Rejected), Folders (filter row on top, then the nested tree), Dates (capture year › month,
//  Sidebar/SidebarDates.swift) and Tags (Tags/UI/TagsSidebarSection.swift: each tag's values + To Review).
//
//  Folder management:
//  - "+" in the Folders header, ⇧⌘N, or the context menu ("Create Subfolder" on a folder,
//    "Create Folder" on empty space) create "Untitled Folder", scroll it into view and start an
//    inline rename (Enter commits, Esc cancels, clicking away commits).
//  - Double-click (or context menu "Rename") renames; ⌫ (registry action) / "Delete Folder…" asks for confirmation.
//  - Drag a folder onto a folder to nest it, onto the top / bottom edge of a row to reorder,
//    onto the "Folders" header to move it to the top level. Drag photos from the grid onto a
//    folder to add them (hold ⌘ to move them out of the shown folder, ⌥ to drop virtual copies;
//    `PhotoDropVerb`).
//  Rows: see `FolderRowView.swift`; actions: `FolderActions.swift`; the folder filter row (name + folder
//  tags; matches keep their parents, dimmed): `FolderFilterBar.swift`.
//

import AppKit
import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @State private var counts = SidebarCounts()
    // Sections can be hidden (the header's Hide / Show on hover, like Finder); remembered.
    @AppStorage("sidebar.section.library") private var showsLibrary = true
    @AppStorage("sidebar.section.folders") private var showsFolders = true
    @AppStorage("sidebar.section.dates") private var showsDates = true
    @AppStorage("sidebar.section.tags") private var showsTags = true
    private var state: FolderSidebarState { .shared }

    var body: some View {
        @Bindable var state = state
        ScrollViewReader { proxy in
            List(selection: selectionBinding) {
                librarySection
                foldersSection
                Section("Dates", isExpanded: $showsDates) {
                    SidebarDates(counts: counts)   // Sidebar/SidebarDates.swift
                }
                TagsSidebarSection(isExpanded: $showsTags)   // Tags/UI/TagsSidebarSection.swift
            }
            .listStyle(.sidebar)
            .contextMenu(forSelectionType: SidebarItem.self) { items in
                contextMenu(for: items)
            } primaryAction: { items in
                if case .folder(let id)? = items.first { state.renamingFolderID = id }
            }
            .shortcutHandlers { [model] in
                // ⌫ (registry action `deleteFolder`) while the sidebar list has focus.
                [ShortcutHandler(.deleteFolder, when: { event in
                    guard event.window?.firstResponder is NSTableView, FolderSidebarState.shared.renamingFolderID == nil,
                          case .folder = model.sidebarItem else { return false }
                    return true
                }) { _ in
                    if case .folder(let id) = model.sidebarItem { FolderActions.requestDelete(id, model: model) }
                }]
            }
            .alert(state.pendingDeletion?.title ?? "", isPresented: Binding(
                get: { state.pendingDeletion != nil },
                set: { if !$0 { state.pendingDeletion = nil } }
            ), presenting: state.pendingDeletion) { pending in
                Button("Delete", role: .destructive) { FolderActions.delete(pending.folder.id, model: model) }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("Photos stay in the catalog.")
            }
            .task { counts.start(catalog: model.catalog) }
            .onChange(of: model.folders) { _, folders in
                state.prune(to: folders)
                // A new folder (header "+", ⇧⌘N, context menu) is scrolled into view once its row exists.
                if let target = state.scrollTarget, folders.contains(where: { $0.id == target }) {
                    state.scrollTarget = nil
                    DispatchQueue.main.async { withAnimation { proxy.scrollTo(SidebarItem.folder(target), anchor: .center) } }
                }
            }
        }
    }

    private var librarySection: some View {
        Section("Library", isExpanded: $showsLibrary) {
            Label("All Photographs", systemImage: "photo.on.rectangle")
                .badge(model.totalPhotoCount)
                .tag(SidebarItem.all)
            Label("Previous Import", systemImage: "clock.arrow.circlepath")
                .tag(SidebarItem.lastImport)
            Label("Picked", systemImage: "flag.fill")
                .badge(counts.flags.picked)
                .tag(SidebarItem.picked)
            Label("Rejected", systemImage: "flag.slash")
                .badge(counts.flags.rejected)
                .tag(SidebarItem.rejected)
        }
    }

    private var foldersSection: some View {
        Section(isExpanded: $showsFolders) {
            FolderFilterBar()   // name + tag filter for the folder list
            let visible = state.visibleTree(model.folderTree)   // FolderFilterBar.swift
            FolderOutline(nodes: visible.nodes, counts: counts, matching: visible.matching)
            if visible.matching?.isEmpty == true {
                Text("No Matching Folders").foregroundStyle(.secondary)
            }
        } header: {
            FoldersSectionHeader()
        }
    }

    @ViewBuilder
    private func contextMenu(for items: Set<SidebarItem>) -> some View {
        if case .folder(let id)? = items.first, let folder = model.folders.first(where: { $0.id == id }) {
            Button("Create Subfolder") { FolderActions.newFolder(parentID: folder.id, model: model) }
            Divider()
            Button("Rename") { state.renamingFolderID = id }
            Toggle("Show Photos from Subfolders", isOn: Bindable(model).includeSubfolders)
            Menu("Tags") { FolderTagMenuItems(folderID: id, model: model) }   // Tags/UI/TagViews.swift
            Divider()
            Button("Delete Folder…") { FolderActions.requestDelete(id, model: model) }
        } else if case .tag(let id, _)? = items.first, let tag = TagStore.shared.tag(id) {
            Button("Edit Tag…") { TagStore.shared.editing = tag }
            Button("Delete Tag…") { TagStore.shared.pendingDeletion = tag }
        } else if items.isEmpty {
            // Right-click on empty space in the sidebar: a top-level folder.
            Button("Create Folder") { FolderActions.newFolder(parentID: nil, model: model) }
        }
    }

    private var selectionBinding: Binding<SidebarItem?> {
        Binding {
            model.sidebarItem
        } set: { item in
            if let item { model.selectSidebarItem(item) }
        }
    }
}
