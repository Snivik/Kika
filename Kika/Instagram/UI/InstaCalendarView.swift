//
//  InstaCalendarView.swift
//  Kika
//
//  Calendar (sidebar Library › Calendar, or Calendar on a plan board): every plan's posts and
//  story sets on a month grid by planned date, and the ones without a date in a Not Scheduled list on the right.
//  Filters: posts, stories or both; posted ones shown or hidden. Click an entry to open it on its plan board; drag it
//  to another day to reschedule (its time stays; a first date gets 18:00), or onto Not Scheduled to clear the date.
//  Posted entries are locked.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum InstaCalendarKinds: String, CaseIterable {
    case both, post, story

    var title: String {
        switch self {
        case .both: "Posts & Stories"
        case .post: "Posts"
        case .story: "Stories"
        }
    }

    func includes(_ kind: InstaKind) -> Bool { self == .both || rawValue == kind.rawValue }
}

struct InstaCalendarView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("insta.calendar.kinds") private var kinds: InstaCalendarKinds = .both
    @AppStorage("insta.calendar.showPosted") private var showPosted = true

    private var store: InstaStore { .shared }
    private var calendar: Calendar { .current }

    private var shown: [InstaPost] {
        store.allPosts.filter { kinds.includes($0.kind) && (showPosted || $0.status != .posted) }
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                toolbar
                Divider()
                weekdayHeader
                monthGrid
            }
            Divider()
            InstaUnscheduledList(posts: shown.filter { $0.scheduledAt == nil })
                .frame(width: 250)
        }
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 10) {
            Button { step(-1) } label: { Image(systemName: "chevron.left") }
                .buttonStyle(.borderless).help("Previous month")
            Text(store.calendarMonth.formatted(.dateTime.month(.wide).year()))
                .font(.title3.weight(.semibold))
                .frame(minWidth: 150)
            Button { step(1) } label: { Image(systemName: "chevron.right") }
                .buttonStyle(.borderless).help("Next month")
            Button("Today") { store.calendarMonth = Date() }
                .disabled(calendar.isDate(store.calendarMonth, equalTo: Date(), toGranularity: .month))
            Spacer()
            Picker("Show", selection: $kinds) {
                ForEach(InstaCalendarKinds.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("Show posts, stories or both")
            Toggle("Posted", isOn: $showPosted)
                .toggleStyle(.checkbox)
                .help("Also show what's already posted")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.bar)
    }

    private func step(_ months: Int) {
        store.calendarMonth = calendar.date(byAdding: .month, value: months, to: store.calendarMonth) ?? store.calendarMonth
    }

    // MARK: Grid

    private var weekdayHeader: some View {
        let symbols = calendar.shortWeekdaySymbols
        let first = calendar.firstWeekday - 1
        return HStack(spacing: 0) {
            ForEach(0..<7, id: \.self) { i in
                Text(symbols[(first + i) % 7].uppercased())
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 6)
    }

    /// The days on screen: whole weeks covering the month.
    private var days: [Date] {
        guard let month = calendar.dateInterval(of: .month, for: store.calendarMonth),
              let start = calendar.dateInterval(of: .weekOfMonth, for: month.start)?.start,
              let lastDay = calendar.date(byAdding: .day, value: -1, to: month.end),
              let end = calendar.dateInterval(of: .weekOfMonth, for: lastDay)?.end else { return [] }
        var out: [Date] = []
        var d = start
        while d < end {
            out.append(d)
            d = calendar.date(byAdding: .day, value: 1, to: d) ?? end
        }
        return out
    }

    private var monthGrid: some View {
        let days = days
        let weeks = max(1, days.count / 7)
        let byDay = Dictionary(grouping: shown.filter { $0.scheduledAt != nil }) { calendar.startOfDay(for: $0.scheduledAt!) }
            .mapValues { $0.sorted { $0.scheduledAt! < $1.scheduledAt! } }
        return GeometryReader { geo in
            let rowHeight = (geo.size.height - 6) / CGFloat(weeks)
            VStack(spacing: 0) {
                ForEach(0..<weeks, id: \.self) { w in
                    HStack(spacing: 0) {
                        ForEach(0..<7, id: \.self) { i in
                            let day = days[w * 7 + i]
                            InstaDayCell(day: day, posts: byDay[day] ?? [],
                                         inMonth: calendar.isDate(day, equalTo: store.calendarMonth, toGranularity: .month),
                                         height: rowHeight)
                        }
                    }
                }
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 6)
        }
    }
}

/// One day: its number, then its entries by time ("+2 more" when they don't fit). A drop target for rescheduling.
struct InstaDayCell: View {
    @Environment(AppModel.self) private var model
    let day: Date
    let posts: [InstaPost]
    let inMonth: Bool
    let height: CGFloat

    @State private var isTargeted = false

    private var isToday: Bool { Calendar.current.isDateInToday(day) }

    var body: some View {
        let fit = max(0, Int((height - 30) / 22))
        let visible = posts.count > fit ? max(0, fit - 1) : posts.count
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(day.formatted(.dateTime.day()))
                    .font(.callout.weight(isToday ? .bold : .regular)).monospacedDigit()
                    .foregroundStyle(isToday ? AnyShapeStyle(.white) : (inMonth ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary)))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background { if isToday { Capsule().fill(Color.accentColor) } }
                Spacer()
            }
            ForEach(posts.prefix(visible)) { InstaCalendarEntry(post: $0, showsTime: true) }
            if visible < posts.count {
                Text("+\(posts.count - visible) more")
                    .font(.caption).foregroundStyle(.secondary)
                    .help(posts.dropFirst(visible).map { "\($0.scheduledAt!.formatted(date: .omitted, time: .shortened)) \($0.title)" }
                        .joined(separator: "\n"))
            }
            Spacer(minLength: 0)
        }
        .padding(4)
        .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .topLeading)
        .background(inMonth ? Color(nsColor: .controlBackgroundColor) : Color(nsColor: .controlBackgroundColor).opacity(0.4))
        .overlay(Rectangle().strokeBorder(Color.secondary.opacity(0.18), lineWidth: 0.5))
        .overlay { if isTargeted { Rectangle().strokeBorder(Color.accentColor, lineWidth: 2) } }
        .clipped()
        .onDrop(of: [.plainText], delegate: InstaScheduleDropDelegate(day: day, model: model, isTargeted: $isTargeted))
    }
}

/// A post or story set as a chip: kind colour, first photo, time, title, status.
struct InstaCalendarEntry: View {
    @Environment(AppModel.self) private var model
    let post: InstaPost
    var showsTime = false

    private var store: InstaStore { .shared }
    private var tint: Color { post.kind == .post ? .accentColor : .pink }
    private var isOverdue: Bool { post.status != .posted && (post.scheduledAt.map { $0 < Date() } ?? false) }

    var body: some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 1.5).fill(tint).frame(width: 3)
            thumbnail
            if showsTime, let date = post.scheduledAt {
                Text(date.formatted(date: .omitted, time: .shortened))
                    .monospacedDigit()
                    .foregroundStyle(isOverdue ? .orange : .secondary)
            }
            Text(post.title).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 0)
            switch post.status {
            case .posted: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .ready: Image(systemName: "circle.fill").font(.system(size: 6)).foregroundStyle(tint)
            case .draft: EmptyView()
            }
        }
        .font(.caption)
        .padding(.trailing, 4)
        .frame(height: 19)
        .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 3))
        .contentShape(Rectangle())
        .onTapGesture { InstaActions.open(post, model: model) }
        .onDrag { post.isLocked ? NSItemProvider() : KikaDrag.provider(.post(post.id)) }
        .help(help)
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let id = post.photoIDs.first, let photo = store.photos[id] {
            ThumbnailView(photo: photo, level: .thumbnail, contentMode: .fill)
                .frame(width: 15, height: 15)
                .clipShape(RoundedRectangle(cornerRadius: 2))
        } else {
            Image(systemName: post.kind.systemImage).font(.system(size: 9)).foregroundStyle(tint).frame(width: 15)
        }
    }

    private var help: String {
        let folder = store.plan(post.planID).flatMap { p in model.folders.first { $0.id == p.folderID }?.name } ?? "Folder"
        var lines = ["\(post.title) · \(folder)"]
        let count = post.kind == .post ? "\(post.exportedSlideCount) slide\(post.exportedSlideCount == 1 ? "" : "s")"
                                       : "\(post.slides.count) frame\(post.slides.count == 1 ? "" : "s")"
        lines.append("\(post.kind.title) · \(count) · \(post.status.title)")
        if let date = post.scheduledAt { lines.append(date.formatted(date: .complete, time: .shortened) + (isOverdue ? " (passed)" : "")) }
        if !post.caption.isEmpty { lines.append(String(post.caption.prefix(140))) }
        lines.append(post.isLocked ? "Click to open" : "Click to open · drag to another day to reschedule")
        return lines.joined(separator: "\n")
    }
}

/// Posts and story sets without a date, by folder. Dropping a dated one here clears its date.
struct InstaUnscheduledList: View {
    @Environment(AppModel.self) private var model
    let posts: [InstaPost]

    @State private var isTargeted = false
    private var store: InstaStore { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Not Scheduled").font(.headline)
                Text("\(posts.count)").foregroundStyle(.secondary).monospacedDigit()
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(.bar)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if posts.isEmpty {
                        Text(store.allPosts.isEmpty ? "No posts or stories yet. Right-click a folder › New Instagram Plan."
                                                    : "Everything shown has a date.")
                            .font(.callout).foregroundStyle(.secondary)
                    } else {
                        Text("Drag onto a day to schedule.").font(.caption).foregroundStyle(.secondary)
                        ForEach(groups, id: \.name) { group in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(group.name).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                ForEach(group.posts) { InstaCalendarEntry(post: $0) }
                            }
                        }
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(isTargeted ? Color.accentColor.opacity(0.12) : .clear)
        .onDrop(of: [.plainText], delegate: InstaScheduleDropDelegate(day: nil, model: model, isTargeted: $isTargeted))
    }

    private var groups: [(name: String, posts: [InstaPost])] {
        var order: [String] = []
        var byName: [String: [InstaPost]] = [:]
        for post in posts {
            let name = store.plan(post.planID).flatMap { p in model.folders.first { $0.id == p.folderID }?.name } ?? "Folder"
            if byName[name] == nil { order.append(name) }
            byName[name, default: []].append(post)
        }
        return order.map { ($0, byName[$0]!) }
    }
}

/// Drop a post on a day (reschedule) or on Not Scheduled (`day` nil: clear the date).
struct InstaScheduleDropDelegate: DropDelegate {
    let day: Date?
    let model: AppModel
    @Binding var isTargeted: Bool

    private var draggedPost: InstaPost? {
        guard case .post(let id)? = KikaDrag.current, let post = InstaStore.shared.allPosts.first(where: { $0.id == id }),
              !post.isLocked else { return nil }
        return post
    }

    func validateDrop(info: DropInfo) -> Bool { draggedPost != nil }
    func dropEntered(info: DropInfo) { isTargeted = draggedPost != nil }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: draggedPost == nil ? .forbidden : .move) }
    func dropExited(info: DropInfo) { isTargeted = false }

    func performDrop(info: DropInfo) -> Bool {
        isTargeted = false
        guard draggedPost != nil else { return false }
        let day = day, model = model
        KikaDrag.load(info) { payload in
            guard case .post(let id) = payload else { return }
            InstaActions.schedule(postID: id, on: day, model: model)
        }
        return true
    }
}
