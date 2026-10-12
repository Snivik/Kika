//
//  CanvasPointer.swift
//  sloproom
//
//  Pointer (cursor) rules for the Develop canvas and full-screen preview layers.
//
//  SwiftUI applies a hovered view's `pointerStyle` but doesn't put the arrow back when that view
//  goes away under a pointer that doesn't move: leaving Develop while zoomed left the zoom / hand
//  cursor over the whole Library, and a tool change could leave the crop cursor over the image.
//  Every canvas layer with a pointer style therefore uses `resetsPointerWhenRemoved()`.
//  The same applies to all transient hover UI: never rely on SwiftUI's "exit" callbacks alone.
//  `PhotoDropFeedback` (the folder Add / Move / Copy badge) also clears when the mouse button is up.
//

import AppKit
import SwiftUI

extension View {
    /// Puts the arrow back when this view disappears (mode, tool or photo switch under a still pointer).
    func resetsPointerWhenRemoved() -> some View {
        onDisappear { NSCursor.arrow.set() }
    }
}

extension PointerStyle {
    /// Crop tool, outside the crop rectangle: drag rotates (straightens). A white curved double arrow with a dark
    /// outline, readable on both dark and light photos.
    static let rotate: PointerStyle = .image(Image(nsImage: CanvasPointer.rotateImage), hotSpot: .center)
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
