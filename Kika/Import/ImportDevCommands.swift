//
//  ImportDevCommands.swift
//  Kika
//
//  DEBUG-only DevScript commands to drive the import sheet headlessly (paths inside the container):
//    importsheet                     open File > Import Photos…
//    importsource <folder>           scan a folder (no open panel)
//    importdest <folder>             use a folder as copy destination (registers a root)
//    importmode copy|inplace         import mode
//    importfolder <name>             "New folder" name
//    importrun                       press Import (a conflict asks Rename / Replace / Skip; the recap follows)
//    importconflict rename|replace|skip   answer the conflict prompt
//    importdetect on|off             "Don't import suspected duplicates"
//    importpattern yearday|day|none  destination subfolders
//    importwait                      wait until scanning / planning / importing is over (≤ 120 s)
//    importdump                      session state: counts, match states, destination plan, prompt, recap
//    importdone                      the recap's "Show Imported Photos" / "Done"
//    importmore                      the recap's "Import More"
//    importsnapshot <png>            PNG of the import sheet
//    importclose                     close the sheet (the app won't `quit` while a sheet is open)
//

#if DEBUG
import AppKit
import Foundation

enum ImportDevCommands {
    private static weak var session: ImportSession?
    private static var start: (() -> Void)?
    private static var done: (() -> Void)?

    static func attach(_ session: ImportSession, start: @escaping () -> Void, done: @escaping () -> Void) {
        self.session = session
        self.start = start
        self.done = done
    }

    static func run(_ command: String, arg: String, model: AppModel) async {
        switch command {
        case "importsheet": model.presentedSheet = .importPhotos
        case "importsource": session?.open(folder: URL(fileURLWithPath: arg, isDirectory: true))
        case "importdest":
            do { try session?.setDestination(folder: URL(fileURLWithPath: arg, isDirectory: true)) } catch { print("DevScript: \(error)") }
        case "importmode": session?.mode = arg == "inplace" ? .addInPlace : .copy
        case "importfolder": session?.newFolderName = arg
        case "importrun": start?()
        case "importconflict":
            session?.startImport(policy: ImportConflictPolicy(rawValue: arg) ?? .rename)
        case "importdetect": session?.skipDuplicates = arg != "off"
        case "importpattern": session?.pattern = arg == "day" ? .day : arg == "none" ? .none : .yearAndDay
        case "importwait": await waitIdle()
        case "importdump": dump()
        case "importdone": done?()
        case "importmore": session?.returnFromRecap()
        case "importsnapshot": snapshotSheet(to: arg)
        case "importclose": model.presentedSheet = nil
        default: print("DevScript: unknown import command \(command)")
        }
    }

    /// Waits until the session is idle (scan, destination preview, conflict check, import).
    private static func waitIdle() async {
        let deadline = Date().addingTimeInterval(120)
        repeat {
            try? await Task.sleep(for: .milliseconds(300))
        } while session.map { $0.isScanning || $0.isPlanning || $0.isPreparing || $0.isImporting } == true && Date() < deadline
    }

    private static func dump() {
        guard let s = session else { print("DevScript importdump: no session"); return }
        var states: [String: Int] = [:]
        for c in s.candidates { states["\(s.matchState(c))", default: 0] += 1 }
        print("importdump: source=\(s.sourceTitle) found=\(s.candidates.count) included=\(s.included.count) dups=\(s.duplicates.count) "
              + "states=\(states) ignored=\(s.ignoredFiles) canImport=\(s.canImport) error=\(s.errorMessage ?? "-")")
        if let plan = s.destinationPlan {
            print("importdump: plan conflicts=\(plan.conflictIDs.count)")
            for f in plan.folders {
                print("importdump:   \(String(repeating: "  ", count: f.depth))\(f.name) \(f.exists ? "exists" : "NEW") files=\(f.existingFiles) +\(f.adding) conflicts=\(f.conflicts)")
            }
        }
        if let p = s.conflictPrompt {
            print("importdump: prompt count=\(p.count) files=\(p.fileConflicts) catalog=\(p.catalogDuplicates) \(p.examples)")
        }
        if let sum = s.recap {
            let r = sum.result
            print("importdump: summary added=\(sum.added) replaced=\(sum.replaced) renamed=\(r.renamed) skippedDup=\(sum.skippedDuplicates.count) "
                  + "skippedConflicts=\(r.skippedConflicts.count) unchecked=\(sum.unchecked) failures=\(r.failures) stop=\(r.stopError.map { "\($0)" } ?? "-") "
                  + "folders=\(r.destinationFolders) created=\(r.createdFolders) ignored=\(sum.ignored)")
        }
    }

    /// Like DevScript.snapshot, but of the attached sheet window.
    /// The import sheet (attached to a top-level window); an alert on top of it is written next
    /// to `path` as `<name>-alert.png`.
    private static func snapshotSheet(to path: String) {
        guard let sheet = NSApp.windows.lazy.filter({ $0.sheetParent == nil && $0.isVisible }).compactMap(\.attachedSheet).first else {
            print("DevScript: no sheet to snapshot")
            return
        }
        capture(sheet, to: path)
        if let alert = sheet.attachedSheet {
            capture(alert, to: (path as NSString).deletingPathExtension + "-alert.png")
        }
    }

    private static func capture(_ sheet: NSWindow, to path: String) {
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
