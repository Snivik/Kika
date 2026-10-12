//
//  TagViews.swift
//  sloproom
//
//  Small tag views: colour dots (grid cells, filmstrip, folder rows) and the menus that set tag values on
//  photos (context menus, Photo menu) and folders (sidebar context menu).
//  Dots: one per tag whose effective value isn't "false" / "no"; filled = set by you, ring = suggested by a
//  workflow and not reviewed yet.
//

import SwiftUI

extension TagColor {
    var color: Color {
        switch self {
        case .red: .red
        case .orange: .orange
        case .yellow: .yellow
        case .green: .green
        case .mint: .mint
        case .blue: .blue
        case .purple: .purple
        case .pink: .pink
        case .gray: .gray
        }
    }
}

/// A tag's colour swatch: filled, or a ring for an unreviewed workflow value.
struct TagDot: View {
    let color: TagColor
    var filled = true
    var size: CGFloat = 8

    var body: some View {
        Group {
            if filled {
                Circle().fill(color.color)
            } else {
                Circle().strokeBorder(color.color, lineWidth: 1.5)
            }
        }
        .frame(width: size, height: size)
    }
}

/// The tag dots of one photo or folder.
struct TagDots: View {
    let values: [Int64: TagValues]?
    var size: CGFloat = 8
    private var store: TagStore { .shared }

    var body: some View {
        let dots = store.dots(values)
        if !dots.isEmpty {
            HStack(spacing: 2) {
                ForEach(dots, id: \.tag.id) { d in
                    TagDot(color: d.tag.color, filled: d.isMine, size: size)
                }
            }
            .help(dots.map { d in
                let value = d.value.value.lowercased() == "true" ? d.tag.name : "\(d.tag.name): \(d.value.value)"
                return d.isMine ? value : "\(value) (suggested by \(d.value.author), not reviewed)"
            }.joined(separator: "\n"))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Tags: " + dots.map(\.tag.name).joined(separator: ", "))
        }
    }
}

/// "Tags" submenu content for photos: per tag its values (checked when every target has it), Clear,
/// Confirm Suggested Tags, New Tag….
struct PhotoTagMenuItems: View {
    let model: AppModel
    /// Resolved when the menu renders AND again when an item is chosen (the menu bar isn't re-rendered on
    /// every selection change).
    let targets: () -> [Int64]
    private var store: TagStore { .shared }

    init(ids: [Int64], model: AppModel) { self.model = model; self.targets = { ids } }
    init(model: AppModel, targets: @escaping () -> [Int64]) { self.model = model; self.targets = targets }

    var body: some View {
        let ids = targets()
        let tags = store.photoTags
        ForEach(tags) { tag in
            let current = store.commonMine(tag.id, photos: ids)
            Menu {
                ForEach(tag.values, id: \.self) { value in
                    Toggle(value, isOn: Binding(get: { current == value },
                                                set: { _ in TagActions.setPhotos(targets(), tag: tag.id, value: value, model: model) }))
                }
                Divider()
                Button("Clear") { TagActions.setPhotos(targets(), tag: tag.id, value: nil, model: model) }
                    .help("Remove your value of \(tag.name) (workflow suggestions stay)")
            } label: {
                Label { Text(tag.name) } icon: { TagMenuIcon(color: tag.color) }
            }
        }
        if !tags.isEmpty { Divider() }
        let review = store.reviewCount(photos: ids)
        Button(review > 0 ? "Confirm Suggested Tags (\(review.formatted()))" : "Confirm Suggested Tags") {
            TagActions.confirmSuggested(targets(), model: model)
        }
        .disabled(review == 0)
        .help("Keep the values workflows suggested as your own")
        Button("New Tag…") { TagActions.newTag(model: model) }
    }
}

/// "Tags" submenu content for folders.
struct FolderTagMenuItems: View {
    let folderID: Int64
    let model: AppModel
    private var store: TagStore { .shared }

    var body: some View {
        let tags = store.folderTags
        ForEach(tags) { tag in
            let current = store.folderValues[folderID]?[tag.id]?.mine?.value
            Menu {
                ForEach(tag.values, id: \.self) { value in
                    Toggle(value, isOn: Binding(get: { current == value },
                                                set: { _ in TagActions.setFolders([folderID], tag: tag.id, value: value, model: model) }))
                }
                Divider()
                Button("Clear") { TagActions.setFolders([folderID], tag: tag.id, value: nil, model: model) }
            } label: {
                Label { Text(tag.name) } icon: { TagMenuIcon(color: tag.color) }
            }
        }
        if !tags.isEmpty { Divider() }
        Button("New Tag…") { TagActions.newTag(model: model, forFolders: true) }
    }
}

/// Menus render SF Symbols / images only: a tinted circle symbol.
struct TagMenuIcon: View {
    let color: TagColor
    var body: some View {
        Image(systemName: "circle.fill").foregroundStyle(color.color)
    }
}
