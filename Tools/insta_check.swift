//
//  insta_check.swift
//  Instagram plans (Kika/Instagram): plans per folder, posts and story sets, slides, cells, layouts, splits,
//  the carousel limit, moves, usage labels, the "Instagram" photo filter, cascades and layout geometry.
//
//  Build & run:
//    Tools/harness.sh /private/tmp/claude-501/insta-out/insta_check Tools/insta_check.swift \
//      Kika/Instagram/InstaModels.swift Kika/Instagram/Catalog+Insta.swift
//    /private/tmp/claude-501/insta-out/insta_check [out-dir]
//
//  Writes only a temp catalog in out-dir. No sample photos needed (runs in CI).
//

import Foundation
import CoreGraphics

@main
struct InstaCheck {
    nonisolated(unsafe) static var failures = 0

    static func check(_ ok: Bool, _ name: String) {
        print("  \(ok ? "PASS" : "FAIL") \(name)")
        if !ok { failures += 1 }
    }

    static func main() async throws {
        let args = CommandLine.arguments
        let outDir = URL(fileURLWithPath: args.count > 1 ? args[1] : "/private/tmp/claude-501/insta-out")
        let dir = outDir.appendingPathComponent("insta-catalog-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: dir) }
        let catalog = try Catalog.open(at: dir)

        let ids = try catalog.insertPhotos((0..<30).map { i in
            var p = Photo(path: "/test/IMG_\(i).DNG")
            p.captureDate = Date(timeIntervalSince1970: 1_700_000_000 + Double(i))
            return p
        })
        func shown(_ insta: InstaUseFilter) throws -> [Int64] {
            try catalog.photos(in: .all, filter: PhotoFilter(insta: insta)).map(\.id)
        }

        print("Filter before any plan")
        check(try shown(.unused).count == 30 && (try shown(.used)).isEmpty, "no tables yet: all unused, none used")

        print("Plans")
        let folder = try catalog.createFolder(name: "Trip")
        let plan = try catalog.createInstaPlan(folderID: folder)
        check(try catalog.createInstaPlan(folderID: folder) == plan, "one plan per folder")
        check(try catalog.instaPlans().map(\.folderID) == [folder], "plan listed with its folder")

        print("Posts and story sets")
        let post1 = try catalog.createInstaPost(planID: plan, kind: .post)
        let story1 = try catalog.createInstaPost(planID: plan, kind: .story)
        let post2 = try catalog.createInstaPost(planID: plan, kind: .post)
        var posts = try catalog.instaPosts(planID: plan)
        check(posts.map(\.title) == ["Post 1", "Stories 1", "Post 2"], "auto titles per kind")
        check(posts.map(\.aspect) == [.portrait, .story, .portrait], "posts 4:5, stories 9:16")

        var edited = posts[0]
        edited.caption = "Golden hour #trip"
        edited.aspect = .tall
        edited.scheduledAt = Date(timeIntervalSince1970: 1_800_000_000)
        edited.status = .posted
        try catalog.updateInstaPost(edited)
        var story = posts[1]
        story.aspect = .square
        try catalog.updateInstaPost(story)
        posts = try catalog.instaPosts(planID: plan)
        check(posts[0].caption == "Golden hour #trip" && posts[0].aspect == .tall, "caption and aspect saved")
        check(posts[0].scheduledAt == Date(timeIntervalSince1970: 1_800_000_000), "date saved")
        check(posts[0].status == .posted && posts[0].postedAt != nil, "posted stamps posted_at")
        check(posts[1].aspect == .story, "stories stay 9:16")
        edited = posts[0]
        edited.status = .draft
        try catalog.updateInstaPost(edited)
        check(try catalog.instaPosts(planID: plan)[0].postedAt == nil, "leaving posted clears posted_at")

        print("Slides")
        let s = try catalog.addInstaSlides(postID: post1, photoIDs: [ids[0], ids[1], ids[2]])
        try catalog.addInstaSlides(postID: post1, photoIDs: [ids[3]], at: 1)
        posts = try catalog.instaPosts(planID: plan)
        check(posts[0].slides.map { $0.photoIDs } == [[ids[0]], [ids[3]], [ids[1]], [ids[2]]], "one slide per photo, inserted at index")
        check(posts[0].slides.map(\.sortOrder) == [0, 1, 2, 3], "slides renumbered")

        try catalog.moveInstaSlide(id: s[2], toPost: post1, index: 0)
        check(try catalog.instaPosts(planID: plan)[0].photoIDs == [ids[2], ids[0], ids[3], ids[1]], "move within a post")

        print("Story layouts")
        let frame = try catalog.addInstaSlide(postID: story1, layout: .grid4)
        check(try catalog.setInstaCells(slideID: frame, from: 1, photoIDs: [ids[4], ids[5], ids[6], ids[7]]) == 3, "fills cells from index, extras ignored")
        var storySlide = try catalog.instaPosts(planID: plan)[1].slides[0]
        check(storySlide.cells.map(\.index) == [1, 2, 3] && storySlide.photoIDs == [ids[4], ids[5], ids[6]], "cells stored by index")
        try catalog.setInstaCells(slideID: frame, from: 2, photoIDs: [ids[8]])
        try catalog.setInstaCellTransforms(slideID: frame, [1: InstaTransform(scale: 0.01, offsetX: 5, offsetY: -0.25, rotation: 270),
                                                            3: InstaTransform(scale: 1.5, rotation: -12.5)])
        storySlide = try catalog.instaPosts(planID: plan)[1].slides[0]
        check(storySlide.cell(2)?.photoID == ids[8], "dropping on a cell replaces it")
        check(storySlide.cell(1)?.transform == InstaTransform(scale: 0.1, offsetX: 3, offsetY: -0.25, rotation: -90), "transform clamped, rotation normalised")
        check(storySlide.cell(3)?.transform == InstaTransform(scale: 1.5, rotation: -12.5), "several cells saved at once")
        try catalog.setInstaCells(slideID: frame, from: 3, photoIDs: [ids[9]])
        check(try catalog.instaPosts(planID: plan)[1].slides[0].cell(3)?.transform.isIdentity == true, "a new photo starts centred")
        try catalog.setInstaSlideLayout(slideID: frame, layout: .stack2)
        storySlide = try catalog.instaPosts(planID: plan)[1].slides[0]
        check(storySlide.layout == .stack2 && storySlide.cells.map(\.index) == [1], "smaller layout drops extra cells")
        try catalog.clearInstaCell(slideID: frame, cell: 1)
        check(try catalog.instaPosts(planID: plan)[1].slides[0].isEmpty, "clear cell")

        print("Splits and the carousel limit")
        try catalog.setInstaSlideSpan(slideID: s[0], span: 3)
        posts = try catalog.instaPosts(planID: plan)
        check(posts[0].slides.first { $0.id == s[0] }?.span == 3 && posts[0].exportedSlideCount == 6, "split counts every strip")
        try catalog.setInstaSlideSpan(slideID: frame, span: 2)
        check(try catalog.instaPosts(planID: plan)[1].slides[0].span == 1, "stories don't split")
        try catalog.addInstaSlides(postID: post2, photoIDs: Array(ids[10..<29]))
        check((try? catalog.addInstaSlides(postID: post2, photoIDs: [ids[29], ids[0]])) == nil, "21st slide refused")
        check(try catalog.instaPosts(planID: plan)[2].slides.count == 19, "refused add changes nothing")
        check((try? catalog.setInstaSlideSpan(slideID: try catalog.instaPosts(planID: plan)[2].slides[0].id, span: 3)) == nil,
              "split past the limit refused")
        try catalog.moveInstaSlide(id: s[0], toPost: story1, index: 0)
        posts = try catalog.instaPosts(planID: plan)
        check(posts[1].slides.first?.id == s[0] && posts[1].slides.first?.span == 1, "slide moved to stories loses its split")
        check(posts[0].slides.map(\.sortOrder) == [0, 1, 2], "source post renumbered")
        try catalog.setInstaSlideLayout(slideID: s[1], layout: .single)
        try catalog.setInstaSlideSpan(slideID: s[1], span: 2)
        try catalog.setInstaSlideLayout(slideID: s[1], layout: .side2)
        check(try catalog.instaPosts(planID: plan)[0].slides.first { $0.id == s[1] }?.span == 1, "multi-cell layout ends a split")

        print("Usage")
        let usage = try catalog.instaUsage()
        check(usage[ids[0]]?.map(\.label) == ["S1"], "moved photo is used in S1")
        check(usage[ids[3]]?.map(\.label) == ["P1"], "label P1")
        check(usage[ids[12]]?.map(\.label) == ["P2"], "label P2")
        try catalog.addInstaSlides(postID: post2, photoIDs: [])
        try catalog.moveInstaPost(id: post2, to: 0)
        posts = try catalog.instaPosts(planID: plan)
        check(posts.map(\.id) == [post2, post1, story1], "move post")
        let other = try catalog.createFolder(name: "Other")
        let otherPost = try catalog.createInstaPost(planID: try catalog.createInstaPlan(folderID: other), kind: .story)
        let all = try catalog.instaPosts(planID: nil)
        check(all.map(\.id) == [post2, post1, story1, otherPost] && all[0].slides.count == 19, "every plan's posts, with slides (calendar)")
        try catalog.deleteFolder(id: other)
        check(try catalog.instaUsage()[ids[12]]?.map(\.label) == ["P1"], "numbers follow board order")
        check(try shown(.used).count == usage.count, "used filter")
        check(try shown(.unused).count == 30 - usage.count, "unused filter")

        print("Cascades")
        try catalog.removePhotos(ids: [ids[3]])
        check(try catalog.instaPosts(planID: plan)[1].photoIDs.contains(ids[3]) == false, "removed photo leaves its cell")
        try catalog.deleteInstaPost(id: post2)
        check(try catalog.instaPosts(planID: plan).map(\.id) == [post1, story1], "delete post")
        try catalog.deleteFolder(id: folder)
        check(try catalog.instaPlans().isEmpty, "deleting the folder deletes its plan")
        check(try catalog.instaUsage().isEmpty && (try shown(.used)).isEmpty, "nothing used after cascade")

        print("Layout geometry")
        let size = CGSize(width: 1080, height: 1920)
        check(InstaLayout.single.cellRects(in: size, gap: 0) == [CGRect(origin: .zero, size: size)], "single, no gap")
        let stack = InstaLayout.stack2.cellRects(in: size, gap: 0.02)
        let g = 0.02 * 1080
        check(abs(stack[0].minX - g) < 0.001 && abs(stack[0].minY - g) < 0.001, "outer margin = gap")
        check(abs(stack[1].minY - stack[0].maxY - g) < 0.001, "inner gap = gap")
        check(abs(stack[1].maxY - (1920 - g)) < 0.001 && abs(stack[0].height - stack[1].height) < 0.001, "equal cells")
        let feature = InstaLayout.feature3.cellRects(in: size, gap: 0)
        check(feature.count == 3 && abs(feature[0].height - 1280) < 0.001 && abs(feature[2].minX - 540) < 0.001, "1 large + 2 small")
        check(InstaLayout.allCases.allSatisfy { $0.cellRects(in: size, gap: 0.01).count == $0.cellCount }, "cell counts")
        check(InstaAspect.portrait.pixelSize == CGSize(width: 1080, height: 1350) && InstaAspect.story.pixelSize == CGSize(width: 1080, height: 1920),
              "export sizes")

        print("Framing")
        let portrait = CGSize(width: 2000, height: 3000), strip = CGSize(width: 1200, height: 500)   // a photo in a 3-slide split
        var pl = InstaFraming.placement(imageSize: portrait, cellSize: strip, transform: InstaTransform())
        check(pl.center == CGPoint(x: 600, y: 250) && abs(pl.size.width - 1200) < 0.001 && abs(pl.size.height - 1800) < 0.001,
              "identity = aspect-fill, centred")
        pl = InstaFraming.placement(imageSize: portrait, cellSize: strip, transform: InstaTransform(scale: 2, offsetX: 0.25, offsetY: -0.5, rotation: 90))
        check(pl.center == CGPoint(x: 900, y: 0) && abs(pl.size.width - 2400) < 0.001 && abs(pl.radians - .pi / 2) < 0.0001,
              "scale, offset in cell fractions, rotation")
        check(InstaFraming.covers(imageSize: portrait, cellSize: strip, transform: InstaTransform()), "identity covers")
        check(!InstaFraming.covers(imageSize: portrait, cellSize: strip, transform: InstaTransform(scale: 0.9)), "smaller leaves background")
        check(!InstaFraming.covers(imageSize: portrait, cellSize: strip, transform: InstaTransform(offsetX: 0.2)), "moved sideways without overflow leaves background")
        check(!InstaFraming.covers(imageSize: portrait, cellSize: strip, transform: InstaTransform(rotation: 10)), "rotated at fill leaves corners")
        let cover = InstaFraming.coverScale(imageSize: portrait, cellSize: strip, rotation: 10)
        check(cover > 1 && InstaFraming.covers(imageSize: portrait, cellSize: strip, transform: InstaTransform(scale: cover, rotation: 10))
              && !InstaFraming.covers(imageSize: portrait, cellSize: strip, transform: InstaTransform(scale: cover * 0.98, rotation: 10)),
              "coverScale is the smallest covering scale")
        check(abs(InstaFraming.coverScale(imageSize: portrait, cellSize: strip, rotation: 0) - 1) < 0.0001, "coverScale at 0° = 1")
        let fit = InstaFraming.fitScale(imageSize: portrait, cellSize: strip, rotation: 0)
        check(abs(fit - 500.0 / 1800) < 0.0001, "fitScale shows the whole photo")
        let big = InstaFraming.placement(imageSize: CGSize(width: 4000, height: 6000), cellSize: CGSize(width: 2400, height: 1000),
                                         transform: InstaTransform(scale: 1.3, offsetX: 0.2, offsetY: -0.1, rotation: 7))
        let small = InstaFraming.placement(imageSize: portrait, cellSize: strip, transform: InstaTransform(scale: 1.3, offsetX: 0.2, offsetY: -0.1, rotation: 7))
        check(abs(big.center.x / 2 - small.center.x) < 0.001 && abs(big.size.width / 2 - small.size.width) < 0.001, "same framing at any render size")

        print(failures == 0 ? "ALL PASS" : "\(failures) FAILURE(S)")
        exit(failures == 0 ? 0 : 1)
    }
}
