//
//  DecodeProfilesSettingsView.swift
//  Kika
//
//  Settings > Raw Decode: the global default profile, a default per camera in the catalog, and the
//  profiles themselves (edit, duplicate, delete, import / export `.kikadecode` files).
//  Profile edits are saved as you go (debounced) and apply live to every photo that inherits them.
//

import SwiftUI
import UniformTypeIdentifiers
import AppKit

struct DecodeProfilesSettingsView: View {
    @Environment(AppModel.self) private var model
    private let store = DecodeProfilesStore.shared
    private let fitter = DecodeFitController.shared

    @State private var selection: Int64?
    @State private var draft: DecodeProfile?
    @State private var saveTask: Task<Void, Never>?
    @State private var cameras: [(camera: CameraKey, count: Int)] = []
    @State private var usage = 0
    @State private var pendingDelete: DecodeProfile?
    @State private var message: String?
    @State private var makeGaps: [Catalog.CameraMakeGap] = []

    static let fileType = UTType(filenameExtension: DecodeProfileFile.fileExtension, conformingTo: .json) ?? .json
    /// Older `.sloproomdecode` files (still importable).
    static let legacyFileTypes = DecodeProfileFile.legacyFileExtensions.compactMap { UTType(filenameExtension: $0, conformingTo: .json) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            defaultsSection
            Divider()
            HStack(alignment: .top, spacing: 14) {
                profileList.frame(width: 230)
                Divider()
                editor.frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .padding(20)
        .frame(minWidth: 760, minHeight: 600, alignment: .topLeading)
        .onAppear { reloadCameras(); select(selection ?? store.profiles.first?.id) }
        .onChange(of: store.revision) { reloadCameras(); refreshDraftFromStore() }
        .confirmationDialog("Delete “\(pendingDelete?.name ?? "")”?",
                            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })) {
            Button("Delete", role: .destructive) { if let p = pendingDelete { delete(p) } }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text(deleteMessage)
        }
        .alert("Raw Decode", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(message ?? "") }
    }

    // MARK: - Defaults

    private var defaultsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Defaults").font(.headline)
            Text("Photos without a profile of their own use the camera's default on top of the global one. Anything a profile leaves unset falls through to Apple's own default for that file.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                GridRow {
                    Text("All cameras").fontWeight(.medium)
                    profilePicker(selection: store.globalDefaultID, none: "Built-in") { id in
                        run { try model.catalog.setGlobalDecodeDefault(id) }
                    }
                    Text("")
                    Text("")
                }
                ForEach(cameras, id: \.camera) { entry in
                    GridRow {
                        Text(entry.camera.displayName)
                        profilePicker(selection: store.cameraDefaults[entry.camera], none: "Same as all cameras") { id in
                            run { try model.catalog.setCameraDecodeDefault(entry.camera, profileID: id) }
                        }
                        Text("\(entry.count) photo\(entry.count == 1 ? "" : "s")").font(.caption).foregroundStyle(.secondary)
                        Menu {
                            ForEach(DecodeFitController.sampleSizes, id: \.count) { size in
                                Button("Match on \(size.count) Photos (\(size.duration))") {
                                    fitter.start(camera: entry.camera, catalog: model.catalog, count: size.count)
                                }
                            }
                        } label: {
                            Text("Match Camera JPEG…")
                        } primaryAction: {
                            fitter.start(camera: entry.camera, catalog: model.catalog)
                        }
                        .menuStyle(.button)
                        .fixedSize()
                        .controlSize(.small)
                        .disabled(fitter.isRunning)
                        .help("Fit a profile so unedited photos match this camera's own JPEGs: base curve, black point, brightness, highlight shoulder. Click for \(DecodeFitController.defaultSampleSize) photos chosen for variety (date, ISO, light); the arrow offers more.")
                    }
                }
            }
            makesNotice
            fitStatus
        }
    }

    /// Lightroom-imported photos without a camera make show up as a separate camera.
    @ViewBuilder private var makesNotice: some View {
        if !makeGaps.isEmpty {
            let photos = makeGaps.map(\.photoCount).reduce(0, +)
            HStack(spacing: 8) {
                Image(systemName: "info.circle").foregroundStyle(.secondary)
                Text("\(photos.formatted()) photo\(photos == 1 ? "" : "s") (\(makeGaps.map(\.model).joined(separator: ", "))) have no camera make, probably from a Lightroom import, so they're listed as separate cameras.")
                    .fixedSize(horizontal: false, vertical: true)
                Button("Fill In Camera Makes…") { store.showsCameraMakesSheet = true }
            }
            .font(.callout)
            .controlSize(.small)
            .sheet(isPresented: Binding(get: { store.showsCameraMakesSheet }, set: { store.showsCameraMakesSheet = $0 })) {
                CameraMakesSheet(catalog: model.catalog, gaps: makeGaps) { reloadCameras() }
            }
        }
    }

    @ViewBuilder private var fitStatus: some View {
        if let camera = fitter.camera {
            HStack(spacing: 10) {
                switch fitter.state {
                case .idle:
                    EmptyView()
                case .preparing(let done, let total):
                    ProgressView(value: total > 0 ? Double(done) / Double(total) : 0).frame(width: 160)
                    Text("\(camera.displayName): choosing photos, \(done) of \(total) ready…")
                    Button("Cancel") { fitter.cancel() }
                case .fitting(let progress):
                    ProgressView(value: progress).frame(width: 160)
                    Text("\(camera.displayName): matching…")
                    Button("Cancel") { fitter.cancel() }
                case .finished(let id, let summary):
                    Image(systemName: "checkmark.circle").foregroundStyle(.green)
                    Text("Created “\(store.profile(id: id)?.name ?? "Profile")”: \(summary)")
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Use as Default for \(camera.displayName)") {
                        run { try model.catalog.setCameraDecodeDefault(camera, profileID: id) }
                        fitter.dismissResult()
                    }
                    Button("Show") { select(id) }
                    Button("Done") { fitter.dismissResult() }
                case .failed(let message):
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                    Text("\(camera.displayName): \(message)")
                    Button("Done") { fitter.dismissResult() }
                }
            }
            .font(.callout)
            .controlSize(.small)
        }
    }

    private func profilePicker(selection: Int64?, none: String, set: @escaping (Int64?) -> Void) -> some View {
        Picker("", selection: Binding(get: { selection }, set: set)) {
            Text(none).tag(Int64?.none)
            Divider()
            ForEach(store.profiles) { p in Text(p.name).tag(Optional(p.id)) }
        }
        .labelsHidden()
        .frame(width: 260)
    }

    // MARK: - Profiles

    private var profileList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Profiles").font(.headline)
            List(selection: Binding(get: { selection }, set: { select($0) })) {
                ForEach(store.profiles) { p in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(p.name)
                        Text(summary(p)).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .tag(Optional(p.id))
                }
            }
            .listStyle(.bordered)
            HStack(spacing: 4) {
                Button { newProfile() } label: { Image(systemName: "plus") }
                    .help("New empty profile (inherits everything)")
                Button { if let id = selection { run { select(try model.catalog.duplicateDecodeProfile(id: id)) } } } label: {
                    Image(systemName: "plus.square.on.square")
                }
                .help("Duplicate the selected profile").disabled(selection == nil)
                Button { pendingDelete = store.profile(id: selection) } label: { Image(systemName: "minus") }
                    .help("Delete the selected profile").disabled(selection == nil)
                Spacer()
                Menu {
                    Button("Import…") { importProfiles() }
                    Divider()
                    Button("Export Selected…") { if let p = store.profile(id: selection) { export([p]) } }
                        .disabled(selection == nil)
                    Button("Export All…") { export(store.profiles) }
                        .disabled(store.profiles.isEmpty)
                } label: { Image(systemName: "square.and.arrow.up.on.square") }
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Import or export .\(DecodeProfileFile.fileExtension) files")
            }
            .buttonStyle(.borderless)
        }
    }

    @ViewBuilder private var editor: some View {
        if let draft {
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    TextField("Name", text: Binding(get: { draft.name }, set: { change(\.name, $0) }))
                        .textFieldStyle(.roundedBorder).font(.title3)
                    TextField("Notes", text: Binding(get: { draft.notes }, set: { change(\.notes, $0) }), axis: .vertical)
                        .textFieldStyle(.roundedBorder).lineLimit(1...3)
                    HStack {
                        if let camera = draft.camera { Text("Made for \(camera.displayName)") }
                        Text(usage == 0 ? "No edited photos use it" : "Used by \(usage) edited photo\(usage == 1 ? "" : "s")")
                        Spacer()
                        Button("Clear All Settings") { change(\.params, DecodeParams()); saveNow() }
                            .disabled(draft.params.isEmpty)
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    ForEach(DecodeParamInfo.Group.allCases, id: \.self) { group in
                        DecodeParamGroup(group: group, layer: draft.params, inherited: inheritedForProfiles,
                                         inheritedSource: { _ in nil },
                                         layerName: "This profile",
                                         onChange: { change(\.params, $0) }, onCommit: { saveNow() })
                    }
                }
                .padding(.trailing, 12)
            }
        } else {
            Text("Select a profile").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// What an unset knob shows in the editor: Кика's built-in, Apple's typical defaults.
    private var inheritedForProfiles: DecodeParams {
        DecodeParamInfo.typicalAppleDefaults.overlaid(by: .builtin)
    }

    private func summary(_ p: DecodeProfile) -> String {
        let set = DecodeParamInfo.all.filter { $0.isSet(in: p.params) }.map(\.title)
        return set.isEmpty ? "Inherits everything" : set.joined(separator: ", ")
    }

    private var deleteMessage: String {
        guard let p = pendingDelete else { return "" }
        let n = (try? model.catalog.photosUsingDecodeProfile(p.id).count) ?? 0
        return n == 0 ? "No edited photos use it." : "\(n) edited photo\(n == 1 ? "" : "s") use it and will fall back to the defaults."
    }

    // MARK: - Editing

    private func select(_ id: Int64?) {
        saveNow()
        selection = id
        draft = store.profile(id: id)
        usage = id.flatMap { try? model.catalog.photosUsingDecodeProfile($0).count } ?? 0
    }

    private func refreshDraftFromStore() {
        guard saveTask == nil else { return } // our own pending edit wins
        draft = store.profile(id: selection)
        if draft == nil { selection = nil }
        usage = selection.flatMap { try? model.catalog.photosUsingDecodeProfile($0).count } ?? 0
    }

    private func change<V>(_ key: WritableKeyPath<DecodeProfile, V>, _ value: V) {
        guard var d = draft else { return }
        d[keyPath: key] = value
        draft = d
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            saveNow()
        }
    }

    private func saveNow() {
        saveTask?.cancel()
        saveTask = nil
        guard let d = draft, let stored = store.profile(id: d.id), stored != d else { return }
        var clean = d
        clean.name = d.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? stored.name : d.name
        run { try model.catalog.updateDecodeProfile(clean) }
    }

    private func newProfile() {
        run {
            let id = try model.catalog.createDecodeProfile(name: try model.catalog.uniqueDecodeProfileName("New Profile"), params: DecodeParams())
            select(id)
        }
    }

    private func delete(_ p: DecodeProfile) {
        pendingDelete = nil
        saveTask?.cancel(); saveTask = nil
        run { try model.catalog.deleteDecodeProfile(id: p.id) }
        select(store.profiles.first { $0.id != p.id }?.id)
    }

    private func reloadCameras() {
        cameras = (try? model.catalog.decodeCameras()) ?? []
        makeGaps = (try? model.catalog.cameraMakeGaps()) ?? []
    }

    private func run(_ body: () throws -> Void) {
        do { try body() } catch { message = error.localizedDescription }
    }

    // MARK: - Files

    private func export(_ profiles: [DecodeProfile]) {
        saveNow()
        let panel = NSSavePanel()
        panel.title = "Export Decode Profiles"
        panel.prompt = "Export"
        panel.nameFieldStringValue = (profiles.count == 1 ? profiles[0].name : "Кика Decode Profiles") + "." + DecodeProfileFile.fileExtension
        panel.allowedContentTypes = [Self.fileType]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        run { try DecodeProfileFile(profiles: profiles.compactMap { store.profile(id: $0.id) }).data().write(to: url, options: .atomic) }
    }

    private func importProfiles() {
        let panel = NSOpenPanel()
        panel.title = "Import Decode Profiles"
        panel.prompt = "Import"
        panel.allowedContentTypes = [Self.fileType] + Self.legacyFileTypes + [.json]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        run {
            var ids: [Int64] = []
            for url in panel.urls {
                ids += try model.catalog.importDecodeProfiles(try DecodeProfileFile.read(try Data(contentsOf: url)))
            }
            if let first = ids.first { select(first) }
            message = "Imported \(ids.count) profile\(ids.count == 1 ? "" : "s")."
        }
    }
}
