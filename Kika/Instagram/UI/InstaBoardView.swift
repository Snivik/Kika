//
//  InstaBoardView.swift
//  Kika
//
//  The plan board (Library, while a plan is selected in the sidebar): the folder's photos on the left (the Library
//  grid with its filter and selection; "Instagram: Not Used" shows what's left) and the plan on the right: posts
//  and story sets as cards, each a row of slides with title, shape, planned date, status and caption.
//  Photos get in by dragging them onto a card (or "Add Selected" in its last slot); slides drag to reorder,
//  also into another card. A posted card is locked. Export: the header, a card's More menu, a slide's menu (InstaExportSheet).
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct InstaBoardView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("insta.board.poolWidth") private var poolWidth: Double = 420

    var body: some View {
        HSplitView {
            LibraryGridView()
                .frame(minWidth: 260, idealWidth: poolWidth)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { poolWidth = $0 }
            InstaPlanView()
                .frame(minWidth: 420, maxWidth: .infinity)
        }
    }
}

/// The posts and story sets of the selected plan.
struct InstaPlanView: View {
    @Environment(AppModel.self) private var model
    private var store: InstaStore { .shared }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {   // not lazy: scrollTo a card must find it
                    ForEach(store.posts) { post in
                        InstaPostCard(post: post).id(post.id)
                    }
                    if store.posts.isEmpty {
                        Text("Add a post or stories, then drag photos onto it.")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 40)
                    }
                }
                .padding(12)
            }
            .task(id: store.revealPostID) {
                // A new post, or one opened from the calendar (set before the board existed): once laid out, scroll to it.
                guard let id = store.revealPostID else { return }
                try? await Task.sleep(for: .milliseconds(150))
                withAnimation { proxy.scrollTo(id, anchor: .top) }
                try? await Task.sleep(for: .milliseconds(400))
                if store.revealPostID == id { store.revealPostID = nil }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) { header }
        .background(Color(nsColor: .underPageBackgroundColor))
        .sheet(item: Binding(get: { store.editingSlideID.flatMap { store.slide($0) }.map { InstaEditTarget(post: $0.post, slide: $0.slide, index: $0.index) } },
                             set: { if $0 == nil { store.editingSlideID = nil } })) { target in
            InstaAdjustSheet(post: target.post, slide: target.slide, index: target.index)   // InstaAdjustSheet.swift
        }
        .alert("Delete “\(store.pendingPostDeletion?.title ?? "")”?", isPresented: Binding(
            get: { store.pendingPostDeletion != nil },
            set: { if !$0 { store.pendingPostDeletion = nil } }
        ), presenting: store.pendingPostDeletion) { post in
            Button("Delete", role: .destructive) { InstaActions.deletePost(post, model: model) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Its slides, caption and date are deleted. Photos stay in the catalog.")
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "square.grid.3x3").foregroundStyle(.secondary)
            Text(usageSummary).font(.callout).foregroundStyle(.secondary).monospacedDigit()
            Spacer()
            Button { model.selectSidebarItem(.instaCalendar) } label: {
                Label("Calendar", systemImage: "calendar")
            }
            .help("Every plan's posts and stories by date")
            if let planID = model.selectedPlanID {
                Button { InstaActions.exportPlan(planID, model: model) } label: {
                    Label("Export Plan…", systemImage: "square.and.arrow.up")
                }
                .disabled(store.posts.allSatisfy { $0.photoIDs.isEmpty })
                .help("Save every post and set of stories as images, each in a folder of its own")
            }
            Button { InstaActions.newPost(.post, photoIDs: model.orderedSelection, model: model) } label: {
                Label("Post", systemImage: "plus")
            }
            .help(model.selection.isEmpty ? "New post" : "New post with the \(model.selection.count) selected photo(s)")
            Button { InstaActions.newPost(.story, photoIDs: model.orderedSelection, model: model) } label: {
                Label("Stories", systemImage: "plus")
            }
            .help(model.selection.isEmpty ? "New set of stories" : "New set of stories with the \(model.selection.count) selected photo(s)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    /// "18 of 26 photos used" over the photos shown on the left (the folder, filtered).
    private var usageSummary: String {
        let shown = model.photos
        let used = shown.filter { store.usage[$0.id] != nil }.count
        let filtered = model.filter.isEmpty ? "" : " shown"
        return "\(used) of \(shown.count)\(filtered) photo\(shown.count == 1 ? "" : "s") used"
    }
}

/// One post (carousel) or story set.
struct InstaPostCard: View {
    @Environment(AppModel.self) private var model
    let post: InstaPost

    @State private var title = ""
    /// The title when editing began: leaving the field saves only a real edit (never stale text over a rename).
    @State private var titleAtFocus = ""
    @State private var caption = ""
    @FocusState private var titleFocused: Bool
    @FocusState private var captionFocused: Bool
    @State private var addTargeted = false

    private var store: InstaStore { .shared }
    private var slideHeight: CGFloat { post.kind == .post ? 190 : 230 }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            slides
            if post.kind == .post { captionEditor }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(statusColor.opacity(post.status == .draft ? 0 : 0.7), lineWidth: 1.5))
        .opacity(post.isLocked ? 0.75 : 1)
        .onAppear {
            title = post.title
            caption = post.caption
            if store.revealPostID == post.id { DispatchQueue.main.async { titleFocused = true } }   // the plan view clears it
        }
        .onChange(of: post.title) { _, t in if !titleFocused || title == titleAtFocus { title = t; titleAtFocus = t } }
        // While typing, the editor is the truth (a save's reload may carry an older caption).
        .onChange(of: post.caption) { _, c in if !captionFocused, c != caption { caption = c } }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: post.kind.systemImage).foregroundStyle(.secondary).help(post.kind.title)
            TextField("Title", text: $title)
                .textFieldStyle(.plain)
                .font(.headline)
                .focused($titleFocused)
                .onSubmit(commitTitle)
                .onChange(of: titleFocused) { was, now in
                    if now { titleAtFocus = title } else if was { commitTitle() }
                }
                .frame(minWidth: 80, maxWidth: 220)
                .disabled(post.isLocked)
            Text(countText).font(.caption).foregroundStyle(countColor).monospacedDigit()
            Spacer(minLength: 4)
            if post.kind == .post {
                Picker("Shape", selection: Binding(get: { post.aspect }, set: { a in var p = post; p.aspect = a; InstaActions.update(p, model: model) })) {
                    ForEach(InstaAspect.postAspects, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                .disabled(post.isLocked)
                .help("Shape of every slide in the carousel")
            }
            dateControl
            Picker("Status", selection: Binding(get: { post.status }, set: { s in var p = post; p.status = s; InstaActions.update(p, model: model) })) {
                ForEach(InstaStatus.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            .help(post.postedAt.map { "Posted \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "Draft → Ready → Posted (posted cards are locked)")
            moreMenu
        }
    }

    @ViewBuilder
    private var dateControl: some View {
        if let date = post.scheduledAt {
            HStack(spacing: 2) {
                if post.status != .posted && date < Date() {
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                        .help("This date has passed")
                        .accessibilityLabel("Date passed")
                }
                DatePicker("Date", selection: Binding(get: { date }, set: { d in var p = post; p.scheduledAt = d; InstaActions.update(p, model: model) }),
                           displayedComponents: [.date, .hourAndMinute])
                    .labelsHidden()
                    .fixedSize()
                Button { var p = post; p.scheduledAt = nil; InstaActions.update(p, model: model) } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.borderless)
                .help("Remove the planned date")
            }
            .help("When to post")
        } else {
            Button { var p = post; p.scheduledAt = Self.nextSlot(); InstaActions.update(p, model: model) } label: {
                Label("Plan Date", systemImage: "calendar.badge.plus")
            }
            .buttonStyle(.borderless)
            .help("Plan when to post this")
        }
    }

    private var moreMenu: some View {
        Menu {
            Button("Move Up") { InstaActions.movePost(post, by: -1, model: model) }
                .disabled(store.posts.first?.id == post.id)
            Button("Move Down") { InstaActions.movePost(post, by: 1, model: model) }
                .disabled(store.posts.last?.id == post.id)
            Divider()
            Button("Select Photos in Grid") { InstaActions.reveal(post.photoIDs, model: model) }
                .disabled(post.photoIDs.isEmpty)
            Button(post.kind == .post ? "Export Post…" : "Export Stories…") { InstaActions.exportPost(post, model: model) }
                .disabled(post.photoIDs.isEmpty)
            if post.kind == .story {
                Menu("Add Layout Frame") {
                    ForEach(InstaLayout.allCases.filter { $0 != .single }, id: \.self) { layout in
                        Button { InstaActions.addEmptySlide(layout, to: post, model: model) } label: {
                            Label(layout.title, systemImage: layout.systemImage)
                        }
                    }
                }
                .disabled(post.isLocked)
            }
            Divider()
            Button("Delete \(post.kind == .post ? "Post" : "Stories")…") { store.pendingPostDeletion = post }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More")
    }

    private func commitTitle() {
        guard title != titleAtFocus else { return }   // not edited
        titleAtFocus = title
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { title = post.title; return }
        guard t != post.title else { return }
        var p = post
        p.title = t
        InstaActions.update(p, model: model)
    }

    private var countText: String {
        if post.kind == .story { return "\(post.slides.count) frame\(post.slides.count == 1 ? "" : "s")" }
        return "\(post.exportedSlideCount) / \(InstaPost.maxCarouselSlides)"
    }

    private var countColor: Color { post.kind == .post && post.exportedSlideCount >= InstaPost.maxCarouselSlides ? .orange : .secondary }

    private var statusColor: Color {
        switch post.status {
        case .draft: .clear
        case .ready: .accentColor
        case .posted: .green
        }
    }

    /// Tomorrow at 18:00.
    static func nextSlot() -> Date {
        let cal = Calendar.current
        let tomorrow = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: Date())) ?? Date()
        return cal.date(bySettingHour: 18, minute: 0, second: 0, of: tomorrow) ?? tomorrow
    }

    // MARK: Slides

    private var slides: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 8) {
                ForEach(Array(post.slides.enumerated()), id: \.element.id) { i, slide in
                    InstaSlideView(slide: slide, post: post, index: i, height: slideHeight)
                }
                if !post.isLocked { addSlot }
            }
            .padding(.vertical, 2)
            .padding(.horizontal, 1)
        }
        .scrollIndicators(.automatic)
        .defaultScrollAnchor(.leading)
    }

    /// Last slot: drop photos (or a slide) to append; click adds the grid selection.
    private var addSlot: some View {
        let selected = model.orderedSelection
        return Button {
            InstaActions.addSlides(selected, to: post, model: model)
        } label: {
            VStack(spacing: 6) {
                Image(systemName: "plus").font(.title3)
                Text(selected.isEmpty ? "Drop photos" : "Add \(selected.count) Selected")
                    .font(.caption)
                    .multilineTextAlignment(.center)
            }
            .foregroundStyle(addTargeted ? Color.accentColor : .secondary)
            .frame(width: max(90, slideHeight * post.aspect.ratio * 0.7), height: slideHeight)
            .background(RoundedRectangle(cornerRadius: 4).strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                .foregroundStyle(addTargeted ? Color.accentColor : Color.secondary.opacity(0.5)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(selected.isEmpty)
        .help(selected.isEmpty ? "Drag photos here from the grid" : "Add the selected photos as new \(post.kind == .post ? "slides" : "frames")")
        .onDrop(of: [.plainText], delegate: InstaAppendDropDelegate(post: post, model: model, isTargeted: $addTargeted))
    }

    // MARK: Caption

    private var captionEditor: some View {
        VStack(alignment: .trailing, spacing: 2) {
            TextEditor(text: $caption)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(4)
                .frame(height: 64)
                .focused($captionFocused)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.secondary.opacity(0.3)))
                .overlay(alignment: .topLeading) {
                    if caption.isEmpty {
                        Text("Caption").foregroundStyle(.tertiary).padding(.horizontal, 9).padding(.vertical, 4).allowsHitTesting(false)
                    }
                }
                .disabled(post.isLocked)
                .task(id: caption) {
                    // Saved once typing pauses.
                    guard caption != post.caption else { return }
                    try? await Task.sleep(for: .milliseconds(600))
                    if Task.isCancelled { return }
                    var p = post
                    p.caption = caption
                    InstaActions.update(p, model: model)
                }
            HStack(spacing: 10) {
                Button("Copy Caption") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(caption, forType: .string)
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .disabled(caption.isEmpty)
                Spacer()
                let tags = caption.split(whereSeparator: \.isWhitespace).filter { $0.hasPrefix("#") && $0.count > 1 }.count
                if tags > 0 { Text("\(tags) hashtag\(tags == 1 ? "" : "s")").font(.caption).foregroundStyle(.secondary) }
                Text("\(caption.count) / \(InstaPost.maxCaptionLength)")
                    .font(.caption).monospacedDigit()
                    .foregroundStyle(caption.count > InstaPost.maxCaptionLength ? .red : .secondary)
            }
        }
    }
}

/// Drop on a card's last slot: photos become new slides at the end; a slide moves to the end.
struct InstaAppendDropDelegate: DropDelegate {
    let post: InstaPost
    let model: AppModel
    @Binding var isTargeted: Bool

    private var accepts: Bool {
        switch KikaDrag.current {
        case .photos?, .slide?: !post.isLocked
        default: false
        }
    }

    func validateDrop(info: DropInfo) -> Bool { accepts }
    func dropEntered(info: DropInfo) { isTargeted = accepts }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: accepts ? .copy : .forbidden) }
    func dropExited(info: DropInfo) { isTargeted = false }

    func performDrop(info: DropInfo) -> Bool {
        isTargeted = false
        guard accepts else { return false }
        let post = post, model = model
        KikaDrag.load(info) { payload in
            switch payload {
            case .photos(let ids): InstaActions.addSlides(ids, to: post, model: model)
            case .slide(let id): InstaActions.moveSlide(id, to: post, at: post.slides.count, model: model)
            case .folder, .post: break
            }
        }
        return true
    }
}
