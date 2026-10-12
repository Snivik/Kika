//
//  DecodeProfilesStore.swift
//  sloproom
//
//  Observable (main-actor) mirror of `DecodeProfileRegistry.shared` for SwiftUI: the profiles,
//  the global / camera defaults and a revision that bumps on every change. AppModel reloads it
//  when a catalog opens and on `.decodeProfiles`.
//

import Foundation
import Observation

@Observable
final class DecodeProfilesStore {
    static let shared = DecodeProfilesStore()

    private(set) var profiles: [DecodeProfile] = []
    private(set) var globalDefaultID: Int64?
    private(set) var cameraDefaults: [CameraKey: Int64] = [:]
    /// Bumps on every reload: views that resolve through the registry read it to refresh.
    private(set) var revision = 0
    /// Settings > Raw Decode's "Fill In Camera Makes" sheet (here so DevScript can open it).
    var showsCameraMakesSheet = false

    func reload() {
        let r = DecodeProfileRegistry.shared
        profiles = r.profiles
        globalDefaultID = r.globalDefault?.id
        cameraDefaults = r.cameraDefaults
        revision += 1
    }

    func profile(id: Int64?) -> DecodeProfile? {
        guard let id else { return nil }
        return profiles.first { $0.id == id }
    }
}
