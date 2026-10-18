//
//  InstaModels.swift
//  Kika
//
//  Instagram plans (UI-free; compiled by Tools/insta_check.swift). A folder can have one plan; a plan holds
//  posts (carousels) and story sets, in order. Each holds slides; a slide is one frame with a layout of
//  cells, and each cell shows one photo. A post slide can span several carousel slides (a split: one
//  photo cut into strips on export). Catalog API: Catalog+Insta.swift.
//

import Foundation
import CoreGraphics

nonisolated struct InstaPlan: Identifiable, Hashable, Sendable {
    var id: Int64
    var folderID: Int64
    var createdAt: Date
}

nonisolated enum InstaKind: String, Hashable, Sendable, CaseIterable {
    case post, story

    var title: String { self == .post ? "Post" : "Stories" }
    /// Prefix of the short label on grid badges ("P2", "S1").
    var letter: String { self == .post ? "P" : "S" }
    var systemImage: String { self == .post ? "square.on.square" : "rectangle.portrait.on.rectangle.portrait" }
}

nonisolated enum InstaStatus: String, Hashable, Sendable, CaseIterable {
    case draft, ready, posted

    var title: String {
        switch self {
        case .draft: "Draft"
        case .ready: "Ready"
        case .posted: "Posted"
        }
    }
}

/// Frame shape. A carousel uses one shape for every slide (Instagram crops the rest to the first).
nonisolated enum InstaAspect: String, Hashable, Sendable, CaseIterable {
    case square = "1:1"
    case portrait = "4:5"
    case tall = "3:4"
    case story = "9:16"

    static let postAspects: [InstaAspect] = [.portrait, .tall, .square]

    /// Width / height.
    var ratio: CGFloat {
        switch self {
        case .square: 1
        case .portrait: 4.0 / 5.0
        case .tall: 3.0 / 4.0
        case .story: 9.0 / 16.0
        }
    }

    /// Export size of one slide, pixels (1080 wide).
    var pixelSize: CGSize { CGSize(width: 1080, height: (1080 / ratio).rounded()) }
}

/// How a slide's frame is divided into cells. Rects are computed in `cellRects(in:gap:)`.
nonisolated enum InstaLayout: String, Hashable, Sendable, CaseIterable {
    case single
    case stack2
    case side2
    case stack3
    case grid4
    case feature3

    var title: String {
        switch self {
        case .single: "Single Photo"
        case .stack2: "2 Stacked"
        case .side2: "2 Side by Side"
        case .stack3: "3 Stacked"
        case .grid4: "2 × 2 Grid"
        case .feature3: "1 Large + 2 Small"
        }
    }

    var systemImage: String {
        switch self {
        case .single: "rectangle.portrait"
        case .stack2: "rectangle.split.1x2"
        case .side2: "rectangle.split.2x1"
        case .stack3: "rectangle.split.3x1"
        case .grid4: "rectangle.split.2x2"
        case .feature3: "rectangle.3.group"
        }
    }

    var cellCount: Int { Self.units[self]!.count }

    /// Cells in unit space (0…1 both ways, y down), before gaps.
    private static let units: [InstaLayout: [CGRect]] = [
        .single: [CGRect(x: 0, y: 0, width: 1, height: 1)],
        .stack2: [CGRect(x: 0, y: 0, width: 1, height: 0.5), CGRect(x: 0, y: 0.5, width: 1, height: 0.5)],
        .side2: [CGRect(x: 0, y: 0, width: 0.5, height: 1), CGRect(x: 0.5, y: 0, width: 0.5, height: 1)],
        .stack3: (0..<3).map { CGRect(x: 0, y: CGFloat($0) / 3, width: 1, height: 1.0 / 3) },
        .grid4: (0..<4).map { CGRect(x: CGFloat($0 % 2) / 2, y: CGFloat($0 / 2) / 2, width: 0.5, height: 0.5) },
        .feature3: [CGRect(x: 0, y: 0, width: 1, height: 2.0 / 3),
                    CGRect(x: 0, y: 2.0 / 3, width: 0.5, height: 1.0 / 3),
                    CGRect(x: 0.5, y: 2.0 / 3, width: 0.5, height: 1.0 / 3)],
    ]

    /// Cell rects in a frame of `size` (y down), separated and inset by `gap` (a fraction of the frame width).
    /// The outer margin equals the gap, so cells are evenly spaced; `gap` 0 = edge to edge.
    func cellRects(in size: CGSize, gap: CGFloat) -> [CGRect] {
        let g = max(0, gap) * size.width
        return Self.units[self]!.map { u in
            let x0 = u.minX * size.width, x1 = u.maxX * size.width
            let y0 = u.minY * size.height, y1 = u.maxY * size.height
            // Full gap at the frame edges, half a gap on each side of an inner edge.
            let left = u.minX == 0 ? g : g / 2, right = u.maxX == 1 ? g : g / 2
            let top = u.minY == 0 ? g : g / 2, bottom = u.maxY == 1 ? g : g / 2
            return CGRect(x: x0 + left, y: y0 + top, width: max(0, x1 - x0 - left - right), height: max(0, y1 - y0 - top - bottom))
        }
    }
}

/// One photo in a cell, placed by `transform` (InstaFraming).
nonisolated struct InstaCell: Hashable, Sendable {
    var index: Int
    var photoID: Int64
    var transform = InstaTransform()
}

/// How a photo sits in its cell. Relative units, so the board and a full-size export frame it the same.
nonisolated struct InstaTransform: Hashable, Sendable {
    /// 1 = just fills the cell (aspect-fill, unrotated); below 1 the background shows around it.
    var scale: Double = 1
    /// Centre displacement as a fraction of the cell's width / height (0 = centred; y down).
    var offsetX: Double = 0
    var offsetY: Double = 0
    /// Degrees, clockwise.
    var rotation: Double = 0

    static let scaleRange = 0.1...10.0

    /// Values the catalog stores: scale in range, offsets within ±3 cells, rotation in (−180, 180].
    var clamped: InstaTransform {
        var r = rotation.truncatingRemainder(dividingBy: 360)
        if r > 180 { r -= 360 } else if r <= -180 { r += 360 }
        return InstaTransform(scale: min(max(scale, Self.scaleRange.lowerBound), Self.scaleRange.upperBound),
                              offsetX: min(max(offsetX, -3), 3), offsetY: min(max(offsetY, -3), 3), rotation: r)
    }
    var isIdentity: Bool { self == InstaTransform() }
}

nonisolated struct InstaSlide: Identifiable, Hashable, Sendable {
    var id: Int64
    var postID: Int64
    var sortOrder: Int
    var layout: InstaLayout = .single
    /// Carousel slides this frame covers (a split). Always 1 for layouts other than `single` and for stories.
    var span: Int = 1
    /// Behind cells and gaps, "#RRGGBB".
    var background: String = "#FFFFFF"
    /// Fraction of the frame width (see `InstaLayout.cellRects`); used only by multi-cell layouts.
    var gap: Double = 0.015
    var cells: [InstaCell] = []

    func cell(_ index: Int) -> InstaCell? { cells.first { $0.index == index } }
    var photoIDs: [Int64] { cells.sorted { $0.index < $1.index }.map(\.photoID) }
    var isEmpty: Bool { cells.isEmpty }
}

nonisolated struct InstaPost: Identifiable, Hashable, Sendable {
    var id: Int64
    var planID: Int64
    var kind: InstaKind
    var title: String
    var caption: String = ""
    var aspect: InstaAspect
    var scheduledAt: Date?
    var status: InstaStatus = .draft
    var postedAt: Date?
    var sortOrder: Int
    var slides: [InstaSlide] = []

    /// Instagram's carousel limit.
    static let maxCarouselSlides = 20
    /// Instagram's caption limit, characters.
    static let maxCaptionLength = 2200

    /// Images this post exports to (splits count once per strip).
    var exportedSlideCount: Int { slides.reduce(0) { $0 + $1.span } }
    var photoIDs: [Int64] { slides.flatMap(\.photoIDs) }
    var isLocked: Bool { status == .posted }
}

/// Where a photo is used: one entry per post / story set it appears in.
nonisolated struct InstaUsage: Hashable, Sendable {
    var planID: Int64
    var postID: Int64
    var kind: InstaKind
    /// 1-based position among the plan's posts of the same kind ("P2" = second post).
    var number: Int
    var status: InstaStatus

    var label: String { kind.letter + String(number) }
}

/// Placing a photo in its cell (shared by the board, the Adjust Photos editor and export). The photo is sized to
/// aspect-fill the cell, times `scale`, centred plus the offsets, then rotated about its centre.
nonisolated enum InstaFraming {
    struct Placement: Equatable {
        /// Centre in cell coordinates (origin = the cell's top-left, y down).
        var center: CGPoint
        /// The photo's unrotated size.
        var size: CGSize
        /// Clockwise.
        var radians: CGFloat
    }

    private static func fill(_ image: CGSize, _ cell: CGSize) -> CGFloat {
        guard image.width > 0, image.height > 0 else { return 1 }
        return max(cell.width / image.width, cell.height / image.height)
    }

    static func placement(imageSize: CGSize, cellSize: CGSize, transform t: InstaTransform) -> Placement {
        let s = fill(imageSize, cellSize) * CGFloat(t.scale)
        return Placement(center: CGPoint(x: cellSize.width * (0.5 + CGFloat(t.offsetX)), y: cellSize.height * (0.5 + CGFloat(t.offsetY))),
                         size: CGSize(width: imageSize.width * s, height: imageSize.height * s),
                         radians: CGFloat(t.rotation) * .pi / 180)
    }

    /// The smallest scale at which the photo, centred at this rotation, covers the whole cell ("Fill").
    static func coverScale(imageSize: CGSize, cellSize: CGSize, rotation: Double) -> Double {
        guard imageSize.width > 0, imageSize.height > 0 else { return 1 }
        let a = CGFloat(rotation) * .pi / 180, c = abs(cos(a)), sn = abs(sin(a))
        let need = max((cellSize.width * c + cellSize.height * sn) / imageSize.width,
                       (cellSize.width * sn + cellSize.height * c) / imageSize.height)
        return Double(need / fill(imageSize, cellSize))
    }

    /// The largest scale at which the whole photo, at this rotation, stays inside the cell ("Fit").
    static func fitScale(imageSize: CGSize, cellSize: CGSize, rotation: Double) -> Double {
        guard imageSize.width > 0, imageSize.height > 0 else { return 1 }
        let a = CGFloat(rotation) * .pi / 180, c = abs(cos(a)), sn = abs(sin(a))
        let s = min(cellSize.width / (imageSize.width * c + imageSize.height * sn),
                    cellSize.height / (imageSize.width * sn + imageSize.height * c))
        return Double(s / fill(imageSize, cellSize))
    }

    /// Whether the photo covers the whole cell (no background showing), with half a point of slack.
    static func covers(imageSize: CGSize, cellSize: CGSize, transform t: InstaTransform) -> Bool {
        let p = placement(imageSize: imageSize, cellSize: cellSize, transform: t)
        let c = cos(-p.radians), sn = sin(-p.radians)
        let corners = [CGPoint.zero, CGPoint(x: cellSize.width, y: 0), CGPoint(x: 0, y: cellSize.height),
                       CGPoint(x: cellSize.width, y: cellSize.height)]
        return corners.allSatisfy { q in
            let dx = q.x - p.center.x, dy = q.y - p.center.y
            let x = dx * c - dy * sn, y = dx * sn + dy * c
            return abs(x) <= p.size.width / 2 + 0.5 && abs(y) <= p.size.height / 2 + 0.5
        }
    }
}
