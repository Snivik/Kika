//
//  TagsSidebarSection.swift
//  sloproom
//
//  "Tags" in the Library sidebar: every photo tag with its values and photo counts (effective values), and
//  "To Review" (set by a workflow, not by you) when there is something to review. A value row shows All
//  Photographs filtered by it (`SidebarItem.tag`). Header "+" = New Tag…; right-click a tag: Edit / Delete.
//

import SwiftUI

struct TagsSidebarSection: View {
    @Binding var isExpanded: Bool
    @Environment(AppModel.self) private var model
    @State private var collapsed: Set<Int64> = []
    private var store: TagStore { .shared }

    var body: some View {
        Section(isExpanded: $isExpanded) {
            ForEach(store.photoTags) { tag in
                DisclosureGroup(isExpanded: Binding(get: { !collapsed.contains(tag.id) },
                                                    set: { if $0 { collapsed.remove(tag.id) } else { collapsed.insert(tag.id) } })) {
                    let counts = store.counts[tag.id]
                    ForEach(tag.values, id: \.self) { value in
                        Label(value, systemImage: "tag")
                            .badge(counts?.values[value] ?? 0)
                            .help("Photos whose \(tag.name) is \(value)")
                            .tag(SidebarItem.tag(tag.id, .value(value)))
                    }
                    if let n = counts?.toReview, n > 0 {
                        Label("To Review", systemImage: "sparkles")
                            .badge(n)
                            .help("\(tag.name) set by a workflow and not reviewed by you yet")
                            .tag(SidebarItem.tag(tag.id, .toReview(nil)))
                    }
                } label: {
                    Label { Text(tag.name).lineLimit(1) } icon: { TagDot(color: tag.color, size: 10) }
                        .contextMenu { menu(tag) }
                        .help("\(tag.name): \(tag.values.joined(separator: ", "))")
                }
            }
        } header: {
            HStack {
                Text("Tags")
                Spacer()
                Button { TagActions.newTag(model: model) } label: { Image(systemName: "plus") }
                    .buttonStyle(.borderless)
                    .help("New Tag")
                    .accessibilityLabel("New Tag")
            }
            .padding(.vertical, 2)
        }
    }

    @ViewBuilder
    private func menu(_ tag: Tag) -> some View {
        Button("Edit Tag…") { store.editing = tag }
        Button("Delete Tag…") { store.pendingDeletion = tag }
    }
}
