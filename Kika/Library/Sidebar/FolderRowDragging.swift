//
//  FolderRowDragging.swift
//  Kika
//
//  Dragging a folder row in the sidebar. The sidebar List (an outline view run by SwiftUI) never asks a row's
//  `itemProvider` for a drag: pressing a row and moving selects the rows under the pointer instead. So the drag
//  is started here, in AppKit:
//    - each folder row carries an invisible `FolderRowMarker` (its folder id; disabled while renaming);
//    - a plain left mouse-down on a marked row is held back from the list; moving 4 pt starts an
//      NSDraggingSession with the row's image and the folder payload (`KikaDrag`), so the rows' existing
//      drop delegates (FolderDropDelegates.swift) take it as before;
//    - letting go without moving replays the click to the list (as fresh events), which then selects the row
//      as usual. Double-clicks, modifier clicks, ⌃-click and clicks on controls (disclosure
//      triangle, the rename field) go straight to the list.
//

import AppKit
import SwiftUI

/// Marks a folder row's view so the drag monitor can tell which folder is under the pointer.
struct FolderRowMarker: NSViewRepresentable {
    let folderID: Int64
    let isEnabled: Bool

    func makeNSView(context: Context) -> MarkerView {
        let view = MarkerView()
        view.folderID = folderID
        view.isEnabled = isEnabled
        return view
    }

    func updateNSView(_ view: MarkerView, context: Context) {
        view.folderID = folderID
        view.isEnabled = isEnabled
    }

    final class MarkerView: NSView {
        var folderID: Int64 = 0
        var isEnabled = true
        override func hitTest(_ point: NSPoint) -> NSView? { nil }   // never takes clicks
    }
}

enum FolderRowDragging {
    private static var monitor: Any?
    /// A mouse-down held back from the list until it turns into a drag or a click.
    private static var pending: (event: NSEvent, folderID: Int64, row: NSView)?
    /// Events being replayed to the list (pass through untouched).
    private static var replaying: Set<ObjectIdentifier> = []
    private static let source = DragSource()
    private static let threshold: CGFloat = 4

    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { event in
            nonisolated(unsafe) let event = event   // local monitors run on the main thread
            return MainActor.assumeIsolated { handle(event) } ? nil : event
        }
    }

    /// True = the event is consumed.
    private static func handle(_ event: NSEvent) -> Bool {
        if replaying.remove(ObjectIdentifier(event)) != nil { return false }
        switch event.type {
        case .leftMouseDown:
            pending = nil
            replaying.removeAll()   // a replayed mouse-up the list's own tracking took never comes back here
            guard let (folderID, row) = folderRow(at: event) else { return false }
            pending = (event, folderID, row)
            return true
        case .leftMouseDragged:
            guard let p = pending else { return false }
            let a = p.event.locationInWindow, b = event.locationInWindow
            guard hypot(b.x - a.x, b.y - a.y) >= threshold else { return true }
            pending = nil
            beginDrag(folderID: p.folderID, row: p.row, mouseDown: p.event)
            return true
        case .leftMouseUp:
            guard let p = pending else { return false }
            pending = nil
            // A click: hand it to the list as a fresh mouse-down + mouse-up (it ignores the held-back originals).
            let replay = [NSEvent.EventType.leftMouseDown, .leftMouseUp].compactMap { type in
                NSEvent.mouseEvent(with: type, location: p.event.locationInWindow, modifierFlags: p.event.modifierFlags,
                                   timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: p.event.windowNumber, context: nil,
                                   eventNumber: p.event.eventNumber, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)
            }
            replay.forEach { replaying.insert(ObjectIdentifier($0)) }
            replay.reversed().forEach { NSApp.postEvent($0, atStart: true) }   // ahead of a double-click's second click
            return true
        default:
            return false
        }
    }

    /// The folder row under a plain single left click in the main window's sidebar, or nil.
    private static func folderRow(at event: NSEvent) -> (Int64, NSView)? {
        guard event.clickCount == 1,
              event.modifierFlags.intersection([.command, .shift, .option, .control]).isEmpty,
              let window = event.window, window === ShortcutDispatcher.shared.mainWindow,
              let hit = window.contentView?.hitTest(event.locationInWindow) else { return nil }
        var row: NSView?
        var view: NSView? = hit
        while let v = view {
            if v is NSControl || v is NSText { return nil }   // disclosure triangle, rename field
            if v is NSTableRowView { row = v; break }
            if v is NSTableView { return nil }
            view = v.superview
        }
        guard let row, let marker = marker(in: row), marker.isEnabled else { return nil }
        return (marker.folderID, row)
    }

    private static func marker(in view: NSView) -> FolderRowMarker.MarkerView? {
        if let m = view as? FolderRowMarker.MarkerView { return m }
        for sub in view.subviews { if let m = marker(in: sub) { return m } }
        return nil
    }

    private static func beginDrag(folderID: Int64, row: NSView, mouseDown: NSEvent) {
        let payload = KikaDragPayload.folder(folderID)
        KikaDrag.current = payload
        let item = NSPasteboardItem()
        item.setString(payload.string, forType: .string)
        let dragging = NSDraggingItem(pasteboardWriter: item)
        dragging.setDraggingFrame(row.bounds, contents: snapshot(row))
        row.beginDraggingSession(with: [dragging], event: mouseDown, source: source)
    }

    /// The row as it looks now (the drag image).
    private static func snapshot(_ view: NSView) -> NSImage? {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        let image = NSImage(size: view.bounds.size)
        image.addRepresentation(rep)
        return image
    }

    private final class DragSource: NSObject, NSDraggingSource {
        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            context == .withinApplication ? [.move, .generic] : []
        }
    }
}
