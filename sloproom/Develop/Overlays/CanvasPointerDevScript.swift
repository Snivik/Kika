//
//  CanvasPointerDevScript.swift
//  sloproom
//
//  Cursor debugging (DEBUG):
//    DevScript `pointer dump`   the app's current cursor and the winning canvas claim (CanvasPointer.swift)
//    launch arg `-debug.cursorTrace YES`   logs every cursor change with its call stack (CursorTrace below).
//  Synthetic mouse moves don't drive cursor updates, so cursor bugs need a real mouse plus the trace.
//

#if DEBUG
import AppKit

enum CanvasPointerDevScript {
    static func run(_ arg: String) async {
        switch arg {
        case "dump":
            print("DevScript pointer: current=\(name(NSCursor.current)) canvas claim=\(String(describing: CanvasPointerState.shared.current))")
        default:
            print("DevScript pointer: dump")
        }
    }

    static func name(_ c: NSCursor) -> String {
        var known: [(String, NSCursor)] = [("arrow", .arrow), ("openHand", .openHand), ("closedHand", .closedHand),
                                           ("crosshair", .crosshair), ("iBeam", .iBeam), ("pointingHand", .pointingHand)]
        if #available(macOS 15.0, *) { known += [("zoomIn", .zoomIn), ("zoomOut", .zoomOut)] }
        if let k = known.first(where: { $0.1 == c || $0.1.image === c.image }) { return k.0 }
        return "other(\(Int(c.image.size.width))x\(Int(c.image.size.height)) hot \(Int(c.hotSpot.x)),\(Int(c.hotSpot.y)))"
    }
}
#endif

#if DEBUG
/// Launch arg `-debug.cursorTrace YES`: logs every cursor change (NSCursor set / push / pop) with the call stack
/// to `<container tmp>/cursor-trace.log`, plus marks such as mode switches. For cursor bugs that need a real mouse.
enum CursorTrace {
    static let isOn = UserDefaults.standard.bool(forKey: "debug.cursorTrace")
    private static var handle: FileHandle?
    private static var last = ""

    private static var installed = false

    static func install() {
        guard isOn, !installed else { return }
        installed = true
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cursor-trace.log")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try? FileHandle(forWritingTo: url)
        swizzle(#selector(NSCursor.set), #selector(NSCursor.traced_set))
        swizzle(#selector(NSCursor.push), #selector(NSCursor.traced_push))
        swizzle(#selector(NSCursor.pop as (NSCursor) -> () -> Void), #selector(NSCursor.traced_pop))
        write("trace on → \(url.path)")
        print("CursorTrace: \(url.path)")
    }

    static func mark(_ text: String) { if isOn { write("=== \(text)") } }

    fileprivate static func log(_ op: String, _ cursor: NSCursor) {
        let name = CanvasPointerDevScript.name(cursor)
        let key = op + name
        guard op != "set" || key != last else { return }   // repeated identical sets are noise
        last = key
        let frames = Thread.callStackSymbols.dropFirst(3).prefix(14).map { "    " + $0 }.joined(separator: "\n")
        write("\(op) \(name)\n\(frames)")
    }

    private static func write(_ s: String) {
        let t = String(format: "%.3f", ProcessInfo.processInfo.systemUptime)
        handle?.write(Data("[\(t)] \(s)\n".utf8))
    }

    private static func swizzle(_ a: Selector, _ b: Selector) {
        guard let m1 = class_getInstanceMethod(NSCursor.self, a), let m2 = class_getInstanceMethod(NSCursor.self, b) else { return }
        method_exchangeImplementations(m1, m2)
    }
}

extension NSCursor {
    @objc fileprivate func traced_set() { CursorTrace.log("set", self); traced_set() }
    @objc fileprivate func traced_push() { CursorTrace.log("push", self); traced_push() }
    @objc fileprivate func traced_pop() { CursorTrace.log("pop", self); traced_pop() }
}
#endif
