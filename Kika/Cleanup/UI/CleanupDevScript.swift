//
//  CleanupDevScript.swift
//  Kika
//
//  DevScript (DEBUG) for Clean Up:
//    cleanup run all|last|<folder name> [similar,blurry,cropped] [low|medium|high]   run (waits until it ends)
//    cleanup sheet [folder name]          open the run sheet
//    cleanup show [similar|blurry|cropped|kept]   Library › Clean Up on that tab
//    cleanup keep <check> <file…> | cleanup reject <check> <file…> | cleanup again <check> <file…>
//    cleanup resolve <group #> <file to keep…>   keep those, reject the rest of the n-th group (0-based)
//    cleanup onimport on|off
//    cleanup dump                          groups, flagged, kept, last result
//

#if DEBUG
import Foundation

enum CleanupDevScript {
    static func run(_ arg: String, model: AppModel) async {
        let p = arg.split(separator: " ").map(String.init)
        let store = CleanupStore.shared
        func ids(_ names: ArraySlice<String>) -> [Int64] {
            let wanted = Set(names)
            return ((try? model.catalog.photos(in: .all)) ?? []).filter { wanted.contains($0.fileName) && $0.masterID == nil }.map(\.id)
        }
        func check(_ s: String) -> CleanupCheck? { CleanupCheck(rawValue: s) }
        switch p.first {
        case "run" where p.count >= 2:
            var options = store.options
            if p.count >= 3 { options.checks = Set(p[2].split(separator: ",").compactMap { CleanupCheck(rawValue: String($0)) }) }
            if p.count >= 4, let s = CleanupSensitivity(rawValue: p[3]) {
                options.blurSensitivity = s; options.cropSensitivity = s; options.similarSensitivity = s
            }
            let photos: [Photo]
            switch p[1] {
            case "all": photos = (try? model.catalog.photos(in: .all)) ?? []
            case "last": photos = (try? model.catalog.photos(in: .lastImport)) ?? []
            default:
                guard let f = model.folders.first(where: { $0.name == p[1] }) else { return print("DevScript cleanup: no folder \(p[1])") }
                photos = (try? model.catalog.photos(in: .folder(id: f.id, includeSubfolders: true))) ?? []
            }
            let start = Date()
            store.run(title: "DevScript \(p[1])", photoIDs: photos.map(\.id), options: options)
            while store.isRunning { try? await Task.sleep(for: .milliseconds(100)) }
            print(String(format: "DevScript cleanup: ran in %.1f s: %@", Date().timeIntervalSince(start), store.lastResultText ?? "-"))
        case "sheet":
            let folder = p.count > 1 ? model.folders.first { $0.name == p[1...].joined(separator: " ") } : nil
            store.presentRunSheet(folderIDs: folder.map { [$0.id] } ?? [])
        case "show":
            model.mode = .library
            model.selectSidebarItem(.cleanup)
            if p.count > 1 { UserDefaults.standard.set(p[1], forKey: "cleanup.tab") }
        case "keep" where p.count >= 3, "reject" where p.count >= 3, "again" where p.count >= 3:
            guard let c = check(p[1]) else { return print("DevScript cleanup: check is similar|blurry|cropped") }
            let targets = ids(p[2...])
            switch p[0] {
            case "keep": CleanupActions.keep(targets, check: c, model: model)
            case "reject": CleanupActions.reject(targets, check: c, model: model)
            default: CleanupActions.reviewAgain(targets, check: c, model: model)
            }
        case "resolve" where p.count >= 2:
            store.reload()
            guard let i = Int(p[1]), store.groups.indices.contains(i) else { return print("DevScript cleanup: no group \(p[1])") }
            CleanupActions.resolve(store.groups[i], keeping: Set(ids(p[2...])), model: model)
        case "onimport" where p.count >= 2:
            store.runOnImport = p[1] == "on"
        case "dump":
            store.reload()
            for (i, g) in store.groups.enumerated() {
                print("DevScript cleanup: group \(i) best=\(g.photos.first { $0.id == g.group.bestID }?.fileName ?? "?") "
                      + g.photos.map { "\($0.fileName)\($0.flag == .reject ? "(X)" : "")" }.joined(separator: " "))
            }
            for c in CleanupCheck.allCases {
                print("DevScript cleanup: \(c.rawValue) review=\(store.flagged[c]?.map(\.fileName) ?? []) kept=\(store.kept[c]?.map(\.fileName) ?? [])")
            }
            print("DevScript cleanup: analysed=\(store.analysedCount) review=\(store.reviewCount) onImport=\(store.runOnImport) last=\(store.lastResultText ?? "-")")
        default:
            print("DevScript cleanup: run | sheet | show | keep | reject | again | resolve | onimport | dump")
        }
    }
}
#endif
