//
//  InstaAdjustSheet.swift
//  Kika
//
//  Adjust Photos (slide menu, or double-click a slide): the whole slide large, with every photo of its layout, or a
//  split's photo with its frame and cut lines as a guide. Click a photo to select it; the parts outside its cell show
//  faded around the frame.
//  - Drag the photo to move it; drag a corner handle to scale it; drag the round handle above it to rotate it
//    (⇧ snaps to 15°; it also settles on straight within 1°). Pinch and trackpad rotation work too; arrows nudge (⇧ × 10).
//  - Controls for the selected photo: scale, straighten (± 45°) and quarter turns, Fill (covers the cell at this angle),
//    Fit (the whole photo shows), Center, Reset; a split's number of slides.
//  Nothing is saved until Done; Cancel / Esc discards.
//

import AppKit
import SwiftUI

/// The slide the sheet edits (`InstaStore.editingSlideID`).
struct InstaEditTarget: Identifiable {
    var post: InstaPost
    var slide: InstaSlide
    var index: Int
    var id: Int64 { slide.id }
}

struct InstaAdjustSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let post: InstaPost
    let slide: InstaSlide
    let index: Int

    @State private var transforms: [Int: InstaTransform] = [:]
    @State private var span = 1
    @State private var selected = 0
    @State private var imageSizes: [Int: CGSize] = [:]
    @State private var interaction: Interaction?
    @State private var gestureStart: InstaTransform?
    @State private var loaded = false
    @FocusState private var canvasFocused: Bool

    private var store: InstaStore { .shared }
    private var canSplit: Bool { post.kind == .post && slide.layout == .single }
    private var cellIndices: [Int] { slide.cells.map(\.index).sorted() }

    /// Model space: the slide at export size (one frame per split strip).
    private var frameSize: CGSize {
        let one = post.aspect.pixelSize
        return CGSize(width: one.width * CGFloat(canSplit ? span : 1), height: one.height)
    }
    private var cellRects: [CGRect] {
        slide.layout.cellRects(in: frameSize, gap: slide.layout == .single ? 0 : slide.gap)
    }

    private enum Mode { case move, scale, rotate }
    private struct Interaction {
        var mode: Mode
        var cell: Int
        var start: InstaTransform
        var origin: CGPoint
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            GeometryReader { geo in canvas(in: geo.size) }
                .background(Color(white: 0.11))
            Divider()
            controls
            Divider()
            footer
        }
        .frame(minWidth: 980, idealWidth: 1100, minHeight: 760, idealHeight: 860)
        .onAppear {
            guard !loaded else { return }
            loaded = true
            transforms = Dictionary(uniqueKeysWithValues: slide.cells.map { ($0.index, $0.transform) })
            span = slide.span
            selected = cellIndices.first ?? 0
            canvasFocused = true
        }
    }

    // MARK: Header / footer

    private var header: some View {
        HStack(spacing: 8) {
            Text(title).font(.headline)
            Text("— \(post.title), \(post.kind == .post ? "slide" : "frame") \(index + 1)").foregroundStyle(.secondary)
            Spacer()
            Text("Drag to move · corners scale · round handle rotates (⇧ snaps)")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
    }

    private var title: String {
        if canSplit && span > 1 { return "Adjust Split" }
        return slide.layout == .single ? "Adjust Photo" : "Adjust Photos in Layout"
    }

    private var footer: some View {
        HStack {
            Button("Reset All") {
                for i in cellIndices { transforms[i] = InstaTransform() }
            }
            .disabled(transforms.values.allSatisfy(\.isIdentity))
            Spacer()
            Button("Cancel", role: .cancel) { close() }
                .keyboardShortcut(.cancelAction)
            Button("Done") { save(); close() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private func save() {
        let changed = transforms.filter { i, t in slide.cell(i)?.transform != t }
        InstaActions.setTransforms(changed, slideID: slide.id, model: model)
        if canSplit && span != slide.span { InstaActions.setSpan(span, of: slide, model: model) }
    }

    private func close() {
        store.editingSlideID = nil
        dismiss()
    }

    // MARK: Canvas

    /// Display scale and the frame's origin in the canvas: the slide takes ~70% so overflow shows around it.
    private func layout(_ size: CGSize) -> (k: CGFloat, origin: CGPoint) {
        let k = max(0.01, min(size.width * 0.72 / frameSize.width, size.height * 0.72 / frameSize.height))
        return (k, CGPoint(x: (size.width - frameSize.width * k) / 2, y: (size.height - frameSize.height * k) / 2))
    }

    private func displayRect(_ i: Int, _ l: (k: CGFloat, origin: CGPoint)) -> CGRect? {
        guard cellRects.indices.contains(i) else { return nil }
        let r = cellRects[i]
        return CGRect(x: l.origin.x + r.minX * l.k, y: l.origin.y + r.minY * l.k, width: r.width * l.k, height: r.height * l.k)
    }

    /// The selected photo's placement in canvas coordinates.
    private func placement(_ i: Int, _ l: (k: CGFloat, origin: CGPoint)) -> InstaFraming.Placement? {
        guard let d = displayRect(i, l), let size = imageSizes[i], let t = transforms[i] else { return nil }
        var p = InstaFraming.placement(imageSize: size, cellSize: d.size, transform: t)
        p.center = CGPoint(x: d.minX + p.center.x, y: d.minY + p.center.y)
        return p
    }

    private func canvas(in size: CGSize) -> some View {
        let l = layout(size)
        let frame = CGRect(origin: l.origin, size: CGSize(width: frameSize.width * l.k, height: frameSize.height * l.k))
        return ZStack(alignment: .topLeading) {
            Color.clear
            ghost(l, opacity: 0.4)                           // the selected photo beyond its cell (behind the slide)
            Rectangle().fill(Color(hex: slide.background) ?? .white)
                .frame(width: frame.width, height: frame.height)
                .position(x: frame.midX, y: frame.midY)
            ForEach(cellIndices.filter { cellRects.indices.contains($0) }, id: \.self) { i in
                if let d = displayRect(i, l) { cellPhoto(i, size: d.size).position(x: d.midX, y: d.midY) }
            }
            if interaction != nil { ghost(l, opacity: 0.3) }   // while adjusting, also over the neighbours
            guides(l, frame: frame)
            handles(l)
        }
        .frame(width: size.width, height: size.height)
        .clipped()
        .contentShape(Rectangle())
        .gesture(dragGesture(l))
        .simultaneousGesture(MagnifyGesture().onChanged { v in
            let start = gestureStart ?? transforms[selected] ?? InstaTransform()
            gestureStart = start
            transforms[selected]?.scale = clampScale(start.scale * v.magnification)
        }.onEnded { _ in gestureStart = nil })
        .simultaneousGesture(RotateGesture().onChanged { v in
            let start = gestureStart ?? transforms[selected] ?? InstaTransform()
            gestureStart = start
            transforms[selected]?.rotation = start.rotation + v.rotation.degrees
        }.onEnded { _ in gestureStart = nil })
        .focusable()
        .focused($canvasFocused)
        .focusEffectDisabled()
        .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow]) { press in
            nudge(press.key, by: press.modifiers.contains(.shift) ? 10 : 1, l)
            return .handled
        }
    }

    private func cellPhoto(_ i: Int, size: CGSize) -> some View {
        Group {
            if let c = slide.cell(i), let photo = store.photos[c.photoID] {
                InstaPhotoView(photo: photo, transform: transforms[i] ?? c.transform, cellSize: size, level: .standard,
                               imageSize: imageSizeBinding(i))
                    .clipped()
            } else {
                Rectangle().fill(Color.secondary.opacity(0.15)).frame(width: size.width, height: size.height)
            }
        }
    }

    @ViewBuilder
    private func ghost(_ l: (k: CGFloat, origin: CGPoint), opacity: Double) -> some View {
        if let d = displayRect(selected, l), let c = slide.cell(selected), let photo = store.photos[c.photoID] {
            InstaPhotoView(photo: photo, transform: transforms[selected] ?? c.transform, cellSize: d.size, level: .standard,
                           imageSize: imageSizeBinding(selected))
                .opacity(opacity)
                .allowsHitTesting(false)
                .position(x: d.midX, y: d.midY)
        }
    }

    private func imageSizeBinding(_ i: Int) -> Binding<CGSize?> {
        Binding(get: { imageSizes[i] }, set: { imageSizes[i] = $0 })
    }

    /// Frame outline, cell outlines (selected in the accent colour), a split's cut lines, centre guides while snapped.
    private func guides(_ l: (k: CGFloat, origin: CGPoint), frame: CGRect) -> some View {
        ZStack(alignment: .topLeading) {
            Path { $0.addRect(frame) }.stroke(.white.opacity(0.85), lineWidth: 1)
            if slide.layout != .single {
                ForEach(cellIndices.filter { $0 != selected }, id: \.self) { i in
                    if let d = displayRect(i, l) { Path { $0.addRect(d) }.stroke(.white.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [4, 3])) }
                }
            }
            if let d = displayRect(selected, l), slide.layout != .single {
                Path { $0.addRect(d) }.stroke(Color.accentColor, lineWidth: 2)
            }
            if canSplit && span > 1 {
                ForEach(1..<span, id: \.self) { k in
                    let x = frame.minX + frame.width * CGFloat(k) / CGFloat(span)
                    Path { p in p.move(to: CGPoint(x: x, y: frame.minY - 14)); p.addLine(to: CGPoint(x: x, y: frame.maxY + 14)) }
                        .stroke(.white.opacity(0.9), style: StrokeStyle(lineWidth: 1, dash: [6, 4]))
                }
                ForEach(0..<span, id: \.self) { k in
                    Text("\(index + 1 + k)")
                        .font(.caption.weight(.semibold)).monospacedDigit()
                        .foregroundStyle(.white.opacity(0.8))
                        .position(x: frame.minX + frame.width * (CGFloat(k) + 0.5) / CGFloat(span), y: frame.maxY + 14)
                }
            }
            if interaction?.mode == .move, let d = displayRect(selected, l), let t = transforms[selected] {
                if t.offsetX == 0 { Path { p in p.move(to: CGPoint(x: d.midX, y: d.minY)); p.addLine(to: CGPoint(x: d.midX, y: d.maxY)) }.stroke(.yellow, lineWidth: 1) }
                if t.offsetY == 0 { Path { p in p.move(to: CGPoint(x: d.minX, y: d.midY)); p.addLine(to: CGPoint(x: d.maxX, y: d.midY)) }.stroke(.yellow, lineWidth: 1) }
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: Handles

    private static let handleRadius: CGFloat = 6
    private static let knobDistance: CGFloat = 26

    private func corners(_ p: InstaFraming.Placement) -> [CGPoint] {
        [(-1.0, -1.0), (1, -1), (1, 1), (-1, 1)].map { sx, sy in rotate(CGPoint(x: sx * p.size.width / 2, y: sy * p.size.height / 2), p) }
    }

    private func knob(_ p: InstaFraming.Placement) -> CGPoint { rotate(CGPoint(x: 0, y: -p.size.height / 2 - Self.knobDistance), p) }

    /// A point in the photo's own frame (centre origin) → canvas.
    private func rotate(_ q: CGPoint, _ p: InstaFraming.Placement) -> CGPoint {
        let c = cos(p.radians), s = sin(p.radians)
        return CGPoint(x: p.center.x + q.x * c - q.y * s, y: p.center.y + q.x * s + q.y * c)
    }

    @ViewBuilder
    private func handles(_ l: (k: CGFloat, origin: CGPoint)) -> some View {
        if let p = placement(selected, l) {
            let cs = corners(p)
            let top = rotate(CGPoint(x: 0, y: -p.size.height / 2), p)
            let k = knob(p)
            ZStack(alignment: .topLeading) {
                Path { path in path.addLines(cs); path.closeSubpath() }.stroke(Color.accentColor, lineWidth: 1)
                Path { path in path.move(to: top); path.addLine(to: k) }.stroke(Color.accentColor, lineWidth: 1)
                ForEach(0..<4, id: \.self) { i in
                    Rectangle().fill(.white).frame(width: Self.handleRadius * 2, height: Self.handleRadius * 2)
                        .overlay(Rectangle().stroke(Color.accentColor, lineWidth: 1.5))
                        .rotationEffect(.radians(Double(p.radians)))
                        .position(cs[i])
                }
                Circle().fill(.white).frame(width: Self.handleRadius * 2 + 2, height: Self.handleRadius * 2 + 2)
                    .overlay(Circle().stroke(Color.accentColor, lineWidth: 1.5))
                    .overlay(Image(systemName: "arrow.clockwise").font(.system(size: 7, weight: .bold)).foregroundStyle(Color.accentColor))
                    .position(k)
            }
            .allowsHitTesting(false)
        }
    }

    // MARK: Gestures

    private func dragGesture(_ l: (k: CGFloat, origin: CGPoint)) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { v in
                if interaction == nil { interaction = begin(at: v.startLocation, l) }
                guard let it = interaction else { return }
                update(it, to: v.location, l)
            }
            .onEnded { _ in interaction = nil }
    }

    /// What a drag starting at `point` does: the selected photo's knob rotates, its corners scale; a press in a cell
    /// selects that photo and moves it; a press on the selected photo's overflow moves it too.
    private func begin(at point: CGPoint, _ l: (k: CGFloat, origin: CGPoint)) -> Interaction? {
        canvasFocused = true
        if let p = placement(selected, l), let t = transforms[selected] {
            if distance(point, knob(p)) <= Self.handleRadius + 5 { return Interaction(mode: .rotate, cell: selected, start: t, origin: point) }
            if corners(p).contains(where: { distance(point, $0) <= Self.handleRadius + 5 }) {
                return Interaction(mode: .scale, cell: selected, start: t, origin: point)
            }
        }
        if let i = cellIndices.first(where: { displayRect($0, l)?.contains(point) == true }), let t = transforms[i] {
            selected = i
            return Interaction(mode: .move, cell: i, start: t, origin: point)
        }
        if let p = placement(selected, l), contains(p, point), let t = transforms[selected] {
            return Interaction(mode: .move, cell: selected, start: t, origin: point)
        }
        return nil
    }

    private func update(_ it: Interaction, to point: CGPoint, _ l: (k: CGFloat, origin: CGPoint)) {
        guard let d = displayRect(it.cell, l) else { return }
        var t = it.start
        switch it.mode {
        case .move:
            t.offsetX = snap(it.start.offsetX + Double((point.x - it.origin.x) / d.width), within: 5 / Double(d.width))
            t.offsetY = snap(it.start.offsetY + Double((point.y - it.origin.y) / d.height), within: 5 / Double(d.height))
        case .scale:
            guard let p = placement(it.cell, l) else { return }
            let r0 = distance(it.origin, p.center), r1 = distance(point, p.center)
            if r0 > 1 { t.scale = clampScale(it.start.scale * Double(r1 / r0)) }
        case .rotate:
            guard let p = placement(it.cell, l) else { return }
            let a0 = atan2(it.origin.y - p.center.y, it.origin.x - p.center.x)
            let a1 = atan2(point.y - p.center.y, point.x - p.center.x)
            var r = it.start.rotation + Double(a1 - a0) * 180 / .pi
            if NSEvent.modifierFlags.contains(.shift) { r = (r / 15).rounded() * 15 }
            else if abs(r - (r / 90).rounded() * 90) < 1 { r = (r / 90).rounded() * 90 }   // settles on straight
            t.rotation = r
        }
        transforms[it.cell] = t
    }

    private func nudge(_ key: KeyEquivalent, by points: CGFloat, _ l: (k: CGFloat, origin: CGPoint)) {
        guard let d = displayRect(selected, l), var t = transforms[selected] else { return }
        switch key {
        case .leftArrow: t.offsetX -= Double(points / d.width)
        case .rightArrow: t.offsetX += Double(points / d.width)
        case .upArrow: t.offsetY -= Double(points / d.height)
        default: t.offsetY += Double(points / d.height)
        }
        transforms[selected] = t
    }

    private func contains(_ p: InstaFraming.Placement, _ q: CGPoint) -> Bool {
        let dx = q.x - p.center.x, dy = q.y - p.center.y
        let c = cos(-p.radians), s = sin(-p.radians)
        return abs(dx * c - dy * s) <= p.size.width / 2 && abs(dx * s + dy * c) <= p.size.height / 2
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }
    private func snap(_ v: Double, within: Double) -> Double { abs(v) < within ? 0 : v }
    private func clampScale(_ s: Double) -> Double { min(max(s, InstaTransform.scaleRange.lowerBound), 4) }

    // MARK: Controls

    private var selectedTransform: Binding<InstaTransform> {
        Binding(get: { transforms[selected] ?? InstaTransform() }, set: { transforms[selected] = $0 })
    }

    /// Rotation = quarter turns × 90° + a straightening angle within ±45°.
    private var quarter: Int { Int((selectedTransform.wrappedValue.rotation / 90).rounded()) }

    private var controls: some View {
        let t = selectedTransform
        let cellSize = cellRects.indices.contains(selected) ? cellRects[selected].size : frameSize
        let image = imageSizes[selected]
        return VStack(alignment: .leading, spacing: 8) {
          HStack(spacing: 18) {
            if cellIndices.count > 1 {
                Picker("Photo", selection: $selected) {
                    ForEach(cellIndices, id: \.self) { Text("\($0 + 1)").tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .help("The photo to adjust (or click it)")
            }
            HStack(spacing: 6) {
                Image(systemName: "minus.magnifyingglass").foregroundStyle(.secondary)
                Slider(value: Binding(get: { t.wrappedValue.scale }, set: { t.wrappedValue.scale = $0 }), in: 0.1...4)
                    .frame(width: 140)
                Image(systemName: "plus.magnifyingglass").foregroundStyle(.secondary)
                Text("\(Int((t.wrappedValue.scale * 100).rounded()))%").monospacedDigit().frame(width: 44, alignment: .trailing)
            }
            .help("Scale (100% just fills the cell)")
            HStack(spacing: 6) {
                Button { t.wrappedValue.rotation -= 90 } label: { Image(systemName: "rotate.left") }
                    .buttonStyle(.borderless).help("Rotate 90° left")
                Slider(value: Binding(get: { t.wrappedValue.rotation - Double(quarter) * 90 },
                                      set: { t.wrappedValue.rotation = Double(quarter) * 90 + $0 }), in: -45...45)
                    .frame(width: 140)
                    .help("Straighten (± 45°)")
                Button { t.wrappedValue.rotation += 90 } label: { Image(systemName: "rotate.right") }
                    .buttonStyle(.borderless).help("Rotate 90° right")
                Text(String(format: "%.1f°", t.wrappedValue.clamped.rotation)).monospacedDigit().frame(width: 52, alignment: .trailing)
            }
            Spacer(minLength: 0)
            if canSplit {
                Picker("Slides", selection: $span) {
                    ForEach(1...5, id: \.self) { Text($0 == 1 ? "No split" : "\($0) slides").tag($0) }
                }
                .fixedSize()
                .help("Split this photo across carousel slides")
            }
          }
          HStack(spacing: 18) {
            HStack(spacing: 6) {
                Button("Fill") {
                    guard let image else { return }
                    t.wrappedValue = InstaTransform(scale: InstaFraming.coverScale(imageSize: image, cellSize: cellSize, rotation: t.wrappedValue.rotation),
                                                    rotation: t.wrappedValue.rotation)
                }
                .help("Cover the whole cell at this angle, centred")
                Button("Fit") {
                    guard let image else { return }
                    t.wrappedValue = InstaTransform(scale: InstaFraming.fitScale(imageSize: image, cellSize: cellSize, rotation: t.wrappedValue.rotation),
                                                    rotation: t.wrappedValue.rotation)
                }
                .help("Show the whole photo, centred")
                Button("Center") { t.wrappedValue.offsetX = 0; t.wrappedValue.offsetY = 0 }
                Button("Reset") { t.wrappedValue = InstaTransform() }
            }
            .fixedSize()
            .disabled(slide.cell(selected) == nil)
            Spacer(minLength: 0)
            if let image, !InstaFraming.covers(imageSize: image, cellSize: cellSize, transform: t.wrappedValue) {
                Label("Background shows", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange).font(.callout)
                    .fixedSize()
                    .help("The photo doesn't cover its whole cell; the slide background shows in the gap. Fill covers it again.")
            }
          }
        }
        .controlSize(.small)
        .padding(.horizontal, 14).padding(.vertical, 9)
    }
}
