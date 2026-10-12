//
//  TagModels.swift
//  sloproom
//
//  Tags: named keys with a list of allowed values ("Blurry": true | false, "Client": Anna | Ben), a colour,
//  and where they apply (photos, folders). A photo or folder holds at most ONE value per tag PER AUTHOR:
//  rows are (tag, author, value), each column single-purpose. The author says who set it: `TagAuthor.user`
//  for the owner, anything else for a workflow (e.g. "workflow:blur-check"). Effective value = the user's
//  if set, else the most recent workflow value; a workflow value without a user value is "to review".
//  Flag (pick / reject) and Rating stay columns on `photos` and appear beside tags as built-in filters
//  (`PhotoFilter.flag` / `minRating`). Storage + SQL: Catalog+Tags.swift. Engine code.
//

import Foundation

nonisolated enum TagAuthor {
    /// The catalog owner. Any other author is a workflow.
    static let user = "user"
    static func isUser(_ author: String) -> Bool { author == user }
}

nonisolated struct Tag: Identifiable, Hashable, Sendable {
    var id: Int64
    var name: String
    /// One of `TagColor` raw values.
    var color: TagColor
    /// Allowed values, in display order (at least one).
    var values: [String]
    var appliesToPhotos: Bool
    var appliesToFolders: Bool
    var sortOrder: Int

    static let defaultValues = ["true", "false"]

    /// Values that light the tag's dot on a photo / folder: everything but "false" / "no".
    static func isShown(_ value: String) -> Bool {
        !["false", "no"].contains(value.lowercased())
    }
}

/// Finder-like label colours.
nonisolated enum TagColor: String, CaseIterable, Hashable, Sendable, Codable {
    case red, orange, yellow, green, mint, blue, purple, pink, gray

    var title: String { rawValue.capitalized }
}

/// One stored value: who set which value when.
nonisolated struct TagValue: Hashable, Sendable {
    var author: String
    var value: String
    var setAt: Date
}

/// All values of one tag on one photo / folder (one per author).
nonisolated struct TagValues: Hashable, Sendable {
    var byAuthor: [TagValue] = []

    var mine: TagValue? { byAuthor.first { TagAuthor.isUser($0.author) } }
    /// The most recent workflow value.
    var suggested: TagValue? { byAuthor.filter { !TagAuthor.isUser($0.author) }.max { $0.setAt < $1.setAt } }
    /// The user's value, else the latest workflow value.
    var effective: TagValue? { mine ?? suggested }
    /// A workflow set a value and the user hasn't (yet).
    var needsReview: Bool { mine == nil && suggested != nil }
}

/// What a tag condition matches.
nonisolated enum TagMatch: Hashable, Sendable {
    /// Effective value (the user's, else the latest workflow's) equals the value.
    case value(String)
    /// Set by a workflow, not (yet) by the user; nil = any value.
    case toReview(String?)
}

nonisolated struct TagCondition: Hashable, Sendable {
    var tagID: Int64
    var match: TagMatch
}

nonisolated extension TagValues {
    /// In-memory twin of `Catalog.tagSQL` (folders are filtered in the sidebar, not in SQL).
    func satisfies(_ match: TagMatch) -> Bool {
        switch match {
        case .value(let v): effective?.value == v
        case .toReview(let v): needsReview && (v == nil || suggested?.value == v)
        }
    }
}

nonisolated extension Optional where Wrapped == TagValues {
    func satisfies(_ match: TagMatch) -> Bool { self?.satisfies(match) ?? false }
}
