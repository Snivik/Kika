//
//  PhotoDateSections.swift
//  sloproom
//
//  Library grid grouping by date (Lightroom-style "All Photographs" by day): consecutive photos
//  of the same capture (or import) day form a section with a sticky header. Only when the list
//  is sorted by a date; `AppModel.groupByDate` (View > Group by Date, default on) switches it off.
//  Also the ↑ / ↓ navigation of a sectioned grid (rows restart at every section).
//

import Foundation

struct PhotoDateSection: Identifiable, Hashable {
    /// Start of the day (seconds), or "undated".
    var id: String
    var title: String
    /// Indices into `AppModel.photos`.
    var range: Range<Int>
}

enum PhotoDateSections {
    /// Day sections of `photos` (already sorted by `key`), nil if `key` isn't a date.
    static func make(_ photos: [Photo], key: PhotoSort.Key, calendar: Calendar = .current) -> [PhotoDateSection]? {
        guard key == .captureDate || key == .importDate else { return nil }
        let format = Date.FormatStyle(date: .complete, time: .omitted)
        var sections: [PhotoDateSection] = []
        var start = 0
        var currentDay: Date?? = nil   // .some(nil) = undated run
        func close(at end: Int) {
            guard let day = currentDay, end > start else { return }
            sections.append(PhotoDateSection(id: day.map { "\($0.timeIntervalSince1970)" } ?? "undated",
                                             title: day.map { $0.formatted(format) } ?? "Unknown Date", range: start..<end))
        }
        for (i, p) in photos.enumerated() {
            let date = key == .captureDate ? p.captureDate : p.importDate
            let day = date.map { calendar.startOfDay(for: $0) }
            if currentDay == nil || currentDay! != day {
                close(at: i)
                start = i
                currentDay = .some(day)
            }
        }
        close(at: photos.count)
        // A day split by an undated run (rare) gets a unique id.
        var seen: [String: Int] = [:]
        for i in sections.indices {
            let n = seen[sections[i].id, default: 0]
            seen[sections[i].id] = n + 1
            if n > 0 { sections[i].id += "#\(n)" }
        }
        return sections
    }

    /// Index reached from `index` by one row up (`down == false`) or down in a grid of `columns`
    /// whose rows restart at each section start (`starts`, ascending, first = 0). Keeps the column
    /// where possible; stays put at the top / bottom.
    static func verticalTarget(from index: Int, down: Bool, columns: Int, starts: [Int], count: Int) -> Int {
        guard count > 0, columns > 0 else { return index }
        let s = (starts.lastIndex { $0 <= index }) ?? 0
        let start = starts.isEmpty ? 0 : starts[s]
        let end = s + 1 < starts.count ? starts[s + 1] : count
        let local = index - start
        let row = local / columns, col = local % columns
        if down {
            if (row + 1) * columns < end - start { return start + min((row + 1) * columns + col, end - start - 1) }
            guard s + 1 < starts.count else { return index }
            let nextEnd = s + 2 < starts.count ? starts[s + 2] : count
            return end + min(col, nextEnd - end - 1)
        } else {
            if row > 0 { return start + (row - 1) * columns + col }
            guard s > 0 else { return index }
            let prevStart = starts[s - 1]
            let lastRow = (start - prevStart - 1) / columns
            return prevStart + min(lastRow * columns + col, start - prevStart - 1)
        }
    }
}
