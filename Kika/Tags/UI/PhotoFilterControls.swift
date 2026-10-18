//
//  PhotoFilterControls.swift
//  Kika
//
//  One filter UI for built-in and user tags (`PhotoFilter`): the Filter menu (Flag, Rating, every photo tag
//  with its values and "To Review") and the chips of active conditions, each removable. Used by the Library
//  filter bar and the Develop toolbar (filmstrip). One condition per tag: choosing another value replaces it.
//

import SwiftUI

struct PhotoFilterMenu: View {
    @Environment(AppModel.self) private var model
    /// Show the number of active conditions in the label (Develop toolbar, no chips there).
    var showsCount = false
    private var store: TagStore { .shared }

    var body: some View {
        @Bindable var model = model
        Menu {
            Section("Flag") {
                ForEach(FlagFilter.allCases.filter { $0 != .all }, id: \.self) { f in
                    Toggle(f.title, isOn: Binding(get: { model.filter.flag == f },
                                                  set: { model.filter.flag = $0 ? f : .all }))
                        .help(f.help)
                }
            }
            Section("Rating") {
                ForEach(1...5, id: \.self) { n in
                    Toggle(String(repeating: "★", count: n) + (n < 5 ? " or more" : ""),
                           isOn: Binding(get: { model.filter.minRating == n },
                                         set: { model.filter.minRating = $0 ? n : 0 }))
                }
            }
            Section("Instagram") {
                ForEach([InstaUseFilter.unused, .used], id: \.self) { f in
                    Toggle(f.title, isOn: Binding(get: { model.filter.insta == f },
                                                  set: { model.filter.insta = $0 ? f : .any }))
                        .help(f == .unused ? "Photos not in any Instagram post or story yet" : "Photos in an Instagram post or story")
                }
            }
            if !store.photoTags.isEmpty {
                Section("Tags") {
                    ForEach(store.photoTags) { tag in
                        Menu {
                            ForEach(tag.values, id: \.self) { value in
                                toggle(value, tag: tag, match: .value(value))
                            }
                            Divider()
                            toggle("To Review", tag: tag, match: .toReview(nil))
                                .help("Set by a workflow, not reviewed by you yet")
                            toggle("Untagged", tag: tag, match: .untagged)
                                .help("No value from you or a workflow")
                        } label: {
                            Label { Text(tag.name) } icon: { TagMenuIcon(color: tag.color) }
                        }
                    }
                }
            }
            Divider()
            Button("Show All Photos") { model.filter = PhotoFilter() }
                .disabled(model.filter.isEmpty)
        } label: {
            let n = model.filter.conditionCount
            Label(showsCount && n > 0 ? "Filter (\(n))" : "Filter", systemImage: n > 0 ? "line.3.horizontal.decrease.circle.fill"
                                                                                       : "line.3.horizontal.decrease.circle")
        }
        .help("Show photos by flag, rating, Instagram use or tag")
    }

    private func toggle(_ title: String, tag: Tag, match: TagMatch) -> some View {
        let condition = TagCondition(tagID: tag.id, match: match)
        return Toggle(title, isOn: Binding(
            get: { model.filter.tags.contains(condition) },
            set: { on in
                model.filter.tags.removeAll { $0.tagID == tag.id }
                if on { model.filter.tags.append(condition) }
            }))
    }
}

/// Active filter conditions as removable chips.
struct PhotoFilterChips: View {
    @Environment(AppModel.self) private var model
    private var store: TagStore { .shared }

    var body: some View {
        HStack(spacing: 6) {
            if model.filter.flag != .all {
                chip(model.filter.flag.title, icon: AnyView(Image(systemName: "flag.fill").font(.caption2))) { model.filter.flag = .all }
            }
            if model.filter.minRating > 0 {
                chip(String(repeating: "★", count: model.filter.minRating) + (model.filter.minRating < 5 ? "+" : ""), icon: nil) {
                    model.filter.minRating = 0
                }
            }
            if model.filter.insta != .any {
                chip("Instagram: \(model.filter.insta.title.lowercased())", icon: AnyView(Image(systemName: "square.on.square").font(.caption2))) {
                    model.filter.insta = .any
                }
            }
            ForEach(model.filter.tags, id: \.self) { c in
                if let tag = store.tag(c.tagID) {
                    chip(c.title(tag), icon: AnyView(TagDot(color: tag.color, size: 7))) {
                        model.filter.tags.removeAll { $0 == c }
                    }
                }
            }
        }
    }

    private func chip(_ title: String, icon: AnyView?, remove: @escaping () -> Void) -> some View {
        HStack(spacing: 4) {
            if let icon { icon }
            Text(title).lineLimit(1)
            Button(action: remove) { Image(systemName: "xmark").font(.caption2.weight(.bold)) }
                .buttonStyle(.plain)
                .help("Remove this filter")
                .accessibilityLabel("Remove filter \(title)")
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(Color.accentColor.opacity(0.18), in: Capsule())
        .fixedSize()
    }
}

extension TagCondition {
    /// "Blurry", "Blurry: false", "Client: Anna", "Blurry: to review".
    func title(_ tag: Tag) -> String {
        switch match {
        case .value(let v): v.lowercased() == "true" ? tag.name : "\(tag.name): \(v)"
        case .toReview(nil): "\(tag.name): to review"
        case .untagged: "\(tag.name): untagged"
        case .toReview(let v?): "\(tag.name): \(v), to review"
        }
    }
}

extension PhotoFilter {
    var conditionCount: Int { (flag == .all ? 0 : 1) + (minRating == 0 ? 0 : 1) + tags.count + (insta == .any ? 0 : 1) }
}
