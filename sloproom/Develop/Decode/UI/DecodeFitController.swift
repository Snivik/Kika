//
//  DecodeFitController.swift
//  sloproom
//
//  Runs "Match Camera JPEG" (DecodeProfileFitter) for one camera at a time in the background and
//  saves the result as a new profile "<camera> Camera Match". Observable state for Settings > Raw Decode.
//

import Foundation
import Observation

@Observable
final class DecodeFitController {
    static let shared = DecodeFitController()
    /// Photos fitted per camera (spread over the catalog's capture dates).
    static let photoLimit = 16

    enum State: Equatable {
        case idle
        case preparing(done: Int, total: Int)
        case fitting(progress: Double)
        case finished(profileID: Int64, summary: String)
        case failed(String)
    }

    private(set) var camera: CameraKey?
    private(set) var state: State = .idle
    var isRunning: Bool {
        switch state { case .preparing, .fitting: true; default: false }
    }

    nonisolated(unsafe) private var cancelFlag = false

    func start(camera: CameraKey, catalog: Catalog) {
        guard !isRunning else { return }
        self.camera = camera
        cancelFlag = false
        state = .preparing(done: 0, total: 0)
        Task.detached(priority: .userInitiated) { [weak self] in
            await self?.run(camera: camera, catalog: catalog)
        }
    }

    func cancel() { cancelFlag = true }

    func dismissResult() {
        if !isRunning { state = .idle; camera = nil }
    }

    nonisolated private func run(camera: CameraKey, catalog: Catalog) async {
        do {
            let photos = try catalog.decodeFitPhotos(camera: camera, limit: Self.photoLimit)
            var samples: [DecodeProfileFitter.Sample] = []
            for (i, photo) in photos.enumerated() {
                if cancelFlag { throw DecodeProfileFitter.FitError.cancelled }
                let url = SecurityScopeManager.shared.accessibleURL(for: photo, catalog: catalog)
                if let s = DecodeProfileFitter.prepare(url: url) { samples.append(s) }
                await setState(.preparing(done: i + 1, total: photos.count))
            }
            let result = try DecodeProfileFitter.fit(samples: samples, progress: { p in
                Task { @MainActor [weak self] in
                    if self?.isRunning == true { self?.state = .fitting(progress: p) }
                }
            }, isCancelled: { [weak self] in self?.cancelFlag ?? true })
            let notes = "Matched to the camera JPEGs of \(result.photoCount) photos on "
                + Date().formatted(date: .abbreviated, time: .omitted) + ". " + result.summary
            let name = try catalog.uniqueDecodeProfileName("\(camera.displayName) Camera Match")
            let id = try catalog.createDecodeProfile(name: name, params: result.params, camera: camera, notes: notes)
            await setState(.finished(profileID: id, summary: result.summary))
        } catch {
            await setState(.failed(error.localizedDescription))
        }
    }

    private func setState(_ s: State) { state = s }
}
