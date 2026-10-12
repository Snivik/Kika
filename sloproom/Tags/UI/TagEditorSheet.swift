//
//  TagEditorSheet.swift
//  sloproom
//
//  New / edit tag: name, colour, values (one per line or comma-separated; default true / false), where it
//  applies. Warns when saving would remove values from photos or folders. Presented from
//  `TagStore.editing` (`.tagEditorSupport(model:)` on the main window), with the delete confirmation.
//

import SwiftUI

struct TagEditorSheet: View {
    let model: AppModel
    @State var tag: Tag
    @State private var valuesText = ""
    @Environment(\.dismiss) private var dismiss

    private var isNew: Bool { tag.id == 0 }
    private var parsedValues: [String] {
        Catalog.cleanTagValues(valuesText.split(whereSeparator: { $0 == "," || $0.isNewline }).map(String.init))
    }

    var body: some View {
        let edited = edited
        let lost: (photos: Int, folders: Int) = isNew ? (0, 0) : ((try? model.catalog.tagValuesLost(by: edited)) ?? (0, 0))
        VStack(alignment: .leading, spacing: 14) {
            Text(isNew ? "New Tag" : "Edit Tag").font(.title3.weight(.semibold))
            Form {
                TextField("Name", text: $tag.name)
                LabeledContent("Colour") {
                    HStack(spacing: 6) {
                        ForEach(TagColor.allCases, id: \.self) { c in
                            Button { tag.color = c } label: {
                                TagDot(color: c, size: 16)
                                    .overlay(Circle().strokeBorder(.primary, lineWidth: tag.color == c ? 2 : 0).padding(-3))
                            }
                            .buttonStyle(.plain)
                            .help(c.title)
                            .accessibilityLabel(c.title)
                        }
                    }
                }
                TextField("Values", text: $valuesText, prompt: Text("true, false"))
                    .help("Allowed values, separated by commas. A photo or folder gets one of them.")
                Text("For a yes / no question like Blurry, keep true, false. Otherwise list the choices, e.g. Anna, Ben.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                LabeledContent("Use for") {
                    HStack {
                        Toggle("Photos", isOn: $tag.appliesToPhotos)
                        Toggle("Folders", isOn: $tag.appliesToFolders)
                    }
                    .toggleStyle(.checkbox)
                }
            }
            .formStyle(.columns)
            if lost.photos > 0 || lost.folders > 0 {
                Label(lostText(lost), systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if !isNew {
                    Button("Delete Tag…", role: .destructive) {
                        TagStore.shared.pendingDeletion = tag
                        dismiss()
                    }
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(isNew ? "Create" : "Save") {
                    TagActions.save(edited, model: model)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(tag.name.trimmingCharacters(in: .whitespaces).isEmpty || (!tag.appliesToPhotos && !tag.appliesToFolders))
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear { valuesText = tag.values.joined(separator: ", ") }
    }

    private var edited: Tag {
        var t = tag
        t.values = parsedValues
        return t
    }

    private func lostText(_ lost: (photos: Int, folders: Int)) -> String {
        var parts: [String] = []
        if lost.photos > 0 { parts.append("\(lost.photos.formatted()) photo\(lost.photos == 1 ? "" : "s")") }
        if lost.folders > 0 { parts.append("\(lost.folders.formatted()) folder\(lost.folders == 1 ? "" : "s")") }
        return "Saving removes this tag's value from " + parts.joined(separator: " and ") + "."
    }
}

extension View {
    /// The tag editor sheet and the delete confirmation, driven by `TagStore`.
    func tagEditorSupport(model: AppModel) -> some View {
        modifier(TagEditorSupport(model: model))
    }
}

private struct TagEditorSupport: ViewModifier {
    let model: AppModel
    private var store: TagStore { .shared }

    func body(content: Content) -> some View {
        @Bindable var store = store
        content
            .sheet(item: $store.editing) { tag in TagEditorSheet(model: model, tag: tag) }
            .alert("Delete the tag “\(store.pendingDeletion?.name ?? "")”?", isPresented: Binding(
                get: { store.pendingDeletion != nil },
                set: { if !$0 { store.pendingDeletion = nil } }
            ), presenting: store.pendingDeletion) { tag in
                Button("Delete", role: .destructive) { TagActions.delete(tag, model: model) }
                Button("Cancel", role: .cancel) {}
            } message: { tag in
                let n = store.photoValues.values.filter { $0[tag.id] != nil }.count
                Text(n > 0 ? "Its values are removed from \(n.formatted()) photo\(n == 1 ? "" : "s"). Photos stay in the catalog."
                           : "Photos stay in the catalog.")
            }
    }
}
