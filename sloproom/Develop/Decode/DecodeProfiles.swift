//
//  DecodeProfiles.swift
//  sloproom
//
//  Decode profiles (named DecodeParams stored in the catalog) and the registry that resolves a
//  photo's decode chain:
//
//    built-in ← global default ← camera default ← photo's profile ← photo's overrides
//
//  `DecodeProfileRegistry.shared` is an in-memory snapshot of the catalog's profiles and defaults,
//  so the render pipeline (any thread) can resolve without touching SQLite. The catalog API
//  (Catalog+DecodeProfiles) reloads it after every change; AppModel loads it when a catalog opens.
//

import Foundation

nonisolated struct DecodeProfile: Codable, Equatable, Sendable, Identifiable, Hashable {
    var id: Int64
    var name: String
    var params: DecodeParams
    /// Camera the profile was made for (informational; assignment is via camera defaults).
    var camera: CameraKey?
    var sortOrder: Int = 0
    var notes: String = ""
}

/// One layer of a resolved chain (for the UI: where a value comes from).
nonisolated struct DecodeLayer: Sendable, Equatable {
    nonisolated enum Kind: String, Sendable { case builtin, global, camera, profile, photo }
    var kind: Kind
    var profileID: Int64?
    var name: String
    var params: DecodeParams

    var label: String {
        switch kind {
        case .builtin: "Built-in"
        case .global: "Global: \(name)"
        case .camera: "Camera: \(name)"
        case .profile: "Profile: \(name)"
        case .photo: "This photo"
        }
    }
}

/// A photo's resolved decode parameters.
nonisolated struct ResolvedDecode: Sendable, Equatable {
    /// Bottom (built-in) to top (photo overrides).
    var layers: [DecodeLayer]
    /// Merged. Apple fields still nil = Apple's per-image default; Sloproom fields always set.
    var params: DecodeParams

    /// Topmost layer that sets `info`, nil = Apple's default.
    func source(of info: DecodeParamInfo) -> DecodeLayer? {
        layers.last { info.isSet(in: $0.params) }
    }

    /// The value below the photo's own overrides (what clearing an override goes back to).
    func inheritedParams() -> DecodeParams {
        layers.filter { $0.kind != .photo }.reduce(DecodeParams()) { $0.overlaid(by: $1.params) }
    }
}

nonisolated final class DecodeProfileRegistry: @unchecked Sendable {
    static let shared = DecodeProfileRegistry()

    private let lock = NSLock()
    private var profilesByID: [Int64: DecodeProfile] = [:]
    private var orderedIDs: [Int64] = []
    private var globalDefaultID: Int64?
    private var cameraDefaultIDs: [CameraKey: Int64] = [:]
    private var signatureValue = ""

    /// Replaces the snapshot (called by the catalog API).
    func replace(profiles: [DecodeProfile], globalDefault: Int64?, cameraDefaults: [CameraKey: Int64]) {
        let byID = Dictionary(profiles.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        // Everything that changes how a photo renders, as stable text (Recent renders hash it).
        var sig = "g\(globalDefault ?? 0)"
        for p in profiles.sorted(by: { $0.id < $1.id }) {
            sig += "|p\(p.id):\(Self.json(p.params))"
        }
        for (k, v) in cameraDefaults.sorted(by: { $0.key < $1.key }) {
            sig += "|c\(k.make)\u{1F}\(k.model)=\(v)"
        }
        lock.lock()
        profilesByID = byID
        orderedIDs = profiles.map(\.id)
        globalDefaultID = globalDefault.flatMap { byID[$0] != nil ? $0 : nil }
        cameraDefaultIDs = cameraDefaults.filter { byID[$0.value] != nil }
        signatureValue = sig
        lock.unlock()
    }

    var profiles: [DecodeProfile] {
        lock.lock(); defer { lock.unlock() }
        return orderedIDs.compactMap { profilesByID[$0] }
    }

    func profile(id: Int64) -> DecodeProfile? {
        lock.lock(); defer { lock.unlock() }
        return profilesByID[id]
    }

    var globalDefault: DecodeProfile? {
        lock.lock(); defer { lock.unlock() }
        return globalDefaultID.flatMap { profilesByID[$0] }
    }

    func cameraDefault(for camera: CameraKey?) -> DecodeProfile? {
        lock.lock(); defer { lock.unlock() }
        return cameraDefaultID(camera).flatMap { profilesByID[$0] }
    }

    /// Exact make + model; else, for a file with a make, a default set on the same model WITHOUT a make
    /// (Lightroom-imported photos before their makes are filled in); else, for a make-less photo, the
    /// only default of that model. Caller holds `lock`.
    private func cameraDefaultID(_ camera: CameraKey?) -> Int64? {
        guard let camera, !camera.isEmpty else { return nil }
        if let id = cameraDefaultIDs[camera] { return id }
        if !camera.make.isEmpty { return cameraDefaultIDs[camera.withoutMake] }
        let sameModel = cameraDefaultIDs.filter { $0.key.model.lowercased() == camera.model.lowercased() }
        return sameModel.count == 1 ? sameModel.first?.value : nil
    }

    var cameraDefaults: [CameraKey: Int64] {
        lock.lock(); defer { lock.unlock() }
        return cameraDefaultIDs
    }

    /// Changes whenever any profile or default changes (part of the Recent renders key).
    var signature: String {
        lock.lock(); defer { lock.unlock() }
        return signatureValue
    }

    /// The photo's chain and merged parameters.
    func resolve(_ decode: DecodeSettings, camera: CameraKey?) -> ResolvedDecode {
        lock.lock()
        let global = globalDefaultID.flatMap { profilesByID[$0] }
        let cam = cameraDefaultID(camera).flatMap { profilesByID[$0] }
        let chosen = decode.profileID.flatMap { profilesByID[$0] }
        lock.unlock()
        var layers = [DecodeLayer(kind: .builtin, profileID: nil, name: "Built-in", params: .builtin)]
        if let global { layers.append(DecodeLayer(kind: .global, profileID: global.id, name: global.name, params: global.params)) }
        if let cam { layers.append(DecodeLayer(kind: .camera, profileID: cam.id, name: cam.name, params: cam.params)) }
        if let chosen { layers.append(DecodeLayer(kind: .profile, profileID: chosen.id, name: chosen.name, params: chosen.params)) }
        if !decode.overrides.isEmpty {
            layers.append(DecodeLayer(kind: .photo, profileID: nil, name: "This photo", params: decode.overrides))
        }
        let merged = layers.reduce(DecodeParams()) { $0.overlaid(by: $1.params) }
        return ResolvedDecode(layers: layers, params: merged)
    }

    /// Profile ids a photo's chain goes through (to find the photos a profile change affects).
    func chainProfileIDs(_ decode: DecodeSettings, camera: CameraKey?) -> Set<Int64> {
        Set(resolve(decode, camera: camera).layers.compactMap(\.profileID))
    }

    static func json(_ p: DecodeParams) -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        return (try? enc.encode(p)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }
}

// MARK: - Export / import file

/// `*.sloproomdecode` file: one or more profiles as JSON.
nonisolated struct DecodeProfileFile: Codable, Sendable {
    static let format = "sloproom.decodeProfiles"
    static let currentVersion = 1
    static let fileExtension = "sloproomdecode"

    nonisolated struct Entry: Codable, Sendable, Equatable {
        var name: String
        var cameraMake: String?
        var cameraModel: String?
        var notes: String?
        var params: DecodeParams
    }

    var format = DecodeProfileFile.format
    var version = DecodeProfileFile.currentVersion
    var exportedAt: Date = Date()
    var profiles: [Entry]

    init(profiles: [DecodeProfile]) {
        self.profiles = profiles.map {
            Entry(name: $0.name, cameraMake: $0.camera?.make, cameraModel: $0.camera?.model,
                  notes: $0.notes.isEmpty ? nil : $0.notes, params: $0.params)
        }
    }

    func data() throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        return try enc.encode(self)
    }

    nonisolated enum ReadError: LocalizedError {
        case notAProfileFile, newerVersion(Int)
        var errorDescription: String? {
            switch self {
            case .notAProfileFile: "This file isn't a Sloproom decode profile."
            case .newerVersion(let v): "This profile file was made by a newer Sloproom (format \(v))."
            }
        }
    }

    static func read(_ data: Data) throws -> DecodeProfileFile {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        guard let file = try? dec.decode(DecodeProfileFile.self, from: data), file.format == format else {
            throw ReadError.notAProfileFile
        }
        guard file.version <= currentVersion else { throw ReadError.newerVersion(file.version) }
        return file
    }
}

nonisolated extension RenderSource {
    /// This photo's merged decode parameters (built-in ← global ← camera ← profile ← overrides).
    func resolvedDecode(_ settings: EditSettings) -> DecodeParams {
        DecodeProfileRegistry.shared.resolve(settings.decode, camera: camera).params
    }
}

nonisolated extension Photo {
    /// Camera identity for decode profile camera defaults (nil if the photo has no make / model).
    var cameraKey: CameraKey? {
        let key = CameraKey(make: cameraMake, model: cameraModel)
        return key.isEmpty ? nil : key
    }
}
