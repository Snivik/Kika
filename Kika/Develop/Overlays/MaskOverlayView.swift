//
//  MaskOverlayView.swift
//  Kika
//
//  Mask tool overlay (shown while `session.activeTool == .mask`; the canvas shows the cropped
//  image). Draws pins (the selected mask's parts get small ones), the selected shape's lines / handles, the
//  brush cursor, the red coverage overlay and, while picking objects, every object found tinted (the one under
//  the pointer brighter: ObjectPreviewRenderer); forwards drags to MaskInteraction (hit testing + editing).
//
//  Pointer: brush = a + / − in the drawn circle, Pick Object = a pointing finger (+ / −), creating = crosshair.
//  ⌥ is watched (flagsChanged), so the pointer turns to − as soon as it goes down, not on the next move.
//
//  Keys (registry actions via the shortcut dispatcher, active while the mask tool is; defaults):
//  O overlay, [ / ] brush size, Esc cancel creation / stop painting / leave the tool, ⌫ delete the selected
//  part or mask. ⌥ while painting erases, while picking removes. The brush size is a SCREEN size
//  (MaskToolState), so the cursor keeps its size at any zoom and strokes painted zoomed in are finer.
//

import AppKit
import SwiftUI

struct MaskOverlayView: View {
    let session: DevelopSession
    /// Where the displayed image is drawn, in this view's coordinates.
    let imageRect: CGRect

    @State private var tool = MaskToolState.shared
    @State private var coverage = MaskCoverageRenderer()
    @State private var objectPreview = ObjectPreviewRenderer()
    @State private var interaction = MaskInteraction()
    @State private var cursor: CGPoint?
    @State private var flagsMonitor: Any?
    @FocusState private var focused: Bool

    var body: some View {
        let space = MaskSpace(geometry: session.canvasGeometry(imageRect: imageRect))
        ZStack(alignment: .topLeading) {
            if tool.showOverlay, let image = coverage.image {
                overlayImage(image)
            }
            if tool.pendingKind == .object {
                let hovered = hoveredObject(space)
                ForEach(objectPreview.images.indices, id: \.self) { i in
                    overlayImage(objectPreview.images[i])
                        .opacity(hovered == i ? 0.6 : hovered == nil ? 0.32 : 0.15)
                }
            }
            Canvas { ctx, _ in draw(&ctx, space: space) }
        }
        .contentShape(Rectangle())
        .canvasPointer(pointer, rank: 1)
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .local)
                .onChanged { value in
                    focused = true
                    cursor = value.location
                    interaction.dragChanged(start: value.startLocation, location: value.location, space: space,
                                            session: session, tool: tool,
                                            erase: tool.pendingKind == .object ? optionDown : eraseRequested)
                }
                .onEnded { value in
                    interaction.dragEnded(location: value.location, space: space, session: session)
                }
        )
        .onContinuousHover { phase in
            if case .active(let p) = phase { cursor = p } else if !interaction.isDragging { cursor = nil }
        }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .shortcutHandlers(id: ObjectIdentifier(session)) { [session, tool] in Self.keyHandlers(session: session, tool: tool) }
        .onAppear {
            focused = true
            tool.optionHeld = NSEvent.modifierFlags.contains(.option)
            flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [tool] event in
                tool.optionHeld = event.modifierFlags.contains(.option)
                return event
            }
        }
        .onDisappear {
            tool.cancelPending()
            tool.refining = false
            tool.optionHeld = false
            if let flagsMonitor { NSEvent.removeMonitor(flagsMonitor) }
            flagsMonitor = nil
        }
        .onChange(of: coverageRequest, initial: true) { _, request in
            if let request { coverage.request(request) } else { coverage.clear() }
        }
        .onChange(of: objectRequest, initial: true) { _, request in
            if let request { objectPreview.request(request) }
        }
    }

    private func overlayImage(_ image: CGImage) -> some View {
        Image(decorative: image, scale: 1)
            .resizable()
            .frame(width: imageRect.width, height: imageRect.height)
            .position(x: imageRect.midX, y: imageRect.midY)
            .allowsHitTesting(false)
    }

    private var optionDown: Bool { tool.optionHeld || NSEvent.modifierFlags.contains(.option) }
    /// Erase mode, or ⌥ for the other one.
    private var eraseRequested: Bool { tool.eraseMode != optionDown }

    private var pointer: CanvasCursor? {
        if tool.pendingKind == .object { return .pick(subtract: tool.picksToSubtract) }
        if session.isBrushing { return .brush(erase: interaction.isDragging ? interaction.isErasing : eraseRequested) }
        return tool.pendingKind != nil ? .crosshair : nil
    }

    /// Objects are found while picking (and kept, so picking again shows them at once).
    private var objectRequest: ObjectPreviewRenderer.Request? {
        guard tool.pendingKind == .object, let source = session.source else { return nil }
        return .init(source: source, geometry: session.settings.geometry, fullSize: session.orientedSize, targetSize: session.viewPixelSize)
    }

    /// The previewed object under the pointer.
    private func hoveredObject(_ space: MaskSpace) -> Int? {
        guard let c = cursor, space.isValid, imageRect.contains(c), let objects = objectPreview.objects else { return nil }
        return objects.index(at: space.geometry.maskPoint(fromView: c))
    }

    private var coverageRequest: MaskCoverageRenderer.Request? {
        guard tool.showOverlay, let mask = session.selectedMask else { return nil }
        return .init(mask: mask, geometry: session.settings.geometry, fullSize: session.orientedSize,
                     targetSize: session.viewPixelSize, source: session.source)
    }

    /// Mask tool keys (registry actions, scope Mask Tool; defaults O, [ / ], ⌫ (also ⌦), Esc).
    private static func keyHandlers(session: DevelopSession, tool: MaskToolState) -> [ShortcutHandler] {
        [
            ShortcutHandler(.maskCancel) { [weak session] _ in
                if tool.pendingKind != nil { tool.cancelPending() }
                else if tool.refining { tool.refining = false }
                else { session?.finishMasking() }
            },
            ShortcutHandler(.maskOverlay) { _ in tool.showOverlay.toggle() },
            ShortcutHandler(.brushSmaller) { _ in tool.stepBrushSize(up: false) },
            ShortcutHandler(.brushLarger) { _ in tool.stepBrushSize(up: true) },
            ShortcutHandler(.deleteMask, when: { [weak session] _ in session?.selectedMaskID != nil }) { [weak session] _ in
                if let session, let ref = session.selectedRef { session.deletePart(ref) }   // the main shape: the mask
            },
        ]
    }

    // MARK: - Drawing

    private func draw(_ ctx: inout GraphicsContext, space: MaskSpace) {
        guard space.isValid else { return }
        let selected = tool.pendingKind == nil ? session.selectedShape : nil
        var clipped = ctx
        clipped.clip(to: Path(imageRect))
        if let m = selected?.linear { drawLinear(m, lines: clipped, handles: ctx, space: space) }
        if let m = selected?.radial { drawRadial(m, ctx: ctx, space: space) }
        for mask in session.settings.masks {
            guard let p = mask.pinPoint else { continue }
            drawPin(space.view(space.px(p)), selected: mask.id == session.selectedMaskID && session.selectedPartID == nil,
                    enabled: mask.isEnabled, in: ctx)
        }
        if let mask = session.selectedMask {
            for part in mask.parts {
                guard let p = part.shape.pinPoint else { continue }
                drawPartPin(space.view(space.px(p)), subtract: part.mode == .subtract && part.shape.brush == nil,
                            selected: part.id == session.selectedPartID, in: ctx)
            }
        }
        if session.isBrushing, let c = cursor { drawBrushCursor(at: c, space: space, in: ctx) }
    }

    private func drawLinear(_ m: LinearGradientMask, lines: GraphicsContext, handles: GraphicsContext, space: MaskSpace) {
        let h = LinearHandles(m, space: space)
        outline(segment(h.viewLine(through: h.start)), in: lines)
        outline(segment(h.viewLine(through: h.mid)), in: lines)
        outline(segment(h.viewLine(through: h.end)), in: lines, dash: [5, 4])
        outline(segment((space.view(h.mid), h.rotateHandle)), in: handles, width: 0.75)
        drawHandle(h.rotateHandle, round: true, in: handles)
    }

    private func drawRadial(_ m: RadialGradientMask, ctx: GraphicsContext, space: MaskSpace) {
        let h = RadialHandles(m, space: space)
        outline(polygon(h.viewEllipse(scale: 1)), in: ctx)
        let inner = 1 - min(max(m.feather, 0), 100) / 100
        if inner > 0.02 { outline(polygon(h.viewEllipse(scale: inner)), in: ctx, dash: [4, 4]) }
        for p in [h.xPlus, h.xMinus, h.yPlus, h.yMinus] { drawHandle(space.view(p), round: false, in: ctx) }
        outline(segment((space.view(h.yMinus), h.rotateHandle)), in: ctx, width: 0.75)
        drawHandle(h.rotateHandle, round: true, in: ctx)
    }

    private func drawBrushCursor(at c: CGPoint, space: MaskSpace, in ctx: GraphicsContext) {
        let outer = tool.brushScreenRadius   // screen size: the same at any zoom
        let inner = outer * (1 - tool.brushFeather / 100)
        outline(Path(ellipseIn: CGRect(x: c.x - outer, y: c.y - outer, width: 2 * outer, height: 2 * outer)), in: ctx)
        if inner > 1 {
            outline(Path(ellipseIn: CGRect(x: c.x - inner, y: c.y - inner, width: 2 * inner, height: 2 * inner)), in: ctx, dash: [3, 3])
        }
    }

    private func segment(_ ends: (CGPoint, CGPoint)) -> Path {
        var p = Path()
        p.move(to: ends.0)
        p.addLine(to: ends.1)
        return p
    }

    private func polygon(_ points: [CGPoint]) -> Path {
        var p = Path()
        p.addLines(points)
        p.closeSubpath()
        return p
    }

    private func outline(_ path: Path, in ctx: GraphicsContext, width: CGFloat = 1, dash: [CGFloat] = []) {
        ctx.stroke(path, with: .color(.black.opacity(0.55)), style: StrokeStyle(lineWidth: width + 2, lineCap: .round, dash: dash))
        ctx.stroke(path, with: .color(.white), style: StrokeStyle(lineWidth: width, lineCap: .round, dash: dash))
    }

    private func drawHandle(_ p: CGPoint, round: Bool, in ctx: GraphicsContext) {
        let r: CGFloat = 4
        let rect = CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)
        let path = round ? Path(ellipseIn: rect) : Path(rect)
        ctx.fill(path, with: .color(.white))
        ctx.stroke(path, with: .color(.black.opacity(0.7)), lineWidth: 1)
    }

    /// A part's pin: a small square with + or −.
    private func drawPartPin(_ p: CGPoint, subtract: Bool, selected: Bool, in ctx: GraphicsContext) {
        let r: CGFloat = selected ? 6 : 5
        let box = Path(roundedRect: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r), cornerRadius: 2)
        ctx.fill(box, with: .color(selected ? .accentColor : .white))
        ctx.stroke(box, with: .color(.black.opacity(0.7)), lineWidth: 1)
        var sign = Path()
        sign.move(to: CGPoint(x: p.x - 3, y: p.y)); sign.addLine(to: CGPoint(x: p.x + 3, y: p.y))
        if !subtract { sign.move(to: CGPoint(x: p.x, y: p.y - 3)); sign.addLine(to: CGPoint(x: p.x, y: p.y + 3)) }
        ctx.stroke(sign, with: .color(selected ? .white : .black), lineWidth: 1.5)
    }

    private func drawPin(_ p: CGPoint, selected: Bool, enabled: Bool, in ctx: GraphicsContext) {
        let r: CGFloat = selected ? 7 : 5.5
        let dot = Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r))
        ctx.fill(dot, with: .color(selected ? .accentColor : .white.opacity(enabled ? 1 : 0.5)))
        ctx.stroke(dot, with: .color(.black.opacity(0.7)), lineWidth: 1)
        if selected {
            ctx.fill(Path(ellipseIn: CGRect(x: p.x - 2, y: p.y - 2, width: 4, height: 4)), with: .color(.white))
        }
    }
}
