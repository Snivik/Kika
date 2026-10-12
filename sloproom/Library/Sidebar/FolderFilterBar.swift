//
//  FolderFilterBar.swift
//  sloproom
//
//  Folder filter (like Xcode's navigator filter): a name field as the first row of the sidebar's Folders
//  section, and a tag menu in the Folders header (`FolderTagFilterMenu`). While it filters, the Folders section shows the matching folders with their parents (dimmed,
//  for context), every group expanded. Tag conditions use effective values, like the photo filter
//  (`TagValues.satisfies`). Esc in the field clears the text.
//

import SwiftUI

struct FolderFilterBar: View {
    @FocusState private var isFieldFocused: Bool
    private var state: FolderSidebarState { .shared }

    var body: some View {
        @Bindable var state = state
        TextField("Filter", text: $state.filterText, prompt: Text("Filter Folders"))
            .textFieldStyle(.roundedBorder)
            .controlSize(.small)
            .focused($isFieldFocused)
            .onExitCommand { state.filterText = ""; isFieldFocused = false }
            .help("Show folders whose name contains this text")
            .padding(.vertical, 2)
    }
}

/// The Folders header's tag filter (a menu doesn't render inside a sidebar List row, the header is fine).
struct FolderTagFilterMenu: View {
    @Environment(AppModel.self) private var model
    private var state: FolderSidebarState { .shared }
    private var store: TagStore { .shared }

    var body: some View {
        @Bindable var state = state
        Menu {
            if store.folderTags.isEmpty {
                Text("No tags are used for folders yet")
            }
            ForEach(store.folderTags) { tag in
                Menu {
                    ForEach(tag.values, id: \.self) { value in
                        toggle(value, TagCondition(tagID: tag.id, match: .value(value)))
                    }
                    Divider()
                    toggle("To Review", TagCondition(tagID: tag.id, match: .toReview(nil)))
                } label: {
                    Label { Text(tag.name) } icon: { TagMenuIcon(color: tag.color) }
                }
            }
            Divider()
            Button("New Tag…") { TagActions.newTag(model: model, forFolders: true) }
            Button("Clear Filter") { state.filterText = ""; state.filterTags = [] }
                .disabled(!state.isFiltering)
        } label: {
            Image(systemName: state.filterTags.isEmpty ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(tagHelp)
        .accessibilityLabel("Filter Folders by Tag")
    }

    private func toggle(_ title: String, _ condition: TagCondition) -> some View {
        Toggle(title, isOn: Binding(
            get: { state.filterTags.contains(condition) },
            set: { on in
                state.filterTags.removeAll { $0.tagID == condition.tagID }
                if on { state.filterTags.append(condition) }
            }))
    }

    private var tagHelp: String {
        let active = state.filterTags.compactMap { c in store.tag(c.tagID).map { c.title($0) } }
        return active.isEmpty ? "Show folders with a tag" : "Showing folders with: " + active.joined(separator: ", ")
    }
}

extension FolderSidebarState {
    /// The folder tree for the sidebar: everything, or the filter's matches with their parents.
    @MainActor
    func visibleTree(_ roots: [FolderNode]) -> (nodes: [FolderNode], matching: Set<Int64>?) {
        guard isFiltering else { return (roots, nil) }
        let text = filterText.trimmingCharacters(in: .whitespaces)
        let values = TagStore.shared.folderValues
        let conditions = filterTags
        let result = FolderTree.filtered(roots) { folder in
            (text.isEmpty || folder.name.localizedCaseInsensitiveContains(text))
                && conditions.allSatisfy { (values[folder.id]?[$0.tagID]).satisfies($0.match) }
        }
        return (result.nodes, result.matching)
    }
}
