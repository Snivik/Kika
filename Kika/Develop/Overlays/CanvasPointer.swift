//
//  CanvasPointer.swift
//  Kika
//
//  Pointer (cursor) ownership. ONE place declares a SwiftUI `pointerStyle`: each window root
//  (`.canvasPointerRoot()` on MainWindowView and FullScreenPreviewView), from `CanvasPointerState`. Canvas
//  layers (hand tool, crop, mask, white-balance picker) only REPORT the cursor they want while hovered
//  (`.canvasPointer(_:rank:)`) and withdraw on hover end or removal.
//
//  Why: SwiftUI's pointer bridge resolves a cursor from the hovered region and caches it. When a view with
//  its own `pointerStyle` is removed under a still pointer (leaving Develop, switching tools), the next
//  cursor update re-applies the removed view's cursor, and within a single region moving the pointer
//  never asks again: the zoom / hand cursor stayed over the whole Library (`-debug.cursorTrace YES`,
//  CanvasPointerDevScript.swift). A root that is never removed and whose VALUE changes takes the bridge's
//  invalidation path, which updates the cursor at once. Setting NSCursor or adding AppKit cursor rects
//  beside SwiftUI flickers (the hosting view's cursor updates win), so don't.
//
//  The same principle holds for all transient hover UI: tie it to state with an owner that outlives the
//  views, not to SwiftUI's exit callbacks (`PhotoDropFeedback` also clears on mouse-up).
//

import AppKit
import SwiftUI

/// The cursors canvas layers ask for.
enum CanvasCursor: Hashable {
    case zoomIn, grabIdle, grabActive, crosshair
    /// Crop tool, outside the crop rectangle: drag rotates (straightens).
    case rotate
    case resize(Edge)

    enum Edge: Hashable { case top, bottom, leading, trailing, topLeading, topTrailing, bottomLeading, bottomTrailing }

    var pointerStyle: PointerStyle {
        switch self {
        case .zoomIn: .zoomIn
        case .grabIdle: .grabIdle
        case .grabActive: .grabActive
        case .crosshair: .rectSelection
        // A white curved double arrow with a dark outline, readable on both dark and light photos.
        case .rotate: .image(Image(nsImage: CanvasPointer.rotateImage), hotSpot: .center)
        case .resize(let e):
            switch e {
            case .top: .frameResize(position: .top)
            case .bottom: .frameResize(position: .bottom)
            case .leading: .frameResize(position: .leading)
            case .trailing: .frameResize(position: .trailing)
            case .topLeading: .frameResize(position: .topLeading)
            case .topTrailing: .frameResize(position: .topTrailing)
            case .bottomLeading: .frameResize(position: .bottomLeading)
            case .bottomTrailing: .frameResize(position: .bottomTrailing)
            }
        }
    }
}

/// Which hovered canvas layers want which cursor; the highest rank wins (a layer drawn above another
/// ranks higher). A hovered layer that wants no cursor (nil) still wins: it shows the arrow.
@Observable
final class CanvasPointerState {
    static let shared = CanvasPointerState()

    private struct Claim: Equatable { var rank: Int; var cursor: CanvasCursor? }
    private var claims: [UUID: Claim] = [:]

    var current: CanvasCursor? { claims.values.max { $0.rank < $1.rank }?.cursor }

    func claim(_ id: UUID, _ cursor: CanvasCursor?, rank: Int) {
        let c = Claim(rank: rank, cursor: cursor)
        if claims[id] != c { claims[id] = c }
    }

    func withdraw(_ id: UUID) {
        if claims[id] != nil { claims[id] = nil }
    }
}

extension View {
    /// The window root's pointer: the winning canvas claim, else the arrow. The only `pointerStyle` in the app.
    func canvasPointerRoot() -> some View {
        modifier(CanvasPointerRoot())
    }

    /// While hovered, this layer wants `cursor` (nil = the arrow). `rank`: higher wins among stacked layers.
    func canvasPointer(_ cursor: CanvasCursor?, rank: Int) -> some View {
        modifier(CanvasPointerClaim(cursor: cursor, rank: rank))
    }
}

private struct CanvasPointerRoot: ViewModifier {
    private var state: CanvasPointerState { .shared }

    func body(content: Content) -> some View {
        content.pointerStyle(state.current?.pointerStyle ?? .default)
    }
}

private struct CanvasPointerClaim: ViewModifier {
    let cursor: CanvasCursor?
    let rank: Int
    @State private var id = UUID()
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .onContinuousHover { phase in
                if case .active = phase {
                    isHovered = true
                    CanvasPointerState.shared.claim(id, cursor, rank: rank)
                } else {
                    isHovered = false
                    CanvasPointerState.shared.withdraw(id)
                }
            }
            .onChange(of: cursor) { _, c in
                if isHovered { CanvasPointerState.shared.claim(id, c, rank: rank) }
            }
            .onDisappear { CanvasPointerState.shared.withdraw(id) }
    }
}

enum CanvasPointer {
    static let rotateImage: NSImage = outlined(symbol: ["arrow.trianglehead.2.clockwise.rotate.90", "arrow.clockwise"], size: 18)

    /// The first available SF Symbol, white on a 1.5 pt dark outline, in an image with room for the outline.
    private static func outlined(symbol names: [String], size: CGFloat) -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: size, weight: .semibold)
        guard let symbol = names.lazy.compactMap({ NSImage(systemSymbolName: $0, accessibilityDescription: nil) }).first?
            .withSymbolConfiguration(config) else { return NSImage() }
        func tinted(_ color: NSColor) -> NSImage {
            NSImage(size: symbol.size, flipped: false) { rect in
                symbol.draw(in: rect)
                color.set()
                rect.fill(using: .sourceAtop)
                return true
            }
        }
        let white = tinted(.white), dark = tinted(NSColor(white: 0, alpha: 0.85))
        let pad: CGFloat = 2
        let canvas = NSSize(width: symbol.size.width + pad * 2, height: symbol.size.height + pad * 2)
        return NSImage(size: canvas, flipped: false) { _ in
            let base = NSRect(origin: NSPoint(x: pad, y: pad), size: symbol.size)
            for dx in stride(from: -1.5, through: 1.5, by: 0.75) {
                for dy in stride(from: -1.5, through: 1.5, by: 0.75) where dx != 0 || dy != 0 {
                    dark.draw(in: base.offsetBy(dx: dx, dy: dy))
                }
            }
            white.draw(in: base)
            return true
        }
    }
}
