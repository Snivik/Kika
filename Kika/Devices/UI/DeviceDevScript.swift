//
//  DeviceDevScript.swift
//  Kika
//
//  DEBUG-only DevScript commands for devices (`device <sub> [arg]`):
//    device filter <name|mac|off>   set the Device filter (photos + folder list)
//    device sheet                   open Move to Device for model.actionTargetIDs
//    device folder <name>           open it for a folder's photos (folder context menu)
//    device dest <folder>           use a folder as destination (no open panel; waits for the check)
//    device layout <yearAndDay|day|sameFolders|flat>
//    device trash <on|off>          Move the originals to the Trash
//    device run / wait / cancel     press Move / wait until finished (max 5 min) / press Stop
//    device snapshot <png>          PNG of the sheet
//    device close                   close the sheet (the app won't `quit` while a sheet is open)
//    device dump                    prints devices, filter, visible folders and the sheet state
//

#if DEBUG
import AppKit
import Foundation

enum DeviceDevScript {
    static func run(_ arg: String, model: AppModel) async {
        let parts = arg.split(separator: " ", maxSplits: 1).map(String.init)
        let rest = parts.count > 1 ? parts[1] : ""
        let c = DeviceMoveController.shared
        switch parts.first ?? "" {
        case "filter":
            model.filter.device = switch rest {
            case "off": nil
            case "mac": .thisMac
            default: .volume(rest)
            }
        case "sheet": c.present(ids: model.actionTargetIDs, model: model)
        case "folder":
            guard let folder = model.folders.first(where: { $0.name == rest }) else { print("DevScript: no folder \(rest)"); break }
            FolderActions.moveToDevice(folder.id, model: model)
        case "dest":
            c.useDestination(URL(fileURLWithPath: rest, isDirectory: true))
            await c.probeTask?.value
            print("DevScript: device destination \(c.destination?.path ?? "nil") problem: \(c.destinationProblem ?? "none")")
        case "layout": c.layout = DeviceMoveLayout(rawValue: rest) ?? c.layout
        case "trash": c.trashOriginals = rest == "on"
        case "run": c.start()
        case "wait":
            for _ in 0..<3000 where c.phase == .moving { try? await Task.sleep(for: .milliseconds(100)) }
            print("DevScript: device move \(c.result?.summary ?? "not finished")")
            for s in c.result?.skipped ?? [] { print("DevScript:   skipped \(s.fileName): \(s.reason)") }
        case "cancel": c.cancel()
        case "snapshot": snapshotSheet(to: rest)
        case "close": c.close(); c.isPresented = false
        case "dump":
            let store = DeviceStore.shared
            print("DevScript: devices \(store.devices.map { store.menuTitle($0) }) filter=\(model.filter.device?.title ?? "none") photos shown=\(model.photos.count)")
            let visible = FolderSidebarState.shared.visibleTree(model.folderTree, device: model.filter.device)
            func names(_ nodes: [FolderNode]) -> [String] { nodes.flatMap { [$0.folder.name] + names($0.children).map { "  " + $0 } } }
            print("DevScript: folders shown \(names(visible.nodes)) matching=\(visible.matching.map { $0.count } ?? -1)")
            print("DevScript: sheet presented=\(c.isPresented) sources=\(c.sources.map { "\($0.device.title):\($0.count)\($0.isOnline ? "" : "(offline)")" }) dest=\(c.destination?.path ?? "nil") problem=\(c.destinationProblem ?? "none") layout=\(c.layout.rawValue) trash=\(c.trashOriginals) canMove=\(c.canMove)")
            for p in model.photos.prefix(10) { print("DevScript:   \(p.displayTitle) → \(p.path)") }
        default: print("DevScript: unknown device command \(arg)")
        }
    }

    private static func snapshotSheet(to path: String) {
        guard let sheet = NSApp.windows.lazy.compactMap(\.attachedSheet).first else {
            print("DevScript: no sheet to snapshot")
            return
        }
        typealias CaptureFn = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage"),
              let image = unsafeBitCast(sym, to: CaptureFn.self)(.null, 1 << 3, UInt32(sheet.windowNumber), 1 << 0)?.takeRetainedValue(),
              let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            print("DevScript: sheet capture failed")
            return
        }
        try? data.write(to: URL(fileURLWithPath: path))
        print("DevScript: wrote \(path) (\(image.width)x\(image.height))")
    }
}
#endif
