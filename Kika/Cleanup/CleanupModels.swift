//
//  CleanupModels.swift
//  Kika
//
//  Clean Up: finds photos you can probably remove: similar shots taken one after another (stacks, like a
//  phone's), blurry subjects and cropped subjects. On-device only (Vision + Accelerate; CleanupAnalyzer.swift).
//
//  Results are TAG VALUES written by the workflow author `CleanupTags.author` ("workflow:cleanup") on three
//  tags created on demand: Blurry, Cropped, Duplicate (true / false). The tag rules (Tags/TagModels.swift) give
//  "kept by you" for free: the user's own value always wins over a workflow's, so
//    - Keep   = your value "false" (not blurry / not cropped / not a duplicate): later runs still store their
//               own value, but it is never effective again, so the photo never comes back for review;
//    - Reject = your value "true" + the Reject flag (Library › Rejected, then Remove from Catalog…).
//  To review = a workflow "true" without a value of yours (`TagMatch.toReview("true")`).
//  Similar groups live in `cleanup_groups` (Catalog+Cleanup.swift); a group is up for review while one of its
//  photos has a Duplicate value to review. Analysis (scores + feature print) is cached per photo and edit
//  version in `cleanup_analysis`, so re-runs and sensitivity changes don't re-analyse.
//  Engine code (no SwiftUI / AppKit).
//

import Foundation

/// One kind of clean-up check.
nonisolated enum CleanupCheck: String, CaseIterable, Codable, Hashable, Sendable, Identifiable {
    case similar, blurry, cropped
    var id: String { rawValue }

    var title: String {
        switch self {
        case .similar: "Similar Shots"
        case .blurry: "Blurry"
        case .cropped: "Cropped Subjects"
        }
    }

    /// The tag holding this check's results.
    var tagName: String {
        switch self {
        case .similar: "Duplicate"
        case .blurry: "Blurry"
        case .cropped: "Cropped"
        }
    }

    var tagColor: TagColor {
        switch self {
        case .similar: .purple
        case .blurry: .orange
        case .cropped: .yellow
        }
    }

    var symbol: String {
        switch self {
        case .similar: "square.stack.3d.down.right"
        case .blurry: "drop.degreesign"
        case .cropped: "crop"
        }
    }
}

nonisolated enum CleanupTags {
    /// Author of every value a clean-up run writes.
    static let author = "workflow:cleanup"
    static let yes = "true"
    static let no = "false"
}

/// How eager a check is.
nonisolated enum CleanupSensitivity: String, CaseIterable, Codable, Hashable, Sendable, Identifiable {
    case low, medium, high
    var id: String { rawValue }
    var title: String {
        switch self {
        case .low: "Only Obvious"
        case .medium: "Balanced"
        case .high: "More"
        }
    }
}

/// What a run looks for (remembered in UserDefaults by the UI).
nonisolated struct CleanupOptions: Hashable, Sendable, Codable {
    var checks: Set<CleanupCheck> = Set(CleanupCheck.allCases)
    var blurSensitivity: CleanupSensitivity = .medium
    var cropSensitivity: CleanupSensitivity = .medium
    var similarSensitivity: CleanupSensitivity = .medium
    /// Longest pause between two shots of one similar group.
    var maxGapSeconds: Double = 120

    /// Below this sharpness a photo is blurry (`CleanupAnalysis.sharpness`, 0…1).
    var blurThreshold: Double {
        switch blurSensitivity {
        case .low: 0.12
        case .medium: 0.2
        case .high: 0.3
        }
    }

    /// From this crop score on a photo has a cropped subject (`CleanupAnalysis.cropScore`, 0…1).
    var cropThreshold: Double {
        switch cropSensitivity {
        case .low: 0.85
        case .medium: 0.6
        case .high: 0.4
        }
    }

    /// Largest feature-print distance between neighbouring shots of one group (bursts get a little more, shots
    /// further apart less: `CleanupGrouping.allowance`). Burst frames measure 0.1…0.3; another person on the same
    /// spot 0.37…0.5; another scene ≥ 0.55.
    var similarDistance: Float {
        switch similarSensitivity {
        case .low: 0.25
        case .medium: 0.33
        case .high: 0.42
        }
    }
}

/// What the analyser measured on one photo.
nonisolated struct CleanupAnalysis: Hashable, Sendable {
    /// Subject sharpness, 0 (mush) … 1 (crisp). Measured where the subject is (faces, else salient objects,
    /// else the whole frame), on the sharpest part of it, so a soft background doesn't count.
    var sharpness: Double
    /// 0 = nothing cut; 1 = a face or head is surely cut by the frame.
    var cropScore: Double
    /// Why the crop score is high ("Face cut at the left edge"), nil when nothing is cut.
    var cropReason: String?
    /// Vision's aesthetics score, -1 … 1 (the best shot of a group); 0 when unavailable.
    var quality: Double
    /// Vision image feature print (similar shots); empty when unavailable.
    var feature: [Float]
}

/// One group of similar shots, in capture order.
nonisolated struct CleanupGroup: Hashable, Sendable, Identifiable {
    /// The smallest photo id of the group (stable across runs while the group doesn't change much).
    var id: Int64
    var photoIDs: [Int64]
    /// The suggested keeper.
    var bestID: Int64
}

/// What the grouping needs to know about one photo.
nonisolated struct CleanupGroupingItem: Sendable {
    var id: Int64
    /// Capture date, else import date.
    var date: Date
    var fileName: String
    var feature: [Float]
    /// Ranking for the keeper: picked / rated photos first, then quality + sharpness.
    var flag: Flag = .none
    var rating: Int = 0
    /// You kept it in an earlier review (your Duplicate value "false").
    var kept = false
    var quality: Double = 0
    var sharpness: Double = 0
}

nonisolated enum CleanupGrouping {
    /// Euclidean distance between two feature prints (what Vision's `computeDistance` does); ∞ if they don't match.
    static func distance(_ a: [Float], _ b: [Float]) -> Float {
        guard !a.isEmpty, a.count == b.count else { return .infinity }
        var sum: Float = 0
        for i in a.indices { let d = a[i] - b[i]; sum += d * d }
        return sum.squareRoot()
    }

    /// Distance allowance by the pause between two shots: a burst (≤ 2 s) × 1.15, ≤ 10 s × 1, longer × 0.85.
    static func allowance(gap: TimeInterval) -> Float { gap <= 2 ? 1.15 : gap <= 10 ? 1 : 0.85 }

    /// A missed-focus or shaken frame looks less like its sharp neighbours to the feature print (a 4 px defocus:
    /// 0.64 apart), yet it's the one to drop: twice the room when either shot is blurry and they're ≤ 10 s apart.
    static func blurAllowance(_ a: CleanupGroupingItem, _ b: CleanupGroupingItem, gap: TimeInterval) -> Float {
        gap <= 10 && min(a.sharpness, b.sharpness) < CleanupOptions().blurThreshold ? 2 : 1
    }

    /// Groups shots taken one after another (≤ `maxGap` apart) that look alike (each within `maxDistance` ×
    /// `allowance` of the previous shot and within 1.25 × `maxDistance` of the group's first, so a slow pan
    /// doesn't chain a whole walk together).
    /// Only groups of two or more; the keeper is the best ranked photo (`rank`).
    static func groups(_ items: [CleanupGroupingItem], maxDistance: Float, maxGap: TimeInterval) -> [CleanupGroup] {
        let sorted = items.filter { !$0.feature.isEmpty }
            .sorted { ($0.date, $0.fileName, $0.id) < ($1.date, $1.fileName, $1.id) }
        var out: [CleanupGroup] = []
        var current: [CleanupGroupingItem] = []
        func flush() {
            if current.count >= 2, let best = current.max(by: { rank($0) < rank($1) }) {
                out.append(CleanupGroup(id: current.map(\.id).min()!, photoIDs: current.map(\.id), bestID: best.id))
            }
            current = []
        }
        for item in sorted {
            if let last = current.last, let first = current.first,
               case let gap = item.date.timeIntervalSince(last.date), gap <= maxGap,
               case let blur = blurAllowance(item, last, gap: gap),
               distance(last.feature, item.feature) <= maxDistance * allowance(gap: gap) * blur,
               distance(first.feature, item.feature) <= maxDistance * 1.25 * blur {
                current.append(item)
            } else {
                flush()
                current = [item]
            }
        }
        flush()
        return out
    }

    /// Keeper ranking: picked beats unflagged beats rejected, then kept by you, then stars, then how good it looks.
    static func rank(_ i: CleanupGroupingItem) -> Double {
        Double(i.flag.rawValue) * 100 + (i.kept ? 50 : 0) + Double(i.rating) * 10 + i.quality + i.sharpness * 1.5
    }
}
