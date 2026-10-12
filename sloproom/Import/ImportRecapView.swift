//
//  ImportRecapView.swift
//  sloproom
//
//  The import recap: shown in the Import Photos sheet when an import ends (also when it stopped
//  early or imported nothing). What was imported / replaced / renamed and where, and everything
//  that was left out with the reason (already in the catalog, unchecked, conflicts, unreadable,
//  videos, failures). Buttons live in the sheet's footer (Import More / Show Imported Photos).
//

import SwiftUI

struct ImportRecapView: View {
    let summary: ImportRecap

    private var r: ImportResult { summary.result }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if let stop = r.stopError {
                    Label(stop.description, systemImage: "exclamationmark.octagon.fill")
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.red.opacity(0.08)))
                }
                if r.wasCancelled {
                    Label("The import was stopped. Photos copied before that are in the catalog.", systemImage: "stop.circle")
                        .foregroundStyle(.secondary)
                }
                section("Imported", rows: importedRows)
                if !destinationRows.isEmpty { section("Destination", rows: destinationRows) }
                section("Not Imported", rows: skippedRows, empty: "Nothing was left out.")
            }
            .padding(24)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon.name)
                .font(.system(size: 36))
                .foregroundStyle(icon.color)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.title2.weight(.semibold))
                Text(subtitle).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var icon: (name: String, color: Color) {
        if !summary.succeeded { return ("xmark.octagon.fill", .red) }
        if r.stopError != nil || !r.failures.isEmpty || r.wasCancelled { return ("exclamationmark.triangle.fill", .orange) }
        return ("checkmark.circle.fill", .green)
    }

    private var title: String {
        guard summary.succeeded else { return r.wasCancelled ? "Import stopped" : "Nothing was imported" }
        let n = r.photoIDs.count
        let verb = summary.mode == .copy ? "Imported" : "Added"
        return "\(verb) \(n) photo\(n == 1 ? "" : "s")" + (r.stopError != nil ? ", then stopped" : "")
    }

    private var subtitle: String {
        var s = "From \(summary.sourceTitle)"
        if let dest = summary.destinationPath { s += " to \(dest)" }
        if summary.mode == .addInPlace { s += " (added in place)" }
        var stats: [String] = []
        if r.filesCopied > 0 { stats.append("\(r.filesCopied) files, \(ByteCountFormatter.string(fromByteCount: r.bytesCopied, countStyle: .file))") }
        if r.elapsed >= 1 { stats.append(duration(r.elapsed)) }
        return stats.isEmpty ? s + "." : s + " · " + stats.joined(separator: " · ")
    }

    // MARK: Rows

    private struct Row: Identifiable {
        var icon: String
        var text: String
        var count: Int
        var details: [String] = []
        var color: Color = .primary
        var id: String { text }
    }

    private var importedRows: [Row] {
        var rows: [Row] = []
        if summary.added > 0 { rows.append(Row(icon: "plus.circle", text: "New photos in the catalog", count: summary.added)) }
        if !r.adoptedExisting.isEmpty {
            rows.append(Row(icon: "checkmark.circle", text: "Already in the destination: added to the catalog without copying",
                            count: r.adoptedExisting.count, details: r.adoptedExisting))
        }
        if summary.replaced > 0 {
            rows.append(Row(icon: "arrow.triangle.2.circlepath", text: "Replaced (existing photos updated, edits kept)", count: summary.replaced))
        }
        if !r.renamed.isEmpty {
            rows.append(Row(icon: "character.cursor.ibeam", text: "Renamed to keep both", count: r.renamed.count, details: r.renamed))
        }
        if let folder = summary.folderName, r.folderID != nil {
            rows.append(Row(icon: "folder", text: "Added to the folder “\(folder)”", count: r.photoIDs.count))
        }
        if rows.isEmpty { rows.append(Row(icon: "minus.circle", text: "No photos", count: 0, color: .secondary)) }
        return rows
    }

    private var destinationRows: [Row] {
        guard summary.mode == .copy else { return [] }
        let created = Set(r.createdFolders)
        return r.destinationFolders.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.map { path in
            let isNew = created.contains(path)
            return Row(icon: isNew ? "folder.badge.plus" : "folder",
                       text: (path.isEmpty ? "(destination folder)" : path) + (isNew ? "  (new)" : ""),
                       count: r.destinationFolders[path] ?? 0)
        }
    }

    private var skippedRows: [Row] {
        var rows: [Row] = []
        if !summary.skippedDuplicates.isEmpty {
            rows.append(Row(icon: "checkmark.circle", text: "Already in the catalog", count: summary.skippedDuplicates.count,
                            details: summary.skippedDuplicates))
        }
        if !r.skippedConflicts.isEmpty {
            rows.append(Row(icon: "arrow.uturn.right", text: "Skipped: imported before", count: r.skippedConflicts.count, details: r.skippedConflicts))
        }
        if summary.unchecked > 0 { rows.append(Row(icon: "square", text: "Unchecked", count: summary.unchecked)) }
        let notImported = summary.found - r.photoIDs.count - summary.skippedDuplicates.count - r.skippedConflicts.count
            - summary.unchecked - r.failures.count
        if r.wasCancelled || r.stopError != nil, notImported > 0 {
            rows.append(Row(icon: "stop.circle", text: "Not reached (import stopped)", count: notImported))
        }
        if !r.failures.isEmpty {
            rows.append(Row(icon: "exclamationmark.triangle", text: "Failed", count: r.failures.count, details: r.failures, color: .red))
        }
        if !summary.unreadable.isEmpty {
            rows.append(Row(icon: "questionmark.square.dashed", text: "Not readable as photos", count: summary.unreadable.count,
                            details: summary.unreadable))
        }
        let videos = summary.ignored.filter { ImportScanner.videoExtensions.contains($0.key) }
        if !videos.isEmpty {
            rows.append(Row(icon: "video", text: "Videos (not supported yet): " + list(videos), count: videos.values.reduce(0, +)))
        }
        let other = summary.ignored.filter { !ImportScanner.videoExtensions.contains($0.key) }
        if !other.isEmpty {
            rows.append(Row(icon: "doc", text: "Other files: " + list(other), count: other.values.reduce(0, +)))
        }
        return rows
    }

    private func list(_ counts: [String: Int]) -> String {
        counts.sorted { $0.value > $1.value }.map { "\($0.value) \($0.key)" }.joined(separator: ", ")
    }

    // MARK: Layout

    private func section(_ title: String, rows: [Row], empty: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 0) {
                if rows.isEmpty, let empty {
                    Text(empty).foregroundStyle(.secondary).padding(10)
                }
                ForEach(Array(rows.enumerated()), id: \.element.id) { i, row in
                    if i > 0 { Divider().padding(.leading, 36) }
                    rowView(row)
                }
            }
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
        }
    }

    @ViewBuilder
    private func rowView(_ row: Row) -> some View {
        if row.details.isEmpty {
            rowLabel(row).padding(.horizontal, 10).padding(.vertical, 7)
        } else {
            DisclosureGroup {
                Text(row.details.prefix(200).joined(separator: "\n") + (row.details.count > 200 ? "\n… and \(row.details.count - 200) more" : ""))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 26)
                    .padding(.vertical, 4)
            } label: {
                rowLabel(row)
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
        }
    }

    private func rowLabel(_ row: Row) -> some View {
        HStack(spacing: 10) {
            Image(systemName: row.icon).frame(width: 18).foregroundStyle(row.color == .primary ? .secondary : row.color)
            Text(row.text).foregroundStyle(row.color).lineLimit(2)
            Spacer(minLength: 8)
            Text("\(row.count)").monospacedDigit().foregroundStyle(.secondary)
        }
    }

    private func duration(_ t: TimeInterval) -> String {
        t < 60 ? "\(Int(t.rounded())) s" : "\(Int(t / 60)) min \(Int(t.truncatingRemainder(dividingBy: 60))) s"
    }
}
