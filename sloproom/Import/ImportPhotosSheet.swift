//
//  ImportPhotosSheet.swift
//  sloproom
//
//  File > Import Photos… (⇧⌘I). Lightroom-like: source (cards / folders) on the left, a checkable
//  thumbnail grid grouped by capture day in the middle (status icon per photo while duplicates are
//  matched), destination preview (existing / new folders, "+N") + options on the right, import
//  progress in the footer, a Rename / Replace / Skip prompt for conflicts, and a recap page
//  (`ImportRecapView`) when the import ends. State: ImportSession; engine: ImportEngine.
//

import AppKit
import Combine
import SwiftUI

struct ImportPhotosSheet: View {
    @Environment(AppModel.self) private var model
    @State private var session: ImportSession?

    var body: some View {
        Group {
            if let session {
                ImportPhotosContent(session: session)
            } else {
                Color.clear
            }
        }
        .frame(minWidth: 960, idealWidth: 1040, minHeight: 640, idealHeight: 720)
        .onAppear {
            if session == nil { session = ImportSession(catalog: model.catalog) }
        }
    }
}

private struct ImportPhotosContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Bindable var session: ImportSession

    var body: some View {
        VStack(spacing: 0) {
            if let summary = session.recap {
                ImportRecapView(summary: summary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                recapFooter(summary)
            } else {
                HStack(spacing: 0) {
                    ImportSourceColumn(session: session)
                        .frame(width: 210)
                    Divider()
                    ImportGridColumn(session: session)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    Divider()
                    ImportOptionsColumn(session: session)
                        .frame(width: 290)
                }
                Divider()
                footer
            }
        }
        .interactiveDismissDisabled(session.isImporting)
        .alert(conflictTitle, isPresented: Binding(
            get: { session.conflictPrompt != nil },
            set: { if !$0 { session.conflictPrompt = nil } }
        ), presenting: session.conflictPrompt) { _ in
            Button("Rename") { session.startImport(policy: .rename) }
                .help("Keep both: copy under a new name (e.g. L1000123-1) and add as a new photo")
            Button("Replace") { session.startImport(policy: .replace) }
                .help("Overwrite the existing file; the existing catalog photo keeps its edits, flags and folders")
            Button("Skip") { session.startImport(policy: .skip) }
                .help("Import everything else; leave these photos out")
            Button("Cancel", role: .cancel) {}
        } message: { prompt in
            Text(conflictMessage(prompt))
        }
        .onAppear {
            session.refreshVolumes()
            session.autoSelectCard()
            #if DEBUG
            ImportDevCommands.attach(session, start: { session.requestImport() }, done: {
                if let summary = session.recap { done(summary) }
            })
            #endif
        }
        .onDisappear { session.cancelScan() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didMountNotification)) { _ in
            session.refreshVolumes()
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didUnmountNotification)) { _ in
            session.refreshVolumes()
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 12) {
            if session.isImporting {
                let p = session.progress
                ProgressView(value: p.fraction)
                    .frame(width: 220)
                VStack(alignment: .leading, spacing: 1) {
                    Text(progressLine(p)).font(.callout).monospacedDigit()
                    if let f = p.currentFile { Text(f).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                }
                Spacer()
                Button("Stop Import") { session.cancelImport() }
                    .keyboardShortcut(.cancelAction)
                    .help("Stop after the current file (photos already copied stay imported)")
            } else if session.isPreparing {
                ProgressView().controlSize(.small)
                Text("Checking the destination for existing files…").font(.callout).foregroundStyle(.secondary)
                Spacer()
            } else {
                if let error = session.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.callout)
                        .lineLimit(3)
                        .textSelection(.enabled)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .help("Close without importing (Esc)")
                if session.isMatching, session.sourceURL != nil {
                    Text("Matching with the catalog…").font(.caption).foregroundStyle(.secondary)
                }
                Button(importTitle) { session.requestImport() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!session.canImport)
                    .help(session.isMatching ? "Available once every photo was compared with the catalog" : "Import the checked photos (Return)")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func recapFooter(_ summary: ImportRecap) -> some View {
        HStack(spacing: 12) {
            Spacer()
            Button("Import More") { session.returnFromRecap() }
                .help("Back to the import window (the source is scanned again)")
            Button(summary.succeeded ? "Show Imported Photos" : "Done") { done(summary) }
                .keyboardShortcut(.defaultAction)
                .help(summary.succeeded ? "Close and show the imported photos (Return)" : "Close (Return)")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var conflictTitle: String {
        guard let n = session.conflictPrompt?.count else { return "" }
        return n == 1 ? "1 photo was imported before" : "\(n) photos were imported before"
    }

    private func conflictMessage(_ p: ImportConflictPrompt) -> String {
        var parts: [String] = []
        if p.fileConflicts > 0 { parts.append("\(p.fileConflicts) already exist\(p.fileConflicts == 1 ? "s" : "") in the destination folder") }
        if p.catalogDuplicates > 0 { parts.append("\(p.catalogDuplicates) \(p.catalogDuplicates == 1 ? "is" : "are") already in the catalog") }
        let more = p.count > p.examples.count ? ", …" : ""
        return parts.joined(separator: " and ") + " (" + p.examples.joined(separator: ", ") + more + ").\n\n"
            + "Rename keeps both (new photos under new names). Replace overwrites the existing files and updates the photos already in the catalog (edits, flags and folders stay). Skip leaves them out."
    }

    private var importTitle: String {
        let n = session.included.count
        let verb = session.mode == .copy ? "Import" : "Add"
        return n > 0 ? "\(verb) \(n) Photo\(n == 1 ? "" : "s")" : verb
    }

    private func progressLine(_ p: ImportProgress) -> String {
        var s = "\(p.filesDone) of \(p.filesTotal) files"
        if p.bytesTotal > 0 { s += " · \(bytes(p.bytesDone)) of \(bytes(p.bytesTotal))" }
        if let eta = p.eta, p.bytesTotal > 0 { s += " · " + remaining(eta) }
        return s
    }

    private func remaining(_ t: TimeInterval) -> String {
        t < 60 ? "\(max(1, Int(t.rounded()))) s left" : "\(Int((t / 60).rounded(.up))) min left"
    }

    /// Recap closed: show what was imported (its folder, else Previous Import).
    private func done(_ summary: ImportRecap) {
        if summary.succeeded {
            if let folderID = summary.result.folderID {
                model.selectedSource = .folder(id: folderID, includeSubfolders: model.includeSubfolders)
            } else {
                model.selectSidebarItem(.lastImport)
            }
            model.mode = .library
            model.selection = []
        }
        dismiss()
    }
}

fileprivate func bytes(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }

// MARK: - Source column

private struct ImportSourceColumn: View {
    @Bindable var session: ImportSession

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ImportColumnHeader("From")
            ForEach(session.volumes) { v in
                SourceRow(icon: v.hasDCIM ? "sdcard" : "externaldrive", title: v.name,
                          subtitle: v.hasDCIM ? "Camera card" : "Removable volume",
                          isSelected: session.sourceID == v.id) { session.open(volume: v) }
            }
            if session.volumes.isEmpty {
                Text("No cards detected. Insert a card or choose a folder.")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 8).padding(.vertical, 4)
            }
            if let recent = session.recentFolder, !recent.key.hasPrefix("volume:") {
                SourceRow(icon: "folder", title: recent.name, subtitle: recent.path,
                          isSelected: session.sourceID == recent.key) { session.openRecentFolder() }
            }
            Button {
                session.chooseFolder()
            } label: {
                Label("Choose Folder…", systemImage: "folder.badge.plus")
            }
            .buttonStyle(.borderless)
            .help("Import from a folder instead of a card")
            .padding(.horizontal, 8)
            .padding(.top, 6)

            Spacer()

            ImportColumnHeader("Mode")
            Picker("Mode", selection: $session.mode) {
                ForEach(ImportMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                        .help(mode == .copy ? "Copy the files to the destination, then add the copies" : "Add the files where they are; nothing is copied")
                }
            }
            .pickerStyle(.radioGroup)
            .help("Copy to a destination or add the files in place")
            .labelsHidden()
            .padding(.horizontal, 8)
            Text(session.mode == .copy
                 ? "Copies the files, then adds the copies."
                 : "Adds the files where they are; nothing is copied.")
                .font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal, 8)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 8)
        .disabled(session.isImporting)
    }
}

private struct SourceRow: View {
    let icon: String
    let title: String
    let subtitle: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.title3)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).lineLimit(1)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 6).fill(isSelected ? Color.accentColor.opacity(0.2) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Import from \(title) (\(subtitle))")
    }
}

private struct ImportColumnHeader: View {
    let title: String
    init(_ title: String) { self.title = title }
    var body: some View {
        Text(title.uppercased())
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.top, 4)
    }
}

// MARK: - Grid column

private struct ImportGridColumn: View {
    @Bindable var session: ImportSession
    private let columns = [GridItem(.adaptive(minimum: 142, maximum: 180), spacing: 8)]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if session.sourceURL == nil {
                placeholder("sdcard", "Choose a card or folder to import from.")
            } else if session.candidates.isEmpty {
                if session.isScanning {
                    VStack(spacing: 8) {
                        ProgressView()
                        Text(session.scanStatus).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    placeholder("photo.on.rectangle.angled", "No photos found in “\(session.sourceTitle)”.")
                }
            } else {
                grid
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(session.sourceURL == nil ? "Import Photos" : session.sourceTitle)
                    .font(.headline)
                    .lineLimit(1)
                Text(summary).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            if session.isScanning, !session.candidates.isEmpty {
                ProgressView().controlSize(.small)
            }
            Spacer()
            Button("Check All") { session.checkAll() }
                .help("Import every photo (except locked duplicates)")
            Button("Uncheck All") { session.uncheckAll() }
                .help("Import none; then check the ones you want")
        }
        .controlSize(.small)
        .disabled(session.candidates.isEmpty || session.isImporting)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var summary: String {
        guard session.sourceURL != nil else { return "Insert a camera card or choose a folder." }
        let all = session.candidates
        let chosen = session.included
        let size = chosen.reduce(Int64(0)) { $0 + $1.totalSize }
        var s = "\(chosen.count) of \(all.count) photos selected · \(bytes(size))"
        let dups = all.filter { session.duplicates.contains($0.id) }.count
        if dups > 0 { s += " · \(dups) already in the catalog" }
        let onDisk = all.filter { !session.duplicates.contains($0.id) && session.isInDestination($0) }.count
        if onDisk > 0 { s += " · \(onDisk) already in the destination" }
        let videos = session.ignoredFiles.filter { ImportScanner.videoExtensions.contains($0.key) }.values.reduce(0, +)
        if videos > 0 { s += " · \(videos) video\(videos == 1 ? "" : "s") not imported" }
        if session.isScanning { s += " · " + session.scanStatus }
        return s
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 8, pinnedViews: [.sectionHeaders]) {
                ForEach(session.sections) { section in
                    Section {
                        ForEach(section.items) { c in
                            ImportCandidateCell(candidate: c,
                                                isIncluded: session.isIncluded(c),
                                                isDuplicate: session.duplicates.contains(c.id),
                                                isIdenticalInDestination: !session.duplicates.contains(c.id) && session.isInDestination(c),
                                                isLocked: session.isLocked(c),
                                                matchState: session.skipDuplicates ? session.matchState(c) : nil,
                                                existsInDestination: session.isIncluded(c) && session.existsInDestination(c))
                                .onTapGesture { session.toggle(c) }
                        }
                    } header: {
                        sectionHeader(section)
                    }
                }
            }
            .padding(12)
        }
        .disabled(session.isImporting)
    }

    private func sectionHeader(_ s: ImportSection) -> some View {
        let selectable = s.items.filter { !session.isLocked($0) }
        let checked = selectable.filter(session.isIncluded).count
        return HStack(spacing: 8) {
            Button { session.toggleSection(s) } label: {
                Image(systemName: checked == 0 ? "square" : checked == selectable.count ? "checkmark.square.fill" : "minus.square.fill")
                    .foregroundStyle(checked == 0 ? Color.secondary : Color.accentColor)
            }
            .buttonStyle(.plain)
            .disabled(selectable.isEmpty)
            .help(checked == selectable.count ? "Uncheck all photos of \(s.title)" : "Check all photos of \(s.title)")
            .accessibilityLabel("Check \(s.title)")
            Text(s.title).font(.subheadline.weight(.semibold))
            Text("\(s.items.count)").font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background(.bar)
    }

    private func placeholder(_ icon: String, _ text: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 40)).foregroundStyle(.tertiary)
            Text(text).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ImportCandidateCell: View {
    let candidate: ImportCandidate
    let isIncluded: Bool
    let isDuplicate: Bool
    /// Not in the catalog, but an identical file is already in its destination folder.
    let isIdenticalInDestination: Bool
    let isLocked: Bool
    /// Shown while "Don't import suspected duplicates" is on.
    let matchState: ImportMatchState?
    /// Checked, and a file with its name is already in the destination folder.
    let existsInDestination: Bool

    var body: some View {
        VStack(spacing: 4) {
            ImportThumbnailView(url: candidate.primary.url)
                .frame(height: 100)
                .overlay(alignment: .topLeading) {
                    Image(systemName: isIncluded ? "checkmark.square.fill" : "square")
                        .font(.title3)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(isIncluded ? Color.white : Color.secondary, isIncluded ? Color.accentColor : Color.clear)
                        .background(RoundedRectangle(cornerRadius: 4).fill(.background.opacity(isIncluded ? 0 : 0.7)))
                        .padding(2)
                }
                .overlay(alignment: .topTrailing) {
                    if let matchState { ImportMatchBadge(state: matchState).padding(3) }
                }
            Text(candidate.primary.fileName)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
            HStack(spacing: 4) {
                if candidate.sidecar != nil { badge("RAW+JPG", .secondary) }
                else if candidate.primary.isRAW { badge("RAW", .secondary) }
                if isDuplicate { badge("Imported", .orange) }
                if existsInDestination || isIdenticalInDestination { badge("In Destination", .orange) }
            }
            .frame(height: 14)
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 8).fill(isIncluded ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.04)))
        .opacity(isLocked ? 0.45 : 1)
        .contentShape(Rectangle())
        .help(isLocked && isIdenticalInDestination
              ? "An identical file is already in the destination folder: not copied again; it's added to the catalog as it is"
              : isLocked ? "Already in the catalog (turn off “Don't import suspected duplicates” to import again)"
              : existsInDestination ? "\(candidate.primary.fileName) already exists in its destination folder; you'll be asked to rename, replace or skip"
              : candidate.primary.url.path)
    }

    private func badge(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(color.opacity(0.6), lineWidth: 0.5))
    }
}

/// Duplicate-matching status of an import cell: comparing → already in the catalog (greyed
/// cell) / new. Monochrome white on a dark backing, like the library's flag badges.
private struct ImportMatchBadge: View {
    let state: ImportMatchState

    var body: some View {
        Group {
            switch state {
            case .processing:
                ProgressView().controlSize(.mini).tint(.white)
            case .matched:
                Image(systemName: "checkmark.circle.fill").font(.system(size: 13, weight: .semibold))
            case .unmatched:
                Image(systemName: "plus.circle.fill").font(.system(size: 13, weight: .semibold))
            }
        }
        .foregroundStyle(.white)
        .frame(width: 20, height: 20)
        .background(Circle().fill(.black.opacity(0.55)))
        .help(help)
        .accessibilityLabel(help)
    }

    private var help: String {
        switch state {
        case .processing: "Comparing with the catalog…"
        case .matched: "Already in the catalog: not imported"
        case .unmatched: "New: not in the catalog yet"
        }
    }
}

// MARK: - Destination preview

/// Lightroom-style merged view of the destination: the existing folders, the ones the import adds
/// photos to ("+N", files already there), the ones it creates (NEW), and name conflicts (they
/// trigger the Rename / Replace / Skip prompt). Untouched existing folders are dimmed; long runs
/// of them collapse into "N more folders".
private struct ImportDestinationTree: View {
    @Bindable var session: ImportSession
    @State private var expanded: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let plan = session.destinationPlan {
                let children = Dictionary(grouping: plan.folders.filter { $0.depth > 0 }) { $0.parentPath ?? "" }
                VStack(alignment: .leading, spacing: 0) {
                    if let root = plan.folders.first { rows(root, children: children) }
                }
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.04)))
                legend
                Text(summary(plan))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Reading the destination and comparing photos…").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .opacity(session.isPlanning && session.destinationPlan != nil ? 0.6 : 1)
    }

    /// A folder and (recursively) its children; untouched siblings collapse when there are many.
    private func rows(_ f: ImportDestinationFolder, children: [String: [ImportDestinationFolder]]) -> AnyView {
        let kids = children[f.path] ?? []
        let untouched = kids.filter { !touched($0) }
        let collapse = untouched.count > 4 && !expanded.contains(f.path)
        let shown = collapse ? kids.filter(touched) : kids
        return AnyView(VStack(alignment: .leading, spacing: 0) {
            row(f, isLeaf: kids.allSatisfy { !touched($0) })
            ForEach(shown) { rows($0, children: children) }
            if collapse {
                Button { expanded.insert(f.path) } label: {
                    Text("\(untouched.count) more existing folder\(untouched.count == 1 ? "" : "s")…")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .padding(.leading, CGFloat(f.depth + 1) * 14 + 21)
                .padding(.vertical, 2)
                .help("Show the folders of \(f.name) this import doesn't add to")
            } else if untouched.count > 4 {
                Button { expanded.remove(f.path) } label: {
                    Text("Hide untouched folders").font(.caption).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .padding(.leading, CGFloat(f.depth + 1) * 14 + 21)
                .padding(.vertical, 2)
                .help("Only show the folders this import adds to or creates")
            }
        })
    }

    private func touched(_ f: ImportDestinationFolder) -> Bool { f.adding > 0 || f.identical > 0 }

    private func row(_ f: ImportDestinationFolder, isLeaf: Bool) -> some View {
        let isNew = !f.exists
        let dim = !touched(f) && f.depth > 0
        return HStack(spacing: 5) {
            Image(systemName: f.depth == 0 ? "externaldrive" : isNew ? "folder.badge.plus" : touched(f) ? "folder.fill" : "folder")
                .foregroundStyle(isNew ? Color.accentColor : .secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 0) {
                Text(f.name)
                    .italic(isNew)
                    .fontWeight(isNew || (touched(f) && f.depth > 0) ? .semibold : .regular)
                    .foregroundStyle(isNew ? Color.accentColor : dim ? .secondary : .primary)
                    .lineLimit(1).truncationMode(.middle)
                if touched(f), isLeaf, let detail = detail(f) {
                    Text(detail).font(.system(size: 10)).foregroundStyle(f.conflicts > 0 ? Color.orange : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 4)
            if isNew, f.depth > 0 {
                Text("NEW").font(.system(size: 9, weight: .bold)).foregroundStyle(Color.accentColor)
            }
            if f.adding > 0 {
                Text("+\(f.adding)")
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(Color.accentColor.opacity(0.18)))
            }
        }
        .font(.caption)
        .opacity(dim ? 0.6 : 1)
        .padding(.leading, CGFloat(f.depth) * 14)
        .padding(.vertical, 2)
        .help(help(f))
    }

    private var legend: some View {
        HStack(spacing: 10) {
            Label("New", systemImage: "folder.badge.plus").foregroundStyle(Color.accentColor)
            Label("Adds to", systemImage: "folder.fill")
            Label("Unchanged", systemImage: "folder").foregroundStyle(.secondary)
        }
        .font(.system(size: 10))
        .labelStyle(.titleAndIcon)
    }

    private func detail(_ f: ImportDestinationFolder) -> String? {
        var parts: [String] = []
        if f.exists { parts.append(f.existingFiles == 0 ? "empty" : "\(f.existingFiles) file\(f.existingFiles == 1 ? "" : "s") there") }
        if f.identical > 0 { parts.append("\(f.identical) already copied") }
        if f.conflicts > 0 { parts.append("\(f.conflicts) name conflict\(f.conflicts == 1 ? "" : "s")") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func help(_ f: ImportDestinationFolder) -> String {
        let place = f.path.isEmpty ? session.destination?.path ?? f.name : f.path
        guard touched(f) || f.depth == 0 else { return "Existing folder: \(place)\nThis import doesn't add photos to it" }
        var s = (f.exists ? "Existing folder" : "New folder (created by the import)") + ": \(place)"
        s += "\n\(f.adding) photo\(f.adding == 1 ? "" : "s") will be added"
        if f.identical > 0 { s += "\n\(f.identical) already there (identical file): not copied again" }
        if f.conflicts > 0 { s += "\n\(f.conflicts) with a file name that already exists here (you'll be asked to rename, replace or skip)" }
        return s
    }

    private func summary(_ plan: ImportDestinationPlan) -> String {
        let leaves = plan.folders.filter { f in f.depth == session.pattern.depth && touched(f) }
        let created = plan.folders.filter { $0.depth > 0 && !$0.exists && touched($0) }.count
        let existing = leaves.filter { $0.exists && $0.adding > 0 }.count
        let identical = plan.folders.first?.identical ?? 0
        var parts: [String] = []
        if created > 0 { parts.append("creates \(created) new folder\(created == 1 ? "" : "s")") }
        if existing > 0 { parts.append("adds to \(existing) existing") }
        if identical > 0 { parts.append("\(identical) already copied") }
        if plan.conflictIDs.count > 0 { parts.append("\(plan.conflictIDs.count) name conflict\(plan.conflictIDs.count == 1 ? "" : "s")") }
        if parts.isEmpty { return session.included.isEmpty ? "No photos selected." : "Photos go straight into the destination folder." }
        return parts.joined(separator: " · ").capitalizedFirst + "."
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

// MARK: - Options column

private struct ImportOptionsColumn: View {
    @Environment(AppModel.self) private var model
    @Bindable var session: ImportSession

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if session.mode == .copy { destinationSection } else { inPlaceNote }
                Divider()
                folderSection
                Divider()
                ImportColumnHeader("Options")
                Toggle("Don't import suspected duplicates", isOn: $session.skipDuplicates)
                    .padding(.horizontal, 8)
                    .help("Photos already in the catalog (same file name, date and size) stay unchecked and locked")
                Toggle("Treat JPEG next to RAW as sidecar", isOn: $session.pairSidecars)
                    .padding(.horizontal, 8)
                    .help("RAW+JPEG pairs are copied together, but only the RAW is added to the catalog.")
            }
            .toggleStyle(.checkbox)
            .padding(.vertical, 12)
            .padding(.horizontal, 8)
        }
        .disabled(session.isImporting)
    }

    private var destinationSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            ImportColumnHeader("To")
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "externaldrive.fill").foregroundStyle(.secondary)
                if let d = session.destination {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(d.displayName ?? d.url.lastPathComponent).lineLimit(1)
                        Text(d.path).font(.caption).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
                    }
                } else {
                    Text("No destination").foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button(session.destination == nil ? "Choose…" : "Change…") { session.chooseDestination() }
                    .controlSize(.small)
                    .help("Choose the folder the photos are copied into")
            }
            .padding(.horizontal, 8)
            if let problem = session.destinationProblem {
                Text(problem)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 8)
            }
            Picker("Organize", selection: $session.pattern) {
                ForEach(DestinationPattern.allCases) { Text($0.title).tag($0) }
            }
            .help("Subfolders created in the destination, by capture date")
            .accessibilityLabel("Organize")
            .padding(.horizontal, 8)
            if session.destination != nil, session.destinationProblem == nil, !session.candidates.isEmpty {
                ImportDestinationTree(session: session)
                    .padding(.horizontal, 8)
            }
        }
    }

    private var inPlaceNote: some View {
        VStack(alignment: .leading, spacing: 6) {
            ImportColumnHeader("To")
            Text("Photos stay where they are. The source folder is remembered so Sloproom can read it later.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 8)
        }
    }

    private var folderSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            ImportColumnHeader("Add to Folder")
            Picker("Folder", selection: $session.targetFolderID) {
                Text("None").tag(Int64?.none)
                ForEach(flatFolders, id: \.folder.id) { item in
                    Text(String(repeating: "\u{2003}", count: item.depth) + item.folder.name).tag(Int64?.some(item.folder.id))
                }
            }
            .labelsHidden()
            .help("Catalog folder the imported photos are added to")
            .padding(.horizontal, 8)
            TextField("New folder (optional)", text: $session.newFolderName)
                .help("Create a new catalog folder (inside the folder above, if any) for the imported photos")
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 8)
            let name = session.newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty {
                let parent = session.targetFolderID.flatMap { id in model.folders.first { $0.id == id }?.name }
                Text(parent.map { "Creates “\(name)” inside “\($0)”." } ?? "Creates the top-level folder “\(name)”.")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
            }
        }
    }

    private var flatFolders: [(folder: Folder, depth: Int)] {
        var out: [(Folder, Int)] = []
        func walk(_ nodes: [FolderNode], _ depth: Int) {
            for n in nodes {
                out.append((n.folder, depth))
                walk(n.children, depth + 1)
            }
        }
        walk(model.folderTree, 0)
        return out
    }
}
