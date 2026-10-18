//
//  FolderRowView.swift
//  Kika
//
//  The nested folder outline: DisclosureGroups with persisted expansion (OutlineGroup can't
//  bind expansion), rows with inline rename, counts, drag source and drop target.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct FolderOutline: View {
    let nodes: [FolderNode]
    let counts: SidebarCounts
    /// While the folder filter is on: the folders that match (others are shown dimmed, as context for a match
    /// below them) and every group is expanded. nil = no filter.
    var matching: Set<Int64>? = nil

    var body: some View {
        ForEach(nodes) { node in
            let dimmed = matching.map { !$0.contains(node.id) } ?? false
            let plan = InstaStore.shared.plan(forFolder: node.id)   // its Instagram plan is the first child row
            if node.children.isEmpty && plan == nil {
                FolderRowView(node: node, counts: counts, isDimmed: dimmed)
                    .tag(SidebarItem.folder(node.id))
                    .id(SidebarItem.folder(node.id))
            } else {
                DisclosureGroup(isExpanded: matching == nil ? FolderSidebarState.shared.expansionBinding(node.id) : .constant(true)) {
                    if let plan {
                        InstaPlanRow(plan: plan)   // Instagram/UI/InstaPlanRow.swift
                            .tag(SidebarItem.plan(plan.id))
                            .id(SidebarItem.plan(plan.id))
                    }
                    FolderOutline(nodes: node.children, counts: counts, matching: matching)
                } label: {
                    FolderRowView(node: node, counts: counts, isDimmed: dimmed)
                        .tag(SidebarItem.folder(node.id))
                        .id(SidebarItem.folder(node.id))
                }
            }
        }
    }
}

struct FolderRowView: View {
    @Environment(AppModel.self) private var model
    let node: FolderNode
    let counts: SidebarCounts
    /// Shown only as the parent of a filter match.
    var isDimmed = false

    @State private var draftName = ""
    @FocusState private var isFieldFocused: Bool
    @State private var dropZone: FolderDropZone?
    @State private var rowHeight: CGFloat = 22

    private var state: FolderSidebarState { .shared }
    private var isRenaming: Bool { state.renamingFolderID == node.id }
    private var directCount: Int { model.folderCounts[node.id] ?? 0 }
    private var totalCount: Int { counts.folderTotals[node.id] ?? directCount }

    var body: some View {
        Label {
            if isRenaming {
                renameField
            } else {
                HStack(spacing: 5) {
                    Text(node.folder.name).lineLimit(1)
                    // Finder-style overlapping tag circles after the name (Tags/UI/TagViews.swift).
                    TagDots(values: TagStore.shared.folderValues[node.id], size: 9, overlapping: true, forFolders: true)
                }
                .opacity(isDimmed ? 0.5 : 1)   // the sidebar list overrides foregroundStyle on labels
            }
        } icon: {
            Image(systemName: node.children.isEmpty ? "folder" : "folder.fill")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .help(tooltip)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { rowHeight = $0 }
        .modifier(FolderDragSource(folderID: node.id, isEnabled: !isRenaming))
        .onDrop(of: [.plainText], delegate: FolderRowDropDelegate(folderID: node.id, rowHeight: rowHeight, model: model, zone: $dropZone))
        .background {
            if dropZone == .into {
                RoundedRectangle(cornerRadius: 4).strokeBorder(Color.accentColor, lineWidth: 2).padding(-2)
            }
        }
        .overlay(alignment: dropZone == .after ? .bottom : .top) {
            if dropZone == .before || dropZone == .after {
                Capsule().fill(Color.accentColor).frame(height: 2).offset(y: dropZone == .after ? 2 : -2)
            }
        }
        .overlay(alignment: .trailing) { PhotoDropVerbBadge(folderID: node.id) }   // Add / Move / Copy while photos hover
        .onChange(of: PhotoDropFeedback.shared.folderID) { _, id in
            if id != node.id && dropZone == .into { dropZone = nil }   // photo drag left or ended without dropExited
        }
        .badge(model.includeSubfolders && !node.children.isEmpty ? totalCount : directCount)
    }

    private var renameField: some View {
        TextField("Folder Name", text: $draftName)
            .textFieldStyle(.plain)
            .padding(.horizontal, 3)
            .background(RoundedRectangle(cornerRadius: 3).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Color.accentColor, lineWidth: 1))
            .focused($isFieldFocused)
            .onSubmit(commitRename)
            .onExitCommand { state.renamingFolderID = nil }
            .onAppear {
                draftName = node.folder.name
                // Focus once the field is in the window (focusing in the same pass is ignored).
                DispatchQueue.main.async { isFieldFocused = true }
            }
            .onChange(of: isFieldFocused) { wasFocused, focused in
                if wasFocused && !focused && isRenaming { commitRename() }   // click elsewhere commits
            }
    }

    private func commitRename() {
        guard isRenaming else { return }
        state.renamingFolderID = nil
        FolderActions.rename(node.id, to: draftName, model: model)
    }

    private var tooltip: String {
        func photos(_ n: Int) -> String { "\(n) photo\(n == 1 ? "" : "s")" }
        let drop = "\nDrop photos to add them (same photo) · ⌘ move · ⌥ virtual copies"
        if node.children.isEmpty { return "\(node.folder.name): \(photos(directCount))" + drop }
        return "\(node.folder.name): \(photos(directCount)) directly, \(photos(totalCount)) including subfolders" + drop
    }
}

/// Makes a row draggable, except while its name is being edited (mouse-drag selects text then).
/// Uses `itemProvider` (the List-row drag API): `onDrag` on a List row swallows the mouse-down,
/// so clicking the row's name wouldn't select the folder.
private struct FolderDragSource: ViewModifier {
    let folderID: Int64
    let isEnabled: Bool

    func body(content: Content) -> some View {
        content.itemProvider(isEnabled ? { KikaDrag.provider(.folder(folderID)) } : nil)
    }
}

/// "Folders" section header: new-folder button, and drop target for moving a folder to the top level.
struct FoldersSectionHeader: View {
    @Binding var isExpanded: Bool
    @Environment(AppModel.self) private var model
    @State private var isTargeted = false

    var body: some View {
        SidebarSectionHeader(title: "Folders", isExpanded: $isExpanded) {
            FolderTagFilterMenu()   // FolderFilterBar.swift
        } actions: {
            Button {
                FolderActions.newFolder(parentID: nil, model: model)
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
            .iconHelp("New Folder", shortcut: .newFolder)
        }
        .contentShape(Rectangle())
        .background {
            if isTargeted { RoundedRectangle(cornerRadius: 4).fill(Color.accentColor.opacity(0.25)).padding(-3) }
        }
        .onDrop(of: [.plainText], delegate: TopLevelFolderDropDelegate(model: model, isTargeted: $isTargeted))
        .help(isTargeted ? "Drop to move to the top level" : "")
    }
}
