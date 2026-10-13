//
//  CameraMakesSheet.swift
//  Kika
//
//  "Fill In Camera Makes…" (Settings > Raw Decode): Lightroom catalogs store only the camera model,
//  so Lightroom-imported photos show up as a second camera ("DC-S9" next to "Panasonic DC-S9").
//  Proposes a make per model — from other photos of that model, else read from one of its files —
//  and fills it in on confirmation (Catalog.fillCameraMake), merging the camera rows.
//

import SwiftUI

struct CameraMakesSheet: View {
    let catalog: Catalog
    let gaps: [Catalog.CameraMakeGap]
    let onDone: () -> Void

    struct Proposal: Identifiable {
        var id: String { gap.model }
        let gap: Catalog.CameraMakeGap
        /// Candidate makes (from other photos, or the file); empty = unknown.
        var makes: [String]
        var chosen: String
        var include: Bool
        var source: String
    }

    @State private var proposals: [Proposal] = []
    @State private var isReading = true
    @State private var isApplying = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Fill In Camera Makes").font(.title3.weight(.semibold))
            Text("Lightroom catalogs store only the camera model, so photos imported from Lightroom appear as a separate camera without a make. Filling in the make merges them with the same camera's other photos, for camera defaults and Match Camera JPEG.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if isReading && proposals.isEmpty {
                ProgressView("Looking up makes…").frame(maxWidth: .infinity)
            }
            ForEach($proposals) { $p in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Toggle("", isOn: $p.include).labelsHidden().disabled(p.makes.isEmpty)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(p.gap.model).fontWeight(.medium)
                            Text("\(p.gap.photoCount.formatted()) photo\(p.gap.photoCount == 1 ? "" : "s")").foregroundStyle(.secondary)
                            Image(systemName: "arrow.right").foregroundStyle(.secondary)
                            if p.makes.count > 1 {
                                Picker("", selection: $p.chosen) { ForEach(p.makes, id: \.self) { Text($0) } }
                                    .labelsHidden().fixedSize()
                            } else {
                                Text(p.makes.first ?? "unknown").foregroundStyle(p.makes.isEmpty ? .secondary : .primary)
                            }
                        }
                        Text(p.source).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Fill In") { apply() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isApplying || !proposals.contains { $0.include && !$0.chosen.isEmpty })
            }
        }
        .padding(20)
        .frame(width: 560)
        .task { await lookUp() }
    }

    private func lookUp() async {
        var out: [Proposal] = []
        for gap in gaps {
            if !gap.knownMakes.isEmpty {
                let makes = gap.knownMakes.map(\.make)
                let counts = gap.knownMakes.map { "\($0.make): \($0.count.formatted())" }.joined(separator: ", ")
                out.append(Proposal(gap: gap, makes: makes, chosen: makes[0], include: makes.count == 1,
                                    source: makes.count == 1
                                        ? "As on \(gap.knownMakes[0].count.formatted()) other photo\(gap.knownMakes[0].count == 1 ? "" : "s") of this model."
                                        : "Several makes use this model (\(counts)): check the right one before including it."))
            } else {
                let catalog = catalog, model = gap.model
                let read: (make: String?, file: String?) = await Task.detached(priority: .userInitiated) {
                    guard let photo = try? catalog.cameraMakeSample(model: model) else { return (nil, nil) }
                    let url = SecurityScopeManager.shared.accessibleURL(for: photo, catalog: catalog)
                    return (PhotoMetadataReader.read(url: url)?.cameraMake, photo.fileName)
                }.value
                if let make = read.make, !make.isEmpty {
                    out.append(Proposal(gap: gap, makes: [make], chosen: make, include: true,
                                        source: "Read from \(read.file ?? "one of its files")."))
                } else {
                    out.append(Proposal(gap: gap, makes: [], chosen: "", include: false,
                                        source: "Couldn't read a make from \(read.file ?? "its files") (offline or no access?)."))
                }
            }
            proposals = out
        }
        isReading = false
    }

    private func apply() {
        isApplying = true
        let chosen = proposals.filter { $0.include && !$0.chosen.isEmpty }.map { ($0.gap.model, $0.chosen) }
        let catalog = catalog
        Task {
            await Task.detached(priority: .userInitiated) {
                for (model, make) in chosen { _ = try? catalog.fillCameraMake(model: model, make: make) }
            }.value
            onDone()
            dismiss()
        }
    }
}
