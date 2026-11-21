//
//  MaskInteraction.swift
//  Kika
//
//  Mouse interaction of the mask tool, kept out of the SwiftUI view so the harness can drive
//  it (Tools/masks_check.swift). MaskOverlayView feeds it drag events in view coordinates.
//
//  Editing math is done in SOURCE PIXELS (oriented, uncropped, full resolution) so angles and
//  distances are aspect-correct; `MaskSpace` converts to/from view coordinates through
//  CanvasGeometry, so crop / rotate / flip are handled for free.
//
//  - Pins: click one to select that mask (drag to move linear / radial); the selected mask's parts have small
//    pins of their own (select / move that part). Handles belong to the selected shape (main or part).
//  - Linear: drag the center pin or line to move, the start / end line to change the feather
//    width, the handle on the center line to rotate.
//  - Radial: side handles resize X / Y, the top handle rotates, dragging inside moves.
//  - Brush: paints strokes (points decimated while painting, simplified at the end);
//    `erase` (⌥ or Erase mode) paints eraser strokes. A brush mask paints, and so does any mask while
//    `MaskToolState.refining` (into its brush part: `Mask.brushTarget`).
//  - Pending creation: a drag creates the shape (a click creates a default size) — a new mask, or a part of
//    `MaskToolState.addingTo`. Pick Object: each click picks the object under it (⌥ = the other mode).
//

import Foundation
import CoreGraphics

struct MaskInteraction {
    enum DragOp {
        /// Creating a shape of a kind; the reference is set once it exists.
        case create(MaskKind, MaskRef?)
        case move(MaskRef, original: MaskShape, from: CGPoint)
        case linearStart(MaskRef), linearEnd(MaskRef), linearRotate(MaskRef)
        case radialX(MaskRef), radialY(MaskRef), radialRotate(MaskRef)
        /// Painting `stroke` into a brush; `appended` once stored.
        case paint(PaintTarget, BrushStroke, appended: Bool)
        /// The drag started on nothing editable.
        case idle
    }

    enum PaintTarget {
        /// Creates a brush mask.
        case newMask
        /// Creates a brush part of this mask.
        case newPart(UUID)
        case brush(MaskRef)
    }

    static let hitRadius: CGFloat = 8

    private(set) var op: DragOp?
    /// ⌥ / Erase at the start of the drag.
    private var optionAtStart = false
    var isDragging: Bool { op != nil }

    /// Eraser stroke in progress?
    var isErasing: Bool {
        if case .paint(_, let stroke, _)? = op { return stroke.isEraser }
        return false
    }

    // MARK: Events

    mutating func dragChanged(start: CGPoint, location: CGPoint, space: MaskSpace, session: DevelopSession,
                              tool: MaskToolState, erase: Bool) {
        guard space.isValid else { return }
        if op == nil {
            session.commitUndoGroup()
            optionAtStart = erase
            op = beginDrag(at: start, space: space, session: session, tool: tool, erase: erase)
        }
        guard let current = op else { return }
        let p = space.pixel(fromView: location)
        let a = space.pixel(fromView: start)
        let moved = hypot(location.x - start.x, location.y - start.y) > 3

        switch current {
        case .create(let kind, let ref):
            guard moved, kind.aiTarget == nil else { return }   // found masks are clicked, not drawn
            if let ref { updateCreated(kind, ref, from: a, to: p, space: space, session: session) }
            else { op = .create(kind, createShape(kind, from: a, to: p, space: space, session: session)) }
        case .move(let ref, let original, let from):
            let d = MaskVec(p) - MaskVec(from)
            session.updateShape(ref) { shape in
                if var l = original.linear {
                    l.start = space.norm((MaskVec(space.px(l.start)) + d).cg)
                    l.end = space.norm((MaskVec(space.px(l.end)) + d).cg)
                    shape = .linear(l)
                } else if var r = original.radial {
                    r.center = space.norm((MaskVec(space.px(r.center)) + d).cg)
                    shape = .radial(r)
                }
            }
        case .linearStart(let ref), .linearEnd(let ref), .linearRotate(let ref):
            session.updateShape(ref) { shape in
                guard let l = shape.linear else { return }
                shape = .linear(Self.editLinear(l, op: current, to: p, space: space))
            }
        case .radialX(let ref), .radialY(let ref), .radialRotate(let ref):
            session.updateShape(ref) { shape in
                guard let r = shape.radial else { return }
                shape = .radial(Self.editRadial(r, op: current, to: p, space: space))
            }
        case .paint(let target, var stroke, let appended):
            if MaskEditing.append(space.norm(p), to: &stroke, aspect: space.aspect) || !appended {
                op = .paint(store(stroke, in: target, appended: appended, session: session), stroke, appended: true)
            } else {
                op = .paint(target, stroke, appended: appended)
            }
        case .idle:
            break
        }
    }

    mutating func dragEnded(location: CGPoint, space: MaskSpace, session: DevelopSession) {
        defer {
            op = nil
            session.commitUndoGroup()
        }
        guard space.isValid, let current = op else { return }
        let p = space.pixel(fromView: location)
        switch current {
        case .create(.object, nil):
            pickObject(at: space.norm(p), flip: optionAtStart, session: session)
        case .create(let kind, nil) where kind.aiTarget != nil:
            break
        case .create(let kind, nil):
            // A click without dragging: default-sized shape at the click point.
            let to = kind == .linear ? CGPoint(x: p.x, y: p.y + 0.25 * space.h) : CGPoint(x: p.x + 0.15 * space.w, y: p.y + 0.15 * space.w)
            createShape(kind, from: p, to: to, space: space, session: session)
        case .paint(let target, var stroke, let appended):
            MaskEditing.append(space.norm(p), to: &stroke, aspect: space.aspect, force: true)
            MaskEditing.finish(&stroke, aspect: space.aspect)
            store(stroke, in: target, appended: appended, session: session)
        default:
            break
        }
    }

    // MARK: Hit testing

    private func beginDrag(at v: CGPoint, space: MaskSpace, session: DevelopSession, tool: MaskToolState, erase: Bool) -> DragOp {
        if let kind = tool.pendingKind {
            return kind == .brush ? beginPaint(.newMask, tool: tool, erase: erase, space: space) : .create(kind, nil)
        }
        func onPin(_ pin: NormPoint?) -> Bool {
            guard let pin else { return false }
            return MaskVec(space.view(space.px(pin))).distance(to: MaskVec(v)) <= Self.hitRadius
        }
        func grab(_ ref: MaskRef, _ shape: MaskShape) -> DragOp {
            shape.linear != nil || shape.radial != nil ? .move(ref, original: shape, from: space.pixel(fromView: v)) : .idle
        }
        if let ref = session.selectedRef, let shape = session.shape(ref), let hit = Self.handleHit(shape, ref: ref, at: v, space: space) {
            return hit
        }
        // The selected mask's part pins: select (and move) that part.
        if let mask = session.selectedMask {
            for part in mask.parts.reversed() where part.id != session.selectedPartID && onPin(part.shape.pinPoint) {
                let ref = MaskRef(mask: mask.id, part: part.id)
                session.selectPart(ref)
                return grab(ref, part.shape)
            }
        }
        // Main pins: select (and move) that mask.
        for mask in session.settings.masks.reversed() where onPin(mask.pinPoint) {
            if mask.id == session.selectedMaskID && session.selectedPartID == nil { continue }
            session.selectMask(mask.id)
            return grab(MaskRef(mask: mask.id), mask.shape)
        }
        if session.isBrushing, let mask = session.selectedMask {
            return beginPaint(mask.brushTarget.map(PaintTarget.brush) ?? .newPart(mask.id), tool: tool, erase: erase, space: space)
        }
        return .idle
    }

    private func beginPaint(_ target: PaintTarget, tool: MaskToolState, erase: Bool, space: MaskSpace) -> DragOp {
        var stroke = BrushStroke()
        stroke.radius = tool.brushRadius(in: space.geometry)   // screen size → image units at this zoom
        stroke.feather = tool.brushFeather
        stroke.flow = tool.brushFlow
        stroke.isEraser = erase
        if erase, case .newMask = target { return .idle } // nothing to erase from
        return .paint(target, stroke, appended: false)
    }

    /// Hit-tests the handles of the selected shape (view coordinates).
    static func handleHit(_ shape: MaskShape, ref: MaskRef, at v: CGPoint, space: MaskSpace) -> DragOp? {
        let pv = MaskVec(v)
        let from = space.pixel(fromView: v)
        func near(_ q: CGPoint) -> Bool { MaskVec(q).distance(to: pv) <= hitRadius }
        if let l = shape.linear {
            let h = LinearHandles(l, space: space)
            if near(h.rotateHandle) { return .linearRotate(ref) }
            if near(space.view(h.mid)) { return .move(ref, original: shape, from: from) }
            let ds = h.viewDistance(v, toLineThrough: h.start), de = h.viewDistance(v, toLineThrough: h.end)
            if min(ds, de) <= hitRadius { return ds <= de ? .linearStart(ref) : .linearEnd(ref) }
            if h.viewDistance(v, toLineThrough: h.mid) <= hitRadius { return .move(ref, original: shape, from: from) }
        } else if let r = shape.radial {
            let h = RadialHandles(r, space: space)
            if near(h.rotateHandle) { return .radialRotate(ref) }
            if near(space.view(h.xPlus)) || near(space.view(h.xMinus)) { return .radialX(ref) }
            if near(space.view(h.yPlus)) || near(space.view(h.yMinus)) { return .radialY(ref) }
            if h.contains(from) { return .move(ref, original: shape, from: from) }
        }
        return nil
    }

    // MARK: Edits (source pixels)

    /// A new mask, or a part of `MaskToolState.addingTo` (Add / Subtract). Returns where it went.
    @discardableResult
    private func createShape(_ kind: MaskKind, from a: CGPoint, to b: CGPoint, space: MaskSpace, session: DevelopSession) -> MaskRef? {
        let shape: MaskShape
        switch kind {
        case .linear:
            shape = .linear(LinearGradientMask(start: space.norm(a), end: space.norm(b)))
        case .radial:
            var r = RadialGradientMask()
            r.center = space.norm(a)
            (r.radiusX, r.radiusY) = Self.radii(from: a, to: b, space: space)
            shape = .radial(r)
        case .brush:
            shape = .brush(BrushMask())
        case .subject, .background, .people, .sky, .object:
            let target = kind.aiTarget ?? .subject
            shape = .ai(AIMask(target: target, points: target == .object ? [space.norm(a)] : []))
        }
        let tool = MaskToolState.shared
        if let id = tool.addingTo, session.mask(id: id) != nil {
            return session.addPart(shape, mode: tool.addMode, to: id)
        }
        if let ai = shape.ai { return MaskRef(mask: session.addAIMask(ai)) }
        return MaskRef(mask: session.addMask(shape))
    }

    /// Pick Object click: a new object mask (later clicks add to it), or one more object for / against the mask
    /// being added to. `flip` (⌥) swaps add and subtract. Picking goes on until Esc.
    private func pickObject(at point: NormPoint, flip: Bool, session: DevelopSession) {
        let tool = MaskToolState.shared
        guard (0...1).contains(point.x), (0...1).contains(point.y) else { return }
        var picked: AIMask?
        if let id = tool.addingTo, let mask = session.mask(id: id) {
            let mode: MaskPart.Mode = (tool.addMode == .subtract) != flip ? .subtract : .add
            let addMode = tool.addMode
            if mode == .add, var ai = mask.ai, ai.target == .object, mask.parts.isEmpty {
                ai.points.append(point)   // one more object of the mask itself
                session.updateMask(id) { $0.ai = ai }
                session.selectMask(id)
                picked = ai
            } else if let last = mask.parts.last, last.mode == mode, var ai = last.shape.ai, ai.target == .object {
                ai.points.append(point)
                session.updateShape(MaskRef(mask: id, part: last.id)) { $0 = .ai(ai) }
                session.selectPart(MaskRef(mask: id, part: last.id))
                picked = ai
            } else {
                session.addPart(.ai(AIMask(target: .object, points: [point])), mode: mode, to: id)
            }
            tool.addMode = addMode
            tool.addingTo = id
        } else {
            tool.addingTo = session.addAIMask(AIMask(target: .object, points: [point]))
            tool.addMode = .add
        }
        tool.pendingKind = .object   // selecting ended it; keep picking
        if let picked, let source = session.source { AIMaskStatus.shared.prepare(picked, source: source) }
    }

    private func updateCreated(_ kind: MaskKind, _ ref: MaskRef, from a: CGPoint, to b: CGPoint, space: MaskSpace, session: DevelopSession) {
        session.updateShape(ref) { shape in
            if var l = shape.linear, kind == .linear {
                l.end = space.norm(b)
                shape = .linear(l)
            } else if var r = shape.radial, kind == .radial {
                (r.radiusX, r.radiusY) = Self.radii(from: a, to: b, space: space)
                shape = .radial(r)
            }
        }
    }

    private static func radii(from a: CGPoint, to b: CGPoint, space: MaskSpace) -> (Double, Double) {
        let minPx = 0.01 * space.w
        return (Double(max(abs(b.x - a.x), minPx) / space.w), Double(max(abs(b.y - a.y), minPx) / space.h))
    }

    static func editLinear(_ l: LinearGradientMask, op: DragOp, to p: CGPoint, space: MaskSpace) -> LinearGradientMask {
        let h = LinearHandles(l, space: space)
        let s = MaskVec(h.start), e = MaskVec(h.end), pv = MaskVec(p)
        let minLength = 0.002 * Double(space.w)
        var out = l
        switch op {
        case .linearStart:
            out.start = space.norm((e - h.dir * max((e - pv).dot(h.dir), minLength)).cg)
        case .linearEnd:
            out.end = space.norm((s + h.dir * max((pv - s).dot(h.dir), minLength)).cg)
        case .linearRotate:
            let m = MaskVec(h.mid)
            guard let perp = (pv - m).normalized else { return l }
            let dir = MaskVec(x: perp.y, y: -perp.x) // inverse of perp = (-dir.y, dir.x)
            let half = (e - s).length / 2
            out.start = space.norm((m - dir * half).cg)
            out.end = space.norm((m + dir * half).cg)
        default: break
        }
        return out
    }

    static func editRadial(_ r: RadialGradientMask, op: DragOp, to p: CGPoint, space: MaskSpace) -> RadialGradientMask {
        let h = RadialHandles(r, space: space)
        let d = MaskVec(p) - MaskVec(h.center)
        let minPx = 0.005 * Double(space.w)
        var out = r
        switch op {
        case .radialX: out.radiusX = max(abs(d.dot(h.ux)), minPx) / Double(space.w)
        case .radialY: out.radiusY = max(abs(d.dot(h.uy)), minPx) / Double(space.h)
        case .radialRotate:
            // The handle sits on -uy (angle θ - 90°).
            var deg = atan2(d.y, d.x) * 180 / .pi + 90
            if deg > 180 { deg -= 360 }
            out.rotation = deg
        default: break
        }
        return out
    }

    /// Stores the in-progress stroke (creating the brush mask / part on first use). Returns where it went.
    @discardableResult
    private func store(_ stroke: BrushStroke, in target: PaintTarget, appended: Bool, session: DevelopSession) -> PaintTarget {
        var brush = BrushMask()
        brush.strokes = [stroke]
        switch target {
        case .newMask:
            return .brush(MaskRef(mask: session.addMask(.brush(brush))))
        case .newPart(let id):
            guard let ref = session.addPart(.brush(brush), mode: .add, to: id, select: false) else { return target }
            return .brush(ref)
        case .brush(let ref):
            session.updateShape(ref) { shape in
                guard var b = shape.brush else { return }
                if appended, !b.strokes.isEmpty { b.strokes[b.strokes.count - 1] = stroke } else { b.strokes.append(stroke) }
                shape = .brush(b)
            }
            return target
        }
    }
}

// MARK: - Geometry helpers

/// Mask space <-> source pixels <-> view.
struct MaskSpace {
    let geometry: CanvasGeometry
    var w: CGFloat { geometry.math.sourceSize.width }
    var h: CGFloat { geometry.math.sourceSize.height }
    var isValid: Bool { w > 0 && h > 0 && geometry.imageRect.width > 0 }
    /// height / width (converts normalized y distances to width units).
    var aspect: Double { Double(h / w) }

    func px(_ p: NormPoint) -> CGPoint { CGPoint(x: p.x * w, y: p.y * h) }
    func norm(_ q: CGPoint) -> NormPoint { NormPoint(x: Double(q.x / w), y: Double(q.y / h)) }
    func view(_ q: CGPoint) -> CGPoint { geometry.viewPoint(fromMask: norm(q)) }
    func pixel(fromView v: CGPoint) -> CGPoint { px(geometry.maskPoint(fromView: v)) }
}

/// Linear gradient lines and handles (source pixels unless noted).
struct LinearHandles {
    let space: MaskSpace
    let start: CGPoint, end: CGPoint, mid: CGPoint
    /// Unit direction start -> end and its perpendicular.
    let dir: MaskVec, perp: MaskVec

    init(_ m: LinearGradientMask, space: MaskSpace) {
        self.space = space
        start = space.px(m.start)
        end = space.px(m.end)
        mid = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
        dir = (MaskVec(end) - MaskVec(start)).normalized ?? MaskVec(x: 0, y: 1)
        perp = MaskVec(x: -dir.y, y: dir.x)
    }

    /// View endpoints of a long line through `p` perpendicular to the gradient (clip it to the image).
    func viewLine(through p: CGPoint) -> (CGPoint, CGPoint) {
        let l = Double(space.w + space.h) * 2
        return (space.view((MaskVec(p) - perp * l).cg), space.view((MaskVec(p) + perp * l).cg))
    }

    func viewDistance(_ v: CGPoint, toLineThrough p: CGPoint) -> CGFloat {
        let a = MaskVec(space.view(p))
        guard let u = (MaskVec(space.view((MaskVec(p) + perp * Double(space.w)).cg)) - a).normalized else { return .infinity }
        let d = MaskVec(v) - a
        return CGFloat(abs(d.x * u.y - d.y * u.x))
    }

    /// Rotation handle (view): on the center line, 44 pt from the center pin.
    var rotateHandle: CGPoint {
        let m = MaskVec(space.view(mid))
        let u = (MaskVec(space.view((MaskVec(mid) + perp * Double(space.w)).cg)) - m).normalized ?? MaskVec(x: 1, y: 0)
        return (m + u * 44).cg
    }
}

/// Radial gradient ellipse and handles (source pixels unless noted).
struct RadialHandles {
    let space: MaskSpace
    let center: CGPoint
    let rx: Double, ry: Double
    /// Ellipse axes (y down, rotated clockwise).
    let ux: MaskVec, uy: MaskVec

    init(_ m: RadialGradientMask, space: MaskSpace) {
        self.space = space
        center = space.px(m.center)
        rx = m.radiusX * Double(space.w)
        ry = m.radiusY * Double(space.h)
        let t = m.rotation * .pi / 180
        ux = MaskVec(x: cos(t), y: sin(t))
        uy = MaskVec(x: -sin(t), y: cos(t))
    }

    var xPlus: CGPoint { (MaskVec(center) + ux * rx).cg }
    var xMinus: CGPoint { (MaskVec(center) - ux * rx).cg }
    var yPlus: CGPoint { (MaskVec(center) + uy * ry).cg }
    var yMinus: CGPoint { (MaskVec(center) - uy * ry).cg }

    /// View polygon of the ellipse scaled by `s` (1 = outer edge).
    func viewEllipse(scale s: Double, segments: Int = 72) -> [CGPoint] {
        (0..<segments).map { k in
            let a = Double(k) / Double(segments) * 2 * .pi
            return space.view((MaskVec(center) + ux * (rx * s * cos(a)) + uy * (ry * s * sin(a))).cg)
        }
    }

    func contains(_ p: CGPoint) -> Bool {
        let d = MaskVec(p) - MaskVec(center)
        let a = d.dot(ux) / max(rx, 1e-9), b = d.dot(uy) / max(ry, 1e-9)
        return a * a + b * b <= 1
    }

    /// Rotation handle (view): 24 pt beyond the top (-y axis) handle.
    var rotateHandle: CGPoint {
        let c = MaskVec(space.view(center)), top = MaskVec(space.view(yMinus))
        let u = (top - c).normalized ?? MaskVec(x: 0, y: -1)
        return (top + u * 24).cg
    }
}

/// Tiny 2D vector (own type, so its operators never clash with other files).
struct MaskVec {
    var x: Double, y: Double
    init(x: Double, y: Double) { self.x = x; self.y = y }
    init(_ p: CGPoint) { x = Double(p.x); y = Double(p.y) }
    var cg: CGPoint { CGPoint(x: x, y: y) }
    var length: Double { hypot(x, y) }
    var normalized: MaskVec? { length > 1e-12 ? MaskVec(x: x / length, y: y / length) : nil }
    func dot(_ o: MaskVec) -> Double { x * o.x + y * o.y }
    func distance(to o: MaskVec) -> CGFloat { CGFloat((self - o).length) }
    static func + (a: MaskVec, b: MaskVec) -> MaskVec { MaskVec(x: a.x + b.x, y: a.y + b.y) }
    static func - (a: MaskVec, b: MaskVec) -> MaskVec { MaskVec(x: a.x - b.x, y: a.y - b.y) }
    static func * (a: MaskVec, k: Double) -> MaskVec { MaskVec(x: a.x * k, y: a.y * k) }
}
