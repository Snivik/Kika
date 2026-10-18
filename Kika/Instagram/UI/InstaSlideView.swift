//
//  InstaSlideView.swift
//  Kika
//
//  One slide (story frame) on the plan board, drawn at `height` in its post's shape: background, layout cells
//  with their photos (aspect-fill), empty cells as drop targets, and the cut lines of a split.
//  Drops: photos on the left / right fifth insert new slides before / after; in the middle they fill the cell
//  under the pointer and the ones after it (a single-photo slide is replaced). A dragged slide moves before / after.
//  Drag the slide to move it; double-click (or Adjust Photos… in the menu) to scale, rotate and move its photos
//  (InstaAdjustSheet). Context menu: adjust, layout, split, background, remove photo, delete slide, open in Develop.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct InstaSlideView: View {
    @Environment(AppModel.self) private var model
    let slide: InstaSlide
    let post: InstaPost
    let index: Int
    let height: CGFloat

    @State private var drop: InstaSlideDrop?

    private var store: InstaStore { .shared }
    private var frameSize: CGSize { CGSize(width: height * post.aspect.ratio, height: height) }
    private var size: CGSize { CGSize(width: frameSize.width * CGFloat(slide.span), height: height) }
    private var rects: [CGRect] { slide.layout.cellRects(in: size, gap: slide.layout == .single ? 0 : slide.gap * CGFloat(slide.span)) }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Rectangle().fill(Color(hex: slide.background) ?? .white)
            ForEach(Array(rects.enumerated()), id: \.offset) { i, rect in
                InstaCellView(cell: slide.cell(i), size: rect.size)
                    .offset(x: rect.minX, y: rect.minY)
            }
            if slide.span > 1 { splitLines }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .overlay(alignment: .topLeading) { badge }
        .overlay { dropFeedback }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { if !post.isLocked { InstaActions.adjust(slide) } }
        .onDrag { KikaDrag.provider(.slide(slide.id)) }
        .onDrop(of: [.plainText], delegate: InstaSlideDropDelegate(slide: slide, post: post, index: index, size: size, rects: rects,
                                                                   model: model, drop: $drop))
        .contextMenu { menu }
        .help(help)
    }

    /// Where the photo is cut into carousel slides.
    private var splitLines: some View {
        ForEach(1..<slide.span, id: \.self) { k in
            Rectangle()
                .fill(.white.opacity(0.9))
                .frame(width: 1, height: height)
                .overlay(Rectangle().stroke(style: StrokeStyle(lineWidth: 1, dash: [4, 3])).foregroundStyle(.black.opacity(0.5)))
                .offset(x: frameSize.width * CGFloat(k))
        }
    }

    private var badge: some View {
        HStack(spacing: 3) {
            Text("\(index + 1)").monospacedDigit()
            if slide.span > 1 { Image(systemName: "scissors"); Text("×\(slide.span)") }
        }
        .font(.caption2.weight(.semibold))
        .padding(.horizontal, 4).padding(.vertical, 1)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 3))
        .foregroundStyle(.white)
        .padding(3)
    }

    @ViewBuilder
    private var dropFeedback: some View {
        switch drop {
        case .before, .after:
            Capsule().fill(Color.accentColor).frame(width: 3)
                .frame(maxWidth: .infinity, alignment: drop == .before ? .leading : .trailing)
                .offset(x: drop == .before ? -5 : 5)
        case .cell(let i) where i < rects.count:
            let r = rects[i]
            RoundedRectangle(cornerRadius: 3).strokeBorder(Color.accentColor, lineWidth: 3)
                .frame(width: r.width, height: r.height)
                .position(x: r.midX, y: r.midY)
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private var menu: some View {
        let locked = post.isLocked
        Button(adjustTitle) { InstaActions.adjust(slide) }
            .disabled(locked || slide.cells.isEmpty)
        Divider()
        Menu("Layout") {
            ForEach(InstaLayout.allCases, id: \.self) { layout in
                Toggle(isOn: Binding(get: { slide.layout == layout }, set: { if $0 { InstaActions.setLayout(layout, of: slide, model: model) } })) {
                    Label(layout.title, systemImage: layout.systemImage)
                }
            }
        }
        .disabled(locked)
        if post.kind == .post {
            Menu("Split Across Slides") {
                ForEach(1...5, id: \.self) { n in
                    Toggle(n == 1 ? "No Split" : "\(n) Slides", isOn: Binding(get: { slide.span == n },
                                                                           set: { if $0 { InstaActions.setSpan(n, of: slide, model: model) } }))
                }
            }
            .disabled(locked || slide.layout != .single)
            .help("Cut the photo into strips that scroll as one panorama")
        }
        if slide.layout != .single {
            Menu("Background") {
                ForEach(InstaBackground.allCases, id: \.self) { bg in
                    Toggle(bg.title, isOn: Binding(get: { slide.background.uppercased() == bg.hex },
                                                   set: { if $0 { InstaActions.setBackground(bg.hex, of: slide, model: model) } }))
                }
            }
            .disabled(locked)
        }
        Button("Reset Framing") { InstaActions.resetFraming(slide, model: model) }
            .disabled(locked || slide.cells.allSatisfy(\.transform.isIdentity))
        Divider()
        let photoIDs = slide.photoIDs
        Button(photoIDs.count > 1 ? "Select Photos in Grid" : "Select Photo in Grid") { InstaActions.reveal(photoIDs, model: model) }
            .disabled(photoIDs.isEmpty)
        Button("Open in Develop") { if let id = photoIDs.first { model.openInDevelop(id) } }
            .disabled(photoIDs.isEmpty)
        Divider()
        if slide.layout != .single {
            Menu("Remove Photo") {
                ForEach(slide.cells.sorted { $0.index < $1.index }, id: \.index) { c in
                    Button("Cell \(c.index + 1): \(store.photos[c.photoID]?.displayTitle ?? "photo")") {
                        InstaActions.clear(slide: slide, cell: c.index, model: model)
                    }
                }
            }
            .disabled(locked || slide.cells.isEmpty)
        }
        Button(post.kind == .post ? "Delete Slide" : "Delete Frame") { InstaActions.deleteSlide(slide, model: model) }
            .disabled(locked)
    }

    private var adjustTitle: String {
        if slide.span > 1 { return "Adjust Split…" }
        return slide.layout == .single ? "Adjust Photo…" : "Adjust Photos in Layout…"
    }

    private var help: String {
        let names = slide.photoIDs.compactMap { store.photos[$0]?.displayTitle }
        var lines = [names.isEmpty ? "Empty" : names.joined(separator: ", ")]
        if slide.span > 1 { lines.append("Split into \(slide.span) slides on export") }
        if !post.isLocked {
            lines.append("Double-click to scale, rotate and move the photos")
            lines.append("Drop photos on the edges to insert, in the middle to replace · drag to move")
        }
        return lines.joined(separator: "\n")
    }
}

/// Where a drag over a slide would land.
enum InstaSlideDrop: Equatable {
    case before, after
    case cell(Int)
}

struct InstaSlideDropDelegate: DropDelegate {
    let slide: InstaSlide
    let post: InstaPost
    let index: Int
    let size: CGSize
    let rects: [CGRect]
    let model: AppModel
    @Binding var drop: InstaSlideDrop?

    private func target(_ info: DropInfo) -> InstaSlideDrop? {
        guard !post.isLocked else { return nil }
        let p = info.location
        let edge = min(size.width * 0.2, 40)
        switch KikaDrag.current {
        case .photos?:
            if p.x < edge { return .before }
            if p.x > size.width - edge { return .after }
            return rects.firstIndex { $0.contains(p) }.map { .cell($0) } ?? (p.x < size.width / 2 ? .before : .after)
        case .slide(let id)?:
            if id == slide.id { return nil }
            return p.x < size.width / 2 ? .before : .after
        default:
            return nil
        }
    }

    func validateDrop(info: DropInfo) -> Bool { target(info) != nil }
    func dropEntered(info: DropInfo) { drop = target(info) }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        drop = target(info)
        return DropProposal(operation: drop == nil ? .forbidden : (KikaDrag.current.map { if case .slide = $0 { true } else { false } } == true ? .move : .copy))
    }
    func dropExited(info: DropInfo) { drop = nil }

    func performDrop(info: DropInfo) -> Bool {
        guard let where_ = target(info) else { drop = nil; return false }
        drop = nil
        let slide = slide, post = post, index = index, model = model
        KikaDrag.load(info) { payload in
            switch (payload, where_) {
            case (.photos(let ids), .before): InstaActions.addSlides(ids, to: post, at: index, model: model)
            case (.photos(let ids), .after): InstaActions.addSlides(ids, to: post, at: index + 1, model: model)
            case (.photos(let ids), .cell(let i)): InstaActions.fill(slide: slide, from: i, with: ids, model: model)
            case (.slide(let id), .before): InstaActions.moveSlide(id, to: post, at: movedIndex(id, index), model: model)
            case (.slide(let id), .after): InstaActions.moveSlide(id, to: post, at: movedIndex(id, index + 1), model: model)
            default: break
            }
        }
        return true
    }

    /// `moveInstaSlide` indexes among the other slides: a slide moved forward within its post lands one earlier.
    private func movedIndex(_ id: Int64, _ i: Int) -> Int {
        if let from = post.slides.firstIndex(where: { $0.id == id }), from < i { return i - 1 }
        return i
    }
}

/// Backgrounds offered for layout frames.
enum InstaBackground: CaseIterable {
    case white, black, cream, gray

    var title: String {
        switch self {
        case .white: "White"
        case .black: "Black"
        case .cream: "Cream"
        case .gray: "Gray"
        }
    }

    var hex: String {
        switch self {
        case .white: "#FFFFFF"
        case .black: "#000000"
        case .cream: "#F3EDE2"
        case .gray: "#2A2A2A"
        }
    }
}

extension Color {
    /// "#RRGGBB" → sRGB colour; nil if malformed.
    init?(hex: String) {
        let h = hex.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "#", with: "")
        guard h.count == 6, let v = UInt32(h, radix: 16) else { return nil }
        self.init(.sRGB, red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
}
