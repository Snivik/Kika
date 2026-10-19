//
//  StuckDragGuard.swift
//  Kika
//
//  Safety net for a drag that never ended (GitHub #2): its drag-image window (window level
//  `kCGDraggingWindowLevel`, covering the screen) stays up and catches every left click until another
//  drag completes. No drag can be in progress when a mouse button goes down, so a drag-level window of
//  ours that is on screen at a left mouse-down is a leftover: it is logged and ordered out. The click
//  itself goes on unchanged (it lands on the hidden leftover, so it does nothing); the next click works.
//  Swallowing it instead left later clicks dead in tests.
//  Log: `log show --last 1d --predicate 'subsystem == "dev.snivik.kika" AND category == "drag"'`.
//  The drag that leaves the window behind is not known yet (Instagram board drags so far).
//
//  DEBUG: `stuckdrag make` puts up a fake leftover window, `stuckdrag click <x> <y>` posts a left click at
//  main-window points (through the event queue, so the guard sees it), `stuckdrag dump` lists drag-level windows.
//

import AppKit
import os

enum StuckDragGuard {
    private static var monitor: Any?
    private static let log = Logger(subsystem: "dev.snivik.kika", category: "drag")
    private static let dragLevel = Int(CGWindowLevelForKey(.draggingWindow))
    /// Leftovers removed since launch (diagnostics).
    private(set) static var recoveries = 0

    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            nonisolated(unsafe) let event = event   // local monitors run on the main thread
            MainActor.assumeIsolated { recover(before: event) }
            return event
        }
    }

    /// Removes leftover drag windows (logged).
    private static func recover(before event: NSEvent) {
        let leftovers = onScreenDragWindows()
        guard !leftovers.isEmpty else { return }
        let numbers = Set(leftovers.map(\.number))
        let windows = NSApp.windows.filter { numbers.contains($0.windowNumber) }
        for (number, bounds) in leftovers {
            let w = windows.first { $0.windowNumber == number }
            log.error("""
                Leftover drag window \(number) \(String(describing: bounds), privacy: .public) \
                class=\(w.map { String(describing: type(of: $0)) } ?? "not an NSWindow", privacy: .public) \
                ignoresMouse=\(w?.ignoresMouseEvents.description ?? "?", privacy: .public) \
                clickWindow=\(event.windowNumber) mode=\(ShortcutDispatcher.shared.model.map { "\($0.mode)" } ?? "?", privacy: .public)
                """)
        }
        windows.forEach { $0.orderOut(nil) }
        recoveries += windows.count
        // The window list lags behind orderOut: check again a moment later.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            let stillUp = onScreenDragWindows().count
            if stillUp > 0 { log.error("\(stillUp) leftover drag window(s) could not be removed") }
        }
    }

    /// On-screen windows of this process at the drag-image level (window number, global bounds).
    private static func onScreenDragWindows() -> [(number: Int, bounds: CGRect)] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        let pid = ProcessInfo.processInfo.processIdentifier
        return list.compactMap { info in
            guard info[kCGWindowOwnerPID as String] as? Int32 == pid, info[kCGWindowLayer as String] as? Int == dragLevel,
                  let number = info[kCGWindowNumber as String] as? Int else { return nil }
            let bounds = (info[kCGWindowBounds as String] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0) } ?? .zero
            return (number, bounds)
        }
    }

    #if DEBUG
    private static var fake: NSWindow?

    static func devCommand(_ arg: String) {
        let parts = arg.split(separator: " ")
        switch parts.first {
        case "make":
            guard let screen = NSScreen.main else { return }
            let w = NSWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            w.level = NSWindow.Level(rawValue: dragLevel)
            w.isOpaque = false
            w.backgroundColor = NSColor.black.withAlphaComponent(0.01)   // fully clear windows let clicks through
            w.isReleasedWhenClosed = false
            w.orderFrontRegardless()
            fake = w
            print("DevScript stuckdrag: made window \(w.windowNumber)")
        case "click":
            let v = parts.dropFirst().compactMap { Double($0) }
            guard v.count == 2, let main = ShortcutDispatcher.shared.mainWindow else { return }
            let screenPoint = CGPoint(x: main.frame.minX + v[0], y: main.frame.maxY - v[1])
            // While the fake leftover is up it covers the screen, so it gets the click (like the real one).
            let target = fake.flatMap { $0.isVisible ? $0 : nil } ?? main
            let number = target.windowNumber
            let location = target.convertPoint(fromScreen: screenPoint)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                if let e = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: number, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                    NSApp.postEvent(e, atStart: false)
                }
            }
            print("DevScript stuckdrag: click at window \(number)\(number == main.windowNumber ? " (main)" : "")")
        default:
            print("DevScript stuckdrag: dragWindows=\(onScreenDragWindows().map(\.number)) recoveries=\(recoveries)")
        }
    }
    #endif
}
