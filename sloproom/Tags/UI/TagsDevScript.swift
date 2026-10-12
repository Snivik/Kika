//
//  TagsDevScript.swift
//  sloproom
//
//  DevScript (DEBUG) for tags:
//    tag new <name> [v1,v2,…] [folders]   create (default values true,false)
//    tag set <name> <value|none> [author]  on the action targets (author default: user; e.g. workflow:blur-check)
//    tag folder <name> <value|none> <folder name>
//    tag sidebar <name> <value|review>     select the sidebar row
//    tag filter <name> <value|review|none> add / remove a filter condition (filter bar)
//    tag confirm                           confirm suggestions on the action targets
//    tag edit <name> | tag editnew | tag close   open / close the editor sheet
//    tag dump                              tags, counts, filter, shown photos
//

#if DEBUG
import Foundation

enum TagsDevScript {
    static func run(_ arg: String, model: AppModel) {
        let p = arg.split(separator: " ").map(String.init)
        let store = TagStore.shared
        store.reloadTags(model.catalog)   // commands run back to back; `.tags` notifications arrive async
        func tag(_ name: String) -> Tag? { store.tags.first { $0.name.lowercased() == name.lowercased() } }
        func match(_ s: String) -> TagMatch { s == "review" ? .toReview(nil) : .value(s) }
        switch p.first {
        case "new" where p.count >= 2:
            let values = p.count > 2 ? p[2].split(separator: ",").map(String.init) : Tag.defaultValues
            do {
                try model.catalog.createTag(name: p[1], color: TagColor.allCases[store.tags.count % TagColor.allCases.count],
                                            values: values, folders: p.contains("folders"))
            } catch { model.report(error) }
        case "set" where p.count >= 3:
            guard let t = tag(p[1]) else { return print("DevScript tag: no tag \(p[1])") }
            do {
                try model.catalog.setPhotoTag(t.id, value: p[2] == "none" ? nil : p[2], author: p.count > 3 ? p[3] : TagAuthor.user,
                                              for: model.actionTargetIDs)
            } catch { model.report(error) }
        case "folder" where p.count >= 4:
            guard let t = tag(p[1]), let f = model.folders.first(where: { $0.name == p[3...].joined(separator: " ") }) else { return }
            TagActions.setFolders([f.id], tag: t.id, value: p[2] == "none" ? nil : p[2], model: model)
        case "sidebar" where p.count >= 3:
            guard let t = tag(p[1]) else { return }
            model.selectSidebarItem(.tag(t.id, match(p[2])))
        case "filter" where p.count >= 3:
            guard let t = tag(p[1]) else { return }
            model.filter.tags.removeAll { $0.tagID == t.id }
            if p[2] != "none" { model.filter.tags.append(TagCondition(tagID: t.id, match: match(p[2]))) }
        case "confirm":
            TagActions.confirmSuggested(model.actionTargetIDs, model: model)
        case "edit" where p.count >= 2:
            store.editing = tag(p[1])
        case "editnew":
            TagActions.newTag(model: model)
        case "close":
            store.editing = nil
        case "dump":
            for t in store.tags {
                let c = store.counts[t.id]
                print("DevScript tag: \(t.name) [\(t.color.rawValue)] values=\(t.values) photos=\(t.appliesToPhotos) folders=\(t.appliesToFolders) "
                      + "counts=\(c?.values ?? [:]) review=\(c?.toReview ?? 0)")
            }
            print("DevScript tag: filter=\(model.filter) item=\(model.sidebarItem) shown=\(model.photos.map(\.fileName))")
        default:
            print("DevScript tag: new | set | folder | sidebar | filter | confirm | edit | editnew | close | dump")
        }
    }
}
#endif
