//
//  SidebarDates.swift
//  sloproom
//
//  "Dates" in the Library sidebar: every capture year (click = the whole year) with its months, photo counts
//  from `SidebarCounts.months`, and "Unknown Date" for photos without a capture date. Independent of folders
//  (`PhotoSource.captureDate` / `.undated`). Years start collapsed; expansion is remembered.
//

import SwiftUI

struct SidebarDates: View {
    let counts: SidebarCounts
    @AppStorage("sidebar.expandedYears") private var expandedYears = ""   // "2026,2025"

    var body: some View {
        let years = Dictionary(grouping: counts.months, by: \.year).sorted { $0.key > $1.key }
        ForEach(years, id: \.key) { year, months in
            DisclosureGroup(isExpanded: expansion(year)) {
                ForEach(months, id: \.month) { m in
                    Label(Self.monthName(m.month), systemImage: "calendar")
                        .badge(m.count)
                        .tag(SidebarItem.date(year: year, month: m.month))
                }
            } label: {
                Label(String(year), systemImage: "calendar")
                    .badge(months.reduce(0) { $0 + $1.count })
                    .tag(SidebarItem.date(year: year, month: nil))
            }
        }
        if counts.undated > 0 {
            Label("Unknown Date", systemImage: "questionmark.circle")
                .badge(counts.undated)
                .help("Photos without a capture date")
                .tag(SidebarItem.undated)
        }
    }

    private func expansion(_ year: Int) -> Binding<Bool> {
        Binding {
            expandedYears.split(separator: ",").contains(Substring(String(year)))
        } set: { open in
            var set = Set(expandedYears.split(separator: ",").map(String.init))
            if open { set.insert(String(year)) } else { set.remove(String(year)) }
            expandedYears = set.sorted().joined(separator: ",")
        }
    }

    static func monthName(_ month: Int) -> String {
        Calendar.current.standaloneMonthSymbols[max(0, min(11, month - 1))]
    }

    /// "2026" or "October 2026" (window title).
    static func title(year: Int, month: Int?) -> String {
        guard let month else { return String(year) }
        return "\(monthName(month)) \(year)"
    }
}
