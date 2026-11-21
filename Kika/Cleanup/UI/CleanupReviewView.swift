//
//  CleanupReviewView.swift
//  Kika
//
//  Library › Clean Up (`AppModel.showsCleanup`): what the checks found, to keep or reject.
//    - Similar Shots: one card per group, like a phone's stacks. The suggested keeper is marked Best; click a
//      shot to mark it Keep / Reject, then "Keep N, Reject M" (or Keep All). Double-click: Quick Look.
//    - Blurry / Cropped: a grid with Keep / Reject per photo and for all.
//    - Kept: what you kept, per check; Review Again sends it back.
//  Keep = your own "not blurry / not cropped / not a duplicate", so later runs never suggest it again. Reject
//  flags it (Library › Rejected; Remove from Catalog… there). Runs: header button, folder menu, Library menu,
//  imports (CleanupStore).
//

import SwiftUI

struct CleanupReviewView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("cleanup.tab") private var tab: Tab = .similar
    private var store: CleanupStore { .shared }

    enum Tab: String, CaseIterable, Identifiable {
        case similar, blurry, cropped, kept
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.4))
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Clean Up").font(.title2.weight(.semibold))
                    Text("Similar shots, blurry and cropped subjects. Keep what you meant; later runs won't suggest it again.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                if store.isRunning {
                    runProgress
                } else {
                    Button("Find Photos to Clean Up…") { store.presentRunSheet(folderIDs: model.shownFolderID.map { [$0] } ?? []) }
                        .help("Choose folders and checks, then run")
                }
            }
            if !store.isRunning, let text = store.lastResultText {
                Label(text, systemImage: "checkmark.circle").font(.caption).foregroundStyle(.secondary)
            }
            Picker("Show", selection: $tab) {
                Text("Similar Shots (\(store.groups.count))").tag(Tab.similar)
                Text("Blurry (\(store.flagged[.blurry]?.count ?? 0))").tag(Tab.blurry)
                Text("Cropped (\(store.flagged[.cropped]?.count ?? 0))").tag(Tab.cropped)
                Text("Kept (\(store.kept.values.map(\.count).reduce(0, +)))").tag(Tab.kept)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var runProgress: some View {
        HStack(spacing: 10) {
            VStack(alignment: .trailing, spacing: 3) {
                ProgressView(value: Double(store.progress.done), total: Double(max(1, store.progress.total)))
                    .frame(width: 220)
                Text(store.progressText).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Button("Stop") { store.cancel() }
                .help("Stop checking (what was measured so far is kept for the next run)")
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .similar:
            if store.groups.isEmpty {
                empty("No Similar Shots to Review", "square.stack.3d.down.right",
                      "Shots taken one after another that look alike show up here as stacks.")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(store.groups) { CleanupGroupCard(group: $0) }
                    }
                    .padding(20)
                }
            }
        case .blurry, .cropped:
            let check: CleanupCheck = tab == .blurry ? .blurry : .cropped
            let photos = store.flagged[check] ?? []
            if photos.isEmpty {
                empty(tab == .blurry ? "No Blurry Photos to Review" : "No Cropped Subjects to Review", check.symbol,
                      tab == .blurry ? "Photos whose subject is out of focus or shaken show up here."
                                     : "Photos with a face or head cut by the frame show up here.")
            } else {
                CleanupPhotoGrid(photos: photos, check: check, mode: .review)
            }
        case .kept:
            let any = CleanupCheck.allCases.contains { !(store.kept[$0]?.isEmpty ?? true) }
            if !any {
                empty("Nothing Kept Yet", "hand.thumbsup", "Photos you keep in Clean Up are listed here, to review again if you change your mind.")
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        ForEach(CleanupCheck.allCases) { check in
                            if let photos = store.kept[check], !photos.isEmpty {
                                Text("\(check.title) · kept \(photos.count)").font(.headline)
                                CleanupPhotoGrid(photos: photos, check: check, mode: .kept, scrolls: false)
                            }
                        }
                    }
                    .padding(20)
                }
            }
        }
    }

    private func empty(_ title: String, _ symbol: String, _ text: String) -> some View {
        ContentUnavailableView {
            Label(title, systemImage: symbol)
        } description: {
            Text(store.analysedCount == 0 ? "Run Clean Up on all photos or on some folders. " + text : text)
        } actions: {
            if !store.isRunning {
                Button("Find Photos to Clean Up…") { store.presentRunSheet(folderIDs: model.shownFolderID.map { [$0] } ?? []) }
            }
        }
    }
}

// MARK: - Similar group card

struct CleanupGroupCard: View {
    @Environment(AppModel.self) private var model
    let group: CleanupStore.ReviewGroup
    @State private var keep: Set<Int64> = []
    @State private var initializedFor: [Int64] = []

    private var ids: [Int64] { group.photos.map(\.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "square.stack.3d.down.right").foregroundStyle(.secondary)
                Text("\(group.photos.count) similar shots").font(.headline)
                if let date = group.photos.first?.captureDate {
                    Text(date.formatted(date: .abbreviated, time: .standard)).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Keep All") { CleanupActions.resolve(group, keeping: Set(ids), model: model) }
                    .help("Keep every shot of this group; it won't be suggested again")
                let rejecting = ids.count - keep.count
                Button(rejecting == 0 ? "Keep All" : "Keep \(keep.count), Reject \(rejecting)") {
                    CleanupActions.resolve(group, keeping: keep, model: model)
                }
                .buttonStyle(.borderedProminent)
                .disabled(keep.isEmpty)
                .help(keep.isEmpty ? "Mark at least one shot to keep" : "Keep the marked shots and reject the others")
            }
            ScrollView(.horizontal) {
                HStack(spacing: 10) {
                    ForEach(group.photos) { photo in
                        CleanupShot(photo: photo, isBest: photo.id == group.group.bestID, isKept: keep.contains(photo.id),
                                    isDecided: CleanupActions.isDecided(photo.id)) {
                            if keep.contains(photo.id) { keep.remove(photo.id) } else { keep.insert(photo.id) }
                        }
                    }
                }
                .padding(.bottom, 6)
            }
            .scrollIndicators(.visible)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.08)))
        .onAppear(perform: initialize)
        .onChange(of: ids) { _, _ in initialize() }
    }

    private func initialize() {
        guard initializedFor != ids else { return }
        initializedFor = ids
        keep = Set(group.photos.filter { CleanupActions.isKeptByDefault($0) }.map(\.id))
    }
}

/// One shot of a group: click marks keep / reject, double-click previews.
private struct CleanupShot: View {
    @Environment(AppModel.self) private var model
    let photo: Photo
    let isBest: Bool
    let isKept: Bool
    let isDecided: Bool
    let toggle: () -> Void

    var body: some View {
        let size = photo.orientedSize
        let aspect = size.height > 0 ? min(max(size.width / size.height, 0.5), 2) : 1.5
        VStack(alignment: .leading, spacing: 4) {
            ThumbnailView(photo: photo, level: .thumbnail)
                .frame(width: 210 * aspect, height: 210)
                .opacity(isKept ? 1 : 0.72)   // still easy to compare with the keepers
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(isKept ? Color.green.opacity(0.9) : .clear, lineWidth: 2))
                .overlay(alignment: .topLeading) {
                    if isBest {
                        Text("Best").font(.caption2.weight(.semibold)).padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.green, in: Capsule()).foregroundStyle(.white).padding(6)
                            .help("Suggested keeper: sharpest, best looking (picked or rated photos first)")
                    }
                }
                .overlay(alignment: .topTrailing) {
                    Image(systemName: isKept ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .font(.title3)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, isKept ? Color.green : Color.red)
                        .padding(6)
                        .accessibilityLabel(isKept ? "Keep" : "Reject")
                }
            HStack(spacing: 4) {
                Text(photo.displayTitle).lineLimit(1).truncationMode(.middle)
                if isDecided { Image(systemName: "person.fill.checkmark").help("You decided on this shot before") }
                Spacer(minLength: 4)
                if let a = CleanupStore.shared.details[photo.id] {
                    Text("Sharp \(Int((a.sharpness * 100).rounded()))%")
                        .foregroundStyle(a.sharpness < CleanupStore.shared.options.blurThreshold ? .orange : .secondary)
                        .help("How sharp the subject is (0 – 100 %)")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(width: 210 * aspect)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { CleanupPreview.show(photo.id, model: model) }
        .onTapGesture(count: 1) { toggle() }
        .help(isKept ? "Marked to keep. Click to reject instead; double-click to preview" : "Marked to reject. Click to keep instead; double-click to preview")
        .contextMenu { CleanupPreview.menu(photo.id, model: model) }
    }
}

// MARK: - Flagged / kept grid

struct CleanupPhotoGrid: View {
    @Environment(AppModel.self) private var model
    let photos: [Photo]
    let check: CleanupCheck
    enum Mode { case review, kept }
    let mode: Mode
    var scrolls = true

    var body: some View {
        if scrolls {
            VStack(spacing: 0) {
                bulkBar
                Divider()
                ScrollView { grid.padding(20) }
            }
        } else {
            grid
        }
    }

    private var bulkBar: some View {
        HStack {
            Text("\(photos.count) photo\(photos.count == 1 ? "" : "s") to review").foregroundStyle(.secondary)
            Spacer()
            Button("Keep All") { CleanupActions.keep(photos.map(\.id), check: check, model: model) }
                .help("Keep every photo listed; they won't be suggested again")
            Button("Reject All") { CleanupActions.reject(photos.map(\.id), check: check, model: model) }
                .help("Flag every photo listed as rejected (Library › Rejected)")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
    }

    private var grid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 200, maximum: 280), spacing: 14)], spacing: 14) {
            ForEach(photos) { photo in
                VStack(alignment: .leading, spacing: 6) {
                    ThumbnailView(photo: photo, level: .thumbnail)
                        .rejectedVeil(photo.flag == .reject)
                        .frame(height: 190)
                        .onTapGesture(count: 2) { CleanupPreview.show(photo.id, model: model) }
                    Text(photo.displayTitle).font(.caption).lineLimit(1).truncationMode(.middle)
                    Text(detail(photo)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    HStack {
                        if mode == .review {
                            Button("Keep") { CleanupActions.keep([photo.id], check: check, model: model) }
                                .help(check == .blurry ? "It's meant to look like this: never suggest it as blurry again"
                                                       : "It's meant to be cropped like this: never suggest it again")
                            Button("Reject") { CleanupActions.reject([photo.id], check: check, model: model) }
                                .help("Flag as rejected (Library › Rejected)")
                        } else {
                            Button("Review Again") { CleanupActions.reviewAgain([photo.id], check: check, model: model) }
                                .help("Forget that you kept it: Clean Up suggests it again")
                        }
                    }
                    .controlSize(.small)
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
                .contextMenu { CleanupPreview.menu(photo.id, model: model) }
            }
        }
    }

    private func detail(_ photo: Photo) -> String {
        guard let a = CleanupStore.shared.details[photo.id] else { return "" }
        switch check {
        case .blurry: return "Sharpness \(Int((a.sharpness * 100).rounded()))%"
        case .cropped: return a.cropReason ?? "Subject at the frame's edge"
        case .similar: return "Similar to the shots next to it"
        }
    }
}

// MARK: - Preview / menu

enum CleanupPreview {
    /// Quick Look on the photo (the Library list is All Photographs while Clean Up shows).
    static func show(_ id: Int64, model: AppModel) {
        model.selection = [id]
        model.focusedPhotoID = id
        FullScreenPreview.shared.show(model: model, style: .quickLook)
    }

    @ViewBuilder
    static func menu(_ id: Int64, model: AppModel) -> some View {
        Button("Quick Look") { show(id, model: model) }
        Button("Open in Develop") {
            model.showsCleanup = false
            model.selection = [id]
            model.openInDevelop(id)
        }
    }
}
