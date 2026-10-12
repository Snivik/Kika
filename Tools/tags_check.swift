//
//  tags_check.swift
//  Tags (sloproom/Tags): definitions, per-author values, effective value / to-review filtering, confirm,
//  value-list edits, folder tags, cascades.
//
//  Build & run:
//    Tools/harness.sh /private/tmp/claude-501/tags-out/tags_check Tools/tags_check.swift
//    /private/tmp/claude-501/tags-out/tags_check [out-dir]
//
//  Writes only a temp catalog in out-dir. No sample photos needed (runs in CI).
//

import Foundation

@main
struct TagsCheck {
    nonisolated(unsafe) static var failures = 0

    static func check(_ ok: Bool, _ name: String) {
        print("  \(ok ? "PASS" : "FAIL") \(name)")
        if !ok { failures += 1 }
    }

    static func main() async throws {
        let args = CommandLine.arguments
        let outDir = URL(fileURLWithPath: args.count > 1 ? args[1] : "/private/tmp/claude-501/tags-out")
        let dir = outDir.appendingPathComponent("tags-catalog-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: dir) }
        let catalog = try Catalog.open(at: dir)

        let ids = try catalog.insertPhotos((0..<6).map { i in
            var p = Photo(path: "/test/IMG_\(i).DNG")
            p.captureDate = Date(timeIntervalSince1970: 1_700_000_000 + Double(i))
            return p
        })
        func shown(_ conditions: [TagCondition], flag: FlagFilter = .all) throws -> [Int64] {
            try catalog.photos(in: .all, filter: PhotoFilter(flag: flag, tags: conditions)).map(\.id)
        }

        print("Definitions")
        let blurry = try catalog.createTag(name: "  Blurry ", color: .red)
        let client = try catalog.createTag(name: "Client", color: .blue, values: ["Anna", " Ben", "anna", ""], photos: true, folders: true)
        var tags = try catalog.allTags()
        check(tags.map(\.name) == ["Blurry", "Client"], "names trimmed, creation order")
        check(tags[0].values == ["true", "false"], "default values true / false")
        check(tags[1].values == ["Anna", "Ben"], "values trimmed, deduplicated case-insensitively, empties dropped")
        check(tags[1].appliesToFolders && !tags[0].appliesToFolders, "scope stored")
        check((try? catalog.createTag(name: "blurry", color: .red)) == nil, "names unique case-insensitively")
        check(try catalog.uniqueTagName("Blurry") == "Blurry 2", "uniqueTagName")

        print("Values by author")
        let workflow = "workflow:blur-check"
        try catalog.setPhotoTag(blurry, value: "true", author: workflow, for: [ids[0], ids[1], ids[2]])
        try catalog.setPhotoTag(blurry, value: "false", author: workflow, for: [ids[3]])
        try catalog.setPhotoTag(blurry, value: "false", for: [ids[1]])          // user overrides the workflow
        try catalog.setPhotoTag(blurry, value: "true", for: [ids[4]])           // user only
        var values = try catalog.photoTagValues()
        check(values[ids[1]]?[blurry]?.byAuthor.count == 2, "user and workflow rows side by side")
        check(values[ids[1]]?[blurry]?.effective?.value == "false", "user value wins")
        check(values[ids[0]]?[blurry]?.effective?.value == "true" && values[ids[0]]?[blurry]?.needsReview == true,
              "workflow-only value is effective and needs review")
        check(values[ids[5]] == nil, "untagged photo has no values")

        print("Filtering")
        check(try shown([TagCondition(tagID: blurry, match: .value("true"))]) == [ids[0], ids[2], ids[4]],
              "Blurry = true: effective values (workflow 0, 2; user 4; user 'false' hides 1)")
        check(try shown([TagCondition(tagID: blurry, match: .value("false"))]) == [ids[1], ids[3]], "Blurry = false")
        check(try shown([TagCondition(tagID: blurry, match: .toReview(nil))]) == [ids[0], ids[2], ids[3]], "to review: any value")
        check(try shown([TagCondition(tagID: blurry, match: .toReview("true"))]) == [ids[0], ids[2]], "to review: true")
        // A later workflow run changes its mind on 2: the latest workflow value is the effective one.
        try await Task.sleep(for: .milliseconds(20))
        try catalog.setPhotoTag(blurry, value: "false", author: "workflow:second-opinion", for: [ids[2]])
        check(try shown([TagCondition(tagID: blurry, match: .value("true"))]) == [ids[0], ids[4]], "latest workflow value wins")
        check(try catalog.photoTagValues()[ids[2]]?[blurry]?.suggested?.author == "workflow:second-opinion", "suggested = latest")
        try catalog.setFlag(.pick, for: [ids[0]])
        check(try shown([TagCondition(tagID: blurry, match: .value("true"))], flag: .picked) == [ids[0]], "tags AND flag")
        try catalog.setPhotoTag(client, value: "Anna", for: [ids[0], ids[4]])
        check(try shown([TagCondition(tagID: blurry, match: .value("true")), TagCondition(tagID: client, match: .value("Anna"))])
              == [ids[0], ids[4]], "two tags AND")
        let folder = try catalog.createFolder(name: "F")
        try catalog.addPhotos([ids[0], ids[1], ids[4]], toFolder: folder)
        check(try catalog.photos(in: .folder(id: folder, includeSubfolders: false),
                                 filter: PhotoFilter(tags: [TagCondition(tagID: blurry, match: .value("true"))])).map(\.id) == [ids[0], ids[4]],
              "tag filter inside a folder")
        check(try catalog.photos(in: .folder(id: folder, includeSubfolders: true),
                                 filter: PhotoFilter(tags: [TagCondition(tagID: blurry, match: .value("true"))])).map(\.id) == [ids[0], ids[4]],
              "tag filter with subfolders (recursive query)")

        print("Confirm suggestions")
        let n = try catalog.confirmSuggestedPhotoTags(for: [ids[0], ids[1], ids[2], ids[5]])
        values = try catalog.photoTagValues()
        check(n == 2, "confirms only photos without a user value (0, 2), got \(n)")
        check(values[ids[0]]?[blurry]?.mine?.value == "true" && values[ids[2]]?[blurry]?.mine?.value == "false",
              "confirmed value = latest workflow value")
        check(values[ids[1]]?[blurry]?.mine?.value == "false", "existing user value untouched")
        check(try shown([TagCondition(tagID: blurry, match: .toReview(nil))]) == [ids[3]], "confirmed photos leave To Review")
        try catalog.setPhotoTag(blurry, value: nil, for: [ids[0]])
        check(try catalog.photoTagValues()[ids[0]]?[blurry]?.mine == nil, "clearing removes only the user's row")
        check(try shown([TagCondition(tagID: blurry, match: .toReview(nil))]) == [ids[0], ids[3]], "cleared: back to review")

        print("Editing values")
        tags = try catalog.allTags()
        var c = tags.first { $0.id == client }!
        c.values = ["Ben", "Cara"]
        check(try catalog.tagValuesLost(by: c).photos == 2, "editor warns: 2 photos lose 'Anna'")
        try catalog.updateTag(c)
        check(try catalog.photoTagValues().values.allSatisfy { $0[client] == nil }, "dropped value removed from photos")
        check(try catalog.allTags().first { $0.id == client }?.values == ["Ben", "Cara"], "new values saved")

        print("Folders")
        try catalog.setFolderTag(client, value: "Ben", for: [folder])
        check(try catalog.folderTagValues()[folder]?[client]?.effective?.value == "Ben", "folder value")
        c.appliesToFolders = false
        try catalog.updateTag(c)
        check(try catalog.folderTagValues().isEmpty, "tag no longer for folders: folder values removed")

        print("Cascades")
        try catalog.removePhotos(ids: [ids[3]])
        check(try catalog.photoTagValues()[ids[3]] == nil, "removing a photo removes its values")
        try catalog.deleteTag(blurry)
        check(try catalog.photoTagValues().values.allSatisfy { $0[blurry] == nil }, "deleting a tag removes its values")
        check(try catalog.allTags().map(\.name) == ["Client"], "tag deleted")

        print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILURE(S)")
        exit(failures == 0 ? 0 : 1)
    }
}
