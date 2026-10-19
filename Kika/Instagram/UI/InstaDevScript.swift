//
//  InstaDevScript.swift
//  Kika
//
//  DevScript (DEBUG) for Instagram plans (post / slide numbers are 1-based, in board order):
//    insta plan <folder name>              create / show the folder's plan (a new plan starts with one post)
//    insta post | insta story              new post / set of stories with the grid selection
//    insta add <post> <first> <count>      add pool photos first…first+count-1 (0-based grid indices) as slides
//    insta addf <post> <name,name…>        add pool photos by file name (without extension) as slides
//    insta fillf <post> <slide> <cell> <name,name…>   pool photos by file name into cells
//    insta title <post> <text…>
//    insta layout <post> <slide> <layout>  single | stack2 | side2 | stack3 | grid4 | feature3
//    insta fill <post> <slide> <cell> <first> <count>   pool photos into cells
//    insta split <post> <slide> <n>        split across n slides
//    insta frame <post> <slide> <cell> <scale> <offsetX> <offsetY> [rotation]   a cell's transform
//    insta adjust <post> <slide> | insta adjust close   open / close the Adjust Photos editor
//    insta caption <post> <text…> | insta date <post> <unix seconds> | insta status <post> <draft|ready|posted>
//    insta filter <any|unused|used>        the Instagram filter of the pool
//    insta calendar [both|post|story] | insta month <YYYY-MM>   show the calendar (filter) / a month
//    insta open <n>                        open the n-th of every plan's posts on its board (as a calendar click)
//    insta export slide <post> <slide> <folder> | insta export post <post> <folder> | insta export plan <folder>
//                                          export into a folder (no open panel; the sheet shows progress)
//    insta export wait | dump | close      wait for it to finish (max 5 min) / print the result / close the sheet
//    insta dump                            plans, posts, slides, usage
//

#if DEBUG
import Foundation

enum InstaDevScript {
    static func run(_ arg: String, model: AppModel) async {
        let p = arg.split(separator: " ").map(String.init)
        let store = InstaStore.shared
        store.load(model.catalog)   // commands run back to back; `.insta` notifications arrive async
        func post(_ s: String) -> InstaPost? { Int(s).flatMap { store.posts.indices.contains($0 - 1) ? store.posts[$0 - 1] : nil } }
        func slide(_ post: InstaPost, _ s: String) -> InstaSlide? { Int(s).flatMap { post.slides.indices.contains($0 - 1) ? post.slides[$0 - 1] : nil } }
        func pool(_ first: String, _ count: String) -> [Int64] {
            let a = Int(first) ?? 0, n = Int(count) ?? 1
            return model.photos.indices.filter { $0 >= a && $0 < a + n }.map { model.photos[$0].id }
        }
        func named(_ list: String) -> [Int64] {
            list.split(separator: ",").compactMap { n in
                model.photos.first { ($0.fileName as NSString).deletingPathExtension == n }?.id
            }
        }
        do {
            switch p.first {
            case "addf" where p.count >= 3:
                guard let target = post(p[1]) else { return print("DevScript insta: no post \(p[1])") }
                try model.catalog.addInstaSlides(postID: target.id, photoIDs: named(p[2]))
            case "fillf" where p.count >= 5:
                guard let t = post(p[1]), let s = slide(t, p[2]) else { return print("DevScript insta: bad fillf args") }
                try model.catalog.setInstaCells(slideID: s.id, from: Int(p[3]) ?? 0, photoIDs: named(p[4]))
            case "title" where p.count >= 3:
                guard var t = post(p[1]) else { return }
                t.title = p.dropFirst(2).joined(separator: " ")
                try model.catalog.updateInstaPost(t)
            case "plan" where p.count >= 2:
                let name = p[1...].joined(separator: " ")
                guard let f = model.folders.first(where: { $0.name == name }) else { return print("DevScript insta: no folder \(name)") }
                InstaActions.showPlan(folderID: f.id, model: model)
            case "post": InstaActions.newPost(.post, photoIDs: model.orderedSelection, model: model)
            case "story": InstaActions.newPost(.story, photoIDs: model.orderedSelection, model: model)
            case "add" where p.count >= 4:
                guard let target = post(p[1]) else { return print("DevScript insta: no post \(p[1])") }
                try model.catalog.addInstaSlides(postID: target.id, photoIDs: pool(p[2], p[3]))
            case "layout" where p.count >= 4:
                guard let t = post(p[1]), let s = slide(t, p[2]), let layout = InstaLayout(rawValue: p[3]) else { return print("DevScript insta: bad layout args") }
                try model.catalog.setInstaSlideLayout(slideID: s.id, layout: layout)
            case "fill" where p.count >= 6:
                guard let t = post(p[1]), let s = slide(t, p[2]) else { return print("DevScript insta: bad fill args") }
                try model.catalog.setInstaCells(slideID: s.id, from: Int(p[3]) ?? 0, photoIDs: pool(p[4], p[5]))
            case "split" where p.count >= 4:
                guard let t = post(p[1]), let s = slide(t, p[2]) else { return print("DevScript insta: bad split args") }
                try model.catalog.setInstaSlideSpan(slideID: s.id, span: Int(p[3]) ?? 1)
            case "frame" where p.count >= 7:
                guard let t = post(p[1]), let s = slide(t, p[2]), let cell = Int(p[3]) else { return print("DevScript insta: bad frame args") }
                let transform = InstaTransform(scale: Double(p[4]) ?? 1, offsetX: Double(p[5]) ?? 0, offsetY: Double(p[6]) ?? 0,
                                               rotation: p.count > 7 ? Double(p[7]) ?? 0 : 0)
                InstaActions.setTransforms([cell: transform], slideID: s.id, model: model)
            case "adjust" where p.count >= 2:
                if p[1] == "close" { store.editingSlideID = nil; return }
                guard p.count >= 3, let t = post(p[1]), let s = slide(t, p[2]) else { return print("DevScript insta: bad adjust args") }
                InstaActions.adjust(s)
            case "caption" where p.count >= 2:
                guard var t = post(p[1]) else { return }
                t.caption = p.dropFirst(2).joined(separator: " ")
                try model.catalog.updateInstaPost(t)
            case "date" where p.count >= 3:
                guard var t = post(p[1]) else { return }
                t.scheduledAt = Double(p[2]).map(Date.init(timeIntervalSince1970:))
                try model.catalog.updateInstaPost(t)
            case "status" where p.count >= 3:
                guard var t = post(p[1]), let s = InstaStatus(rawValue: p[2]) else { return }
                t.status = s
                try model.catalog.updateInstaPost(t)
            case "calendar":
                if p.count >= 2 { UserDefaults.standard.set(p[1], forKey: "insta.calendar.kinds") }
                model.selectSidebarItem(.instaCalendar)
            case "open" where p.count >= 2:   // a post as the calendar opens it (index among every plan's posts)
                guard let i = Int(p[1]), store.allPosts.indices.contains(i - 1) else { return }
                InstaActions.open(store.allPosts[i - 1], model: model)
            case "month" where p.count >= 2:
                let f = DateFormatter()
                f.dateFormat = "yyyy-MM"
                if let d = f.date(from: p[1]) { store.calendarMonth = d }
            case "filter" where p.count >= 2:
                model.filter.insta = InstaUseFilter(rawValue: p[1]) ?? .any
            case "export" where p.count >= 2:
                await export(Array(p.dropFirst()), model: model, post: post, slide: slide)
            case "dump":
                print("insta plans: \(store.plans.map { "#\($0.id) folder \($0.folderID)" }) shown \(store.shownPlanID.map(String.init) ?? "none")")
                for (i, t) in store.posts.enumerated() {
                    print("  \(i + 1). \(t.kind.rawValue) “\(t.title)” \(t.aspect.rawValue) \(t.status.rawValue) date \(t.scheduledAt.map { "\($0)" } ?? "-") caption \(t.caption.count) chars")
                    for s in t.slides {
                        let framing = s.cells.map { c in
                            let t = c.transform
                            return "\(c.index):\(t.scale),\(t.offsetX),\(t.offsetY),\(t.rotation)°"
                        }.joined(separator: " ")
                        print("     slide \(s.layout.rawValue) span \(s.span) photos \(s.photoIDs) framing \(framing)")
                    }
                }
                print("  used photos: \(store.usage.count); pool \(model.photos.count) shown")
            default:
                print("DevScript insta: unknown \(arg)")
            }
        } catch {
            model.report(error)
        }
    }

    private static func export(_ p: [String], model: AppModel, post: (String) -> InstaPost?, slide: (InstaPost, String) -> InstaSlide?) async {
        let c = InstaExportController.shared
        func folder(_ from: Int) -> URL { URL(fileURLWithPath: p.dropFirst(from).joined(separator: " "), isDirectory: true) }
        switch p[0] {
        case "slide" where p.count >= 4:
            guard let t = post(p[1]), let s = slide(t, p[2]) else { return print("DevScript insta: bad export slide args") }
            c.start(.slide(s.id), name: "\(t.title), slide \(p[2])", destination: folder(3), catalog: model.catalog)
        case "post" where p.count >= 3:
            guard let t = post(p[1]) else { return print("DevScript insta: no post \(p[1])") }
            c.start(.post(t.id), name: t.title, destination: folder(2), catalog: model.catalog)
        case "plan" where p.count >= 2:
            guard let id = InstaStore.shared.shownPlanID else { return print("DevScript insta: no plan shown") }
            let folderID = InstaStore.shared.plan(id)?.folderID
            c.start(.plan(id), name: model.folders.first { $0.id == folderID }?.name ?? "plan", destination: folder(1), catalog: model.catalog)
        case "wait":
            for _ in 0..<3000 where c.phase == .exporting { try? await Task.sleep(for: .milliseconds(100)) }
            print("DevScript insta: export \(c.result?.summary ?? "not finished")")
        case "dump":
            print("DevScript insta: export phase=\(c.phase) progress=\(c.progress.done)/\(c.progress.total) dest=\(c.destination?.path ?? "nil")")
            for f in c.result?.files ?? [] { print("DevScript insta:   \(f.path)") }
            for s in c.result?.skipped ?? [] { print("DevScript insta:   skipped \(s.fileName) (\(s.photoName)): \(s.reason)") }
            if let e = c.result?.stopError { print("DevScript insta:   stopped: \(e)") }
        case "close": c.close()
        default: print("DevScript insta: unknown export \(p.joined(separator: " "))")
        }
    }
}
#endif
