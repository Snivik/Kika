//
//  MaskEditing.swift
//  Kika
//
//  UI-free helpers for editing masks: brush point decimation / simplification (strokes must
//  stay small in JSON), naming, pin positions. Distances are measured in "width units"
//  (fractions of the oriented image width; y is scaled by the aspect H/W), like brush radii.
//

import Foundation
import CoreGraphics

nonisolated enum MaskKind: String, CaseIterable, Sendable {
    case linear, radial, brush
    // Found by Vision (AIMask)
    case subject, background, people, sky, object

    /// Drawn on the photo.
    static let shapes: [MaskKind] = [.linear, .radial, .brush]
    /// Found on the photo (Select row of the panel).
    static let found: [MaskKind] = [.subject, .background, .people, .sky, .object]

    var aiTarget: AIMask.Target? {
        switch self {
        case .subject: .subject
        case .background: .background
        case .people: .people
        case .sky: .sky
        case .object: .object
        case .linear, .radial, .brush: nil
        }
    }

    var title: String {
        switch self {
        case .linear: "Linear Gradient"
        case .radial: "Radial Gradient"
        case .brush: "Brush"
        case .subject: "Subject"
        case .background: "Background"
        case .people: "People"
        case .sky: "Sky"
        case .object: "Object"
        }
    }

    var systemImage: String {
        switch self {
        case .linear: "rectangle.tophalf.filled"
        case .radial: "circle.dashed"
        case .brush: "paintbrush.pointed"
        case .subject: "person.and.background.dotted"
        case .background: "photo"
        case .people: "person.2"
        case .sky: "cloud.sun"
        case .object: "hand.point.up.left"
        }
    }
}

nonisolated extension MaskShape {
    var kind: MaskKind {
        switch self {
        case .linear: .linear
        case .radial: .radial
        case .brush: .brush
        case .ai(let m):
            switch m.target {
            case .subject: .subject
            case .background: .background
            case .people: .people
            case .sky: .sky
            case .object: .object
            }
        }
    }
}

nonisolated extension MaskShape {
    /// Shape accessors: nil if the shape is another kind; setting replaces the shape.
    var linear: LinearGradientMask? {
        get { if case .linear(let m) = self { m } else { nil } }
        set { if let newValue { self = .linear(newValue) } }
    }
    var radial: RadialGradientMask? {
        get { if case .radial(let m) = self { m } else { nil } }
        set { if let newValue { self = .radial(newValue) } }
    }
    var brush: BrushMask? {
        get { if case .brush(let m) = self { m } else { nil } }
        set { if let newValue { self = .brush(newValue) } }
    }
    var ai: AIMask? {
        get { if case .ai(let m) = self { m } else { nil } }
        set { if let newValue { self = .ai(newValue) } }
    }

    /// Where the shape's pin is drawn (mask space).
    var pinPoint: NormPoint? {
        switch self {
        case .linear(let m): return NormPoint(x: (m.start.x + m.end.x) / 2, y: (m.start.y + m.end.y) / 2)
        case .radial(let m): return m.center
        case .brush(let m): return m.strokes.first(where: { !$0.isEraser && !$0.points.isEmpty })?.points.first
        case .ai(let m): return m.points.first   // picked objects; whole-photo selections have no pin
        }
    }
}

/// A mask's main shape (`part` nil) or one of its parts.
nonisolated struct MaskRef: Equatable, Hashable, Sendable {
    var mask: UUID
    var part: UUID? = nil
}

nonisolated extension Mask {
    /// Main shape accessors: nil if the mask is another kind; setting replaces the shape.
    var linear: LinearGradientMask? { get { shape.linear } set { shape.linear = newValue } }
    var radial: RadialGradientMask? { get { shape.radial } set { shape.radial = newValue } }
    var brush: BrushMask? { get { shape.brush } set { shape.brush = newValue } }
    var ai: AIMask? { get { shape.ai } set { shape.ai = newValue } }

    /// Where the mask's pin is drawn (mask space).
    var pinPoint: NormPoint? { shape.pinPoint }

    /// The main shape (nil) or a part's shape.
    func shape(part: UUID?) -> MaskShape? {
        guard let part else { return shape }
        return parts.first { $0.id == part }?.shape
    }

    /// Changes the main shape (nil) or a part's shape.
    mutating func updateShape(part: UUID?, _ change: (inout MaskShape) -> Void) {
        guard let part else { change(&shape); return }
        guard let i = parts.firstIndex(where: { $0.id == part }) else { return }
        change(&parts[i].shape)
    }

    /// Where paint / erase strokes go: the main shape of a brush mask without parts, else the last part when
    /// it is a brush; nil = append a new brush part (so strokes always apply after every part before them).
    var brushTarget: MaskRef? {
        if parts.isEmpty, shape.brush != nil { return MaskRef(mask: id) }
        if let last = parts.last, last.shape.brush != nil { return MaskRef(mask: id, part: last.id) }
        return nil
    }
}

nonisolated enum MaskEditing {
    /// Point spacing while painting, as a fraction of the brush radius.
    static let brushSpacing = 0.25
    /// Simplification tolerance, as a fraction of the brush radius.
    static let brushTolerance = 0.04

    /// Rounds to 1e-5 (0.1 px on a 10 000 px image) so JSON stays short.
    static func rounded(_ p: NormPoint) -> NormPoint {
        NormPoint(x: (p.x * 1e5).rounded() / 1e5, y: (p.y * 1e5).rounded() / 1e5)
    }

    /// Distance in width units between two mask points. `aspect` = height / width.
    static func distance(_ a: NormPoint, _ b: NormPoint, aspect: Double) -> Double {
        hypot(a.x - b.x, (a.y - b.y) * aspect)
    }

    /// Appends `p` to the stroke if it is at least `brushSpacing × radius` from the last point.
    /// Returns true if the point was added.
    @discardableResult
    static func append(_ p: NormPoint, to stroke: inout BrushStroke, aspect: Double, force: Bool = false) -> Bool {
        let p = rounded(p)
        if let last = stroke.points.last {
            let d = distance(last, p, aspect: aspect)
            guard d > 1e-6, force || d >= max(stroke.radius * brushSpacing, 1e-4) else { return false }
        }
        stroke.points.append(p)
        return true
    }

    /// Ramer–Douglas–Peucker simplification (keeps the stroke within `tolerance` width units).
    static func simplify(_ points: [NormPoint], tolerance: Double, aspect: Double) -> [NormPoint] {
        guard points.count > 2, tolerance > 0 else { return points }
        var keep = [Bool](repeating: false, count: points.count)
        keep[0] = true; keep[points.count - 1] = true
        var stack = [(0, points.count - 1)]
        while let (a, b) = stack.popLast() {
            guard b > a + 1 else { continue }
            let ax = points[a].x, ay = points[a].y * aspect
            let dx = points[b].x - ax, dy = points[b].y * aspect - ay
            let len = hypot(dx, dy)
            var best = -1.0, index = a
            for i in (a + 1)..<b {
                let px = points[i].x - ax, py = points[i].y * aspect - ay
                let d = len > 1e-12 ? abs(px * dy - py * dx) / len : hypot(px, py)
                if d > best { best = d; index = i }
            }
            if best > tolerance {
                keep[index] = true
                stack.append((a, index)); stack.append((index, b))
            }
        }
        return points.indices.filter { keep[$0] }.map { points[$0] }
    }

    /// Final clean-up at the end of a stroke.
    static func finish(_ stroke: inout BrushStroke, aspect: Double) {
        stroke.points = simplify(stroke.points, tolerance: stroke.radius * brushTolerance, aspect: aspect)
    }

    /// "Linear Gradient 2" — first unused number for the kind.
    static func nextName(for kind: MaskKind, existing: [Mask]) -> String {
        let names = Set(existing.map(\.name))
        var n = 1
        while names.contains("\(kind.title) \(n)") { n += 1 }
        return "\(kind.title) \(n)"
    }
}
