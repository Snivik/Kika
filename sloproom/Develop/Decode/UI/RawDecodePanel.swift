//
//  RawDecodePanel.swift
//  sloproom
//
//  Develop > Raw Decode (RAW only, collapsed by default): the photo's decode profile, its own
//  overrides of every decode knob (with where each inherited value comes from), the pinned
//  decoder version, and turning the current calibration into a profile / camera default.
//

import SwiftUI

struct RawDecodePanel: View {
    @Bindable var session: DevelopSession
    @Environment(\.openSettings) private var openSettings
    private let store = DecodeProfilesStore.shared

    @State private var newProfileName = ""
    @State private var isNamingProfile = false
    @State private var pendingUpdate: DecodeProfile?
    @State private var pendingUpdateUsage = 0
    @State private var errorMessage: String?

    var body: some View {
        if session.source.map({ !$0.isRAW }) ?? false {
            EmptyView()
        } else {
            InspectorSection("Raw Decode", expandedByDefault: false,
                             onReset: { session.settings.decode = keepingPin(DecodeSettings()) }) {
                content
            }
            .alert("Save as New Profile", isPresented: $isNamingProfile) {
                TextField("Name", text: $newProfileName)
                Button("Save") { saveAsNewProfile() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The profile gets this photo's decode settings; the photo then uses it.")
            }
            .confirmationDialog(updateTitle, isPresented: Binding(get: { pendingUpdate != nil }, set: { if !$0 { pendingUpdate = nil } })) {
                Button("Update Profile") { if let p = pendingUpdate { updateProfile(p) } }
                Button("Cancel", role: .cancel) { pendingUpdate = nil }
            } message: {
                Text(pendingUpdateUsage > 1
                     ? "\(pendingUpdateUsage) edited photos use it and will change too. Unedited photos of its cameras follow it as well."
                     : "Unedited photos that inherit it follow it as well.")
            }
            .alert("Raw Decode", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(errorMessage ?? "") }
        }
    }

    @ViewBuilder private var content: some View {
        let _ = store.revision
        let resolved = session.resolvedDecode
        let inherited = inheritedValues(resolved)
        let defaults = session.source?.appleDefaults

        Picker("Profile", selection: profileBinding) {
            Text(defaultsLabel(resolved)).tag(Int64?.none)
            if !store.profiles.isEmpty { Divider() }
            ForEach(store.profiles) { p in Text(p.name).tag(Optional(p.id)) }
        }
        .help("Decode profile for this photo. Defaults = the global and camera defaults (Settings > Raw Decode).")
        Text(chainText(resolved)).font(.caption2).foregroundStyle(.secondary).lineLimit(2)

        ForEach(DecodeParamInfo.Group.allCases, id: \.self) { group in
            DecodeParamGroup(group: group, layer: session.settings.decode.overrides, inherited: inherited,
                             inheritedSource: { source(of: $0, in: resolved) }, layerName: "This photo",
                             supported: { info in !info.isApple || defaults == nil || defaults!.supported.contains(info.id) },
                             onChange: { session.settings.decode.overrides = $0 },
                             onCommit: { session.commitUndoGroup() })
        }

        if let defaults, defaults.decoderVersions.count > 0 {
            Picker("Decoder", selection: decoderBinding(defaults)) {
                ForEach(defaults.decoderVersions.reversed(), id: \.self) { v in
                    Text(v == defaults.newestDecoder ? "\(v) (newest)" : v).tag(v)
                }
            }
            .help("Apple RAW decoder version. Pinned when the photo is first edited so a macOS update can't change it.")
            .padding(.top, 4)
        }

        HStack {
            Button("Save as Profile…") {
                newProfileName = (try? session.catalog.uniqueDecodeProfileName(session.source?.camera?.displayName ?? "My Profile")) ?? "My Profile"
                isNamingProfile = true
            }
            .help("Make a profile from this photo's decode settings (everything that differs from the built-in)")
            Menu("More") {
                if let target = updateTarget(resolved) {
                    Button("Update “\(target.name)” with This Photo's Overrides") { askUpdate(target) }
                        .disabled(session.settings.decode.overrides.isEmpty)
                }
                if let camera = session.source?.camera ?? session.photo.cameraKey {
                    Button("Use Profile as Default for \(camera.displayName)") { makeCameraDefault(camera) }
                        .disabled(session.settings.decode.profileID == nil)
                }
                Button("Clear This Photo's Overrides") { session.settings.decode.overrides = DecodeParams() }
                    .disabled(session.settings.decode.overrides.isEmpty)
                Divider()
                Button("Manage Profiles…") {
                    SettingsNavigation.shared.tab = .rawDecode
                    openSettings()
                }
            }
            .fixedSize()
        }
        .controlSize(.small)
        .padding(.top, 4)
    }

    // MARK: - Values

    /// Below the photo's overrides: built-in, profiles, then Apple's per-file defaults.
    private func inheritedValues(_ resolved: ResolvedDecode) -> DecodeParams {
        let apple = session.source?.appleDefaults?.values ?? DecodeParamInfo.typicalAppleDefaults
        return apple.overlaid(by: resolved.inheritedParams())
    }

    /// The profile layer the inherited value comes from (nil = Apple's / Sloproom's default).
    private func source(of info: DecodeParamInfo, in resolved: ResolvedDecode) -> String? {
        let below = resolved.layers.filter { $0.kind != .photo }
        guard let layer = below.last(where: { info.isSet(in: $0.params) }), layer.kind != .builtin else { return nil }
        return layer.label
    }

    private func defaultsLabel(_ resolved: ResolvedDecode) -> String {
        let names = resolved.layers.filter { $0.kind == .global || $0.kind == .camera }.map(\.name)
        return names.isEmpty ? "Defaults (built-in)" : "Defaults (\(names.joined(separator: " + ")))"
    }

    private func chainText(_ resolved: ResolvedDecode) -> String {
        resolved.layers.map(\.label).joined(separator: " → ")
    }

    /// The profile "Update" writes into: the chosen one, else the camera default, else the global default.
    private func updateTarget(_ resolved: ResolvedDecode) -> DecodeProfile? {
        resolved.layers.last { $0.profileID != nil }.flatMap { store.profile(id: $0.profileID) }
    }

    private var profileBinding: Binding<Int64?> {
        Binding(get: { session.settings.decode.profileID },
                set: { session.commitUndoGroup(); session.settings.decode.profileID = $0; session.commitUndoGroup() })
    }

    private func decoderBinding(_ defaults: AppleRawDefaults) -> Binding<String> {
        Binding(get: { session.settings.decode.decoderVersion ?? defaults.newestDecoder },
                set: { session.commitUndoGroup(); session.settings.decode.decoderVersion = $0; session.commitUndoGroup() })
    }

    private func keepingPin(_ d: DecodeSettings) -> DecodeSettings {
        var d = d
        d.decoderVersion = session.settings.decode.decoderVersion
        return d
    }

    // MARK: - Actions

    private var updateTitle: String { "Update “\(pendingUpdate?.name ?? "")”?" }

    private func askUpdate(_ profile: DecodeProfile) {
        pendingUpdateUsage = (try? session.catalog.photosUsingDecodeProfile(profile.id).count) ?? 0
        pendingUpdate = profile
    }

    private func saveAsNewProfile() {
        let resolved = session.resolvedDecode
        // Everything above the built-in, so the photo renders exactly the same through the new profile.
        let params = resolved.layers.filter { $0.kind != .builtin }.reduce(DecodeParams()) { $0.overlaid(by: $1.params) }
        do {
            let name = try session.catalog.uniqueDecodeProfileName(newProfileName)
            let id = try session.catalog.createDecodeProfile(name: name, params: params, camera: session.source?.camera)
            session.commitUndoGroup()
            var d = session.settings.decode
            d.profileID = id
            d.overrides = DecodeParams()
            session.settings.decode = d
            session.commitUndoGroup()
        } catch { errorMessage = "Couldn't save the profile: \(error.localizedDescription)" }
    }

    private func updateProfile(_ profile: DecodeProfile) {
        pendingUpdate = nil
        var p = profile
        p.params = p.params.overlaid(by: session.settings.decode.overrides)
        do {
            try session.catalog.updateDecodeProfile(p)
            session.commitUndoGroup()
            session.settings.decode.overrides = DecodeParams()
            session.commitUndoGroup()
        } catch { errorMessage = "Couldn't update the profile: \(error.localizedDescription)" }
    }

    private func makeCameraDefault(_ camera: CameraKey) {
        guard let id = session.settings.decode.profileID else { return }
        do { try session.catalog.setCameraDecodeDefault(camera, profileID: id) }
        catch { errorMessage = "Couldn't set the camera default: \(error.localizedDescription)" }
    }
}
