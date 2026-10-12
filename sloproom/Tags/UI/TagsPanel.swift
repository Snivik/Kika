//
//  TagsPanel.swift
//  sloproom
//
//  Develop inspector "Tags": the photo's value for every photo tag (yours; "—" = none) and, where a workflow
//  suggested one you haven't set, the suggestion with Confirm. With the sidebar's "To Review" rows this is the
//  review loop: open the set, step through with ← / →, confirm or change.
//

import SwiftUI

struct TagsPanel: View {
    let session: DevelopSession
    @Environment(AppModel.self) private var model
    private var store: TagStore { .shared }

    var body: some View {
        let photoID = session.photo.id
        let values = store.photoValues[photoID] ?? [:]
        InspectorSection("Tags", id: "tags") {
            VStack(alignment: .leading, spacing: 8) {
                if store.photoTags.isEmpty {
                    Text("No tags yet. Tags mark photos for later, e.g. Blurry: true / false, so you can review a smaller set.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                ForEach(store.photoTags) { tag in
                    row(tag, values[tag.id], photoID: photoID)
                }
                HStack {
                    if values.values.contains(where: \.needsReview) {
                        Button("Confirm All Suggestions") { TagActions.confirmSuggested([photoID], model: model) }
                            .help("Keep every value workflows suggested for this photo as your own")
                    }
                    Spacer()
                    Button("New Tag…") { TagActions.newTag(model: model) }
                }
                .controlSize(.small)
            }
        }
    }

    @ViewBuilder
    private func row(_ tag: Tag, _ v: TagValues?, photoID: Int64) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                TagDot(color: tag.color, size: 9)
                Text(tag.name).lineLimit(1)
                Spacer()
                Picker(tag.name, selection: Binding<String?>(
                    get: { v?.mine?.value },
                    set: { TagActions.setPhotos([photoID], tag: tag.id, value: $0, model: model) })) {
                    Text("—").tag(String?.none)
                    ForEach(tag.values, id: \.self) { Text($0).tag(String?.some($0)) }
                }
                .labelsHidden()
                .fixedSize()
                .controlSize(.small)
                .help("Your value of \(tag.name) for this photo")
            }
            if let s = v?.suggested, v?.mine?.value != s.value {
                HStack(spacing: 6) {
                    Text("Suggested: \(s.value)").foregroundStyle(.secondary)
                    Text("by \(s.author)").foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    if v?.mine == nil {
                        Button("Confirm") { TagActions.confirmSuggested([photoID], tag: tag.id, model: model) }
                            .controlSize(.small)
                            .help("Keep \(tag.name): \(s.value) as your own")
                    }
                }
                .font(.caption)
                .padding(.leading, 15)
            }
        }
    }
}
