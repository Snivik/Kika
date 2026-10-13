//
//  DecodeFitController.swift
//  Kika
//
//  Runs "Match Camera JPEG" (DecodeProfileFitter) for one camera at a time in the background and
//  saves the result as a NEW profile each run, "<camera> Camera Match (<n fitted> photos)", so runs with
//  different sample sizes can be compared. Observable state for Settings > Raw Decode.
//
//  Photos: the most varied `count` RAWs of the camera (`catalog.decodeFitPhotos`, by date / ISO /
//  scene brightness); nearly black or blown frames are replaced by the next candidates, and photos far
//  from their camera JPEG (picture styles, filters) are dropped before fitting.
//

import Foundation
import Observation

@Observable
final class DecodeFitController {
    static let shared = DecodeFitController()

    /// Sample sizes offered, with a rough duration (≈ 3 s per photo, M-series Mac).
    static let sampleSizes: [(count: Int, duration: String)] = [(16, "about 45 s"), (32, "about 1½ min"), (64, "about 3 min")]
    static let defaultSampleSize = 16

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

    func start(camera: CameraKey, catalog: Catalog, count: Int = DecodeFitController.defaultSampleSize) {
        guard !isRunning else { return }
        self.camera = camera
        cancelFlag = false
        state = .preparing(done: 0, total: count)
        Task.detached(priority: .userInitiated) { [weak self] in
            await self?.run(camera: camera, catalog: catalog, count: count)
        }
    }

    func cancel() { cancelFlag = true }

    func dismissResult() {
        if !isRunning { state = .idle; camera = nil }
    }

    nonisolated private func run(camera: CameraKey, catalog: Catalog, count: Int) async {
        do {
            let queue = try catalog.decodeFitPhotos(camera: camera, count: count)
            var samples: [DecodeProfileFitter.Sample] = []
            var skipped: [String: Int] = [:]
            for photo in queue where samples.count < count {
                if cancelFlag { throw DecodeProfileFitter.FitError.cancelled }
                let url = SecurityScopeManager.shared.accessibleURL(for: photo, catalog: catalog)
                switch DecodeProfileFitter.prepareChecked(url: url) {
                case .success(let s): samples.append(s)
                case .failure(let reason): skipped[reason.rawValue, default: 0] += 1
                }
                await setState(.preparing(done: samples.count, total: min(count, queue.count)))
            }
            let (kept, rejected) = DecodeProfileFitter.rejectOutliers(samples)
            if !rejected.isEmpty { skipped[DecodeProfileFitter.SkipReason.unlikeJPEG.rawValue] = rejected.count }
            var result = try DecodeProfileFitter.fit(samples: kept, progress: { p in
                Task { @MainActor [weak self] in
                    if self?.isRunning == true { self?.state = .fitting(progress: p) }
                }
            }, isCancelled: { [weak self] in self?.cancelFlag ?? true })
            result.skipped = skipped
            let notes = "Matched to the camera JPEGs of \(result.photoCount) photos on "
                + Date().formatted(date: .abbreviated, time: .omitted) + ". " + result.summary
            // A new profile every run, named by the photos actually fitted (the camera may have fewer
            // usable RAWs than asked for), so runs with different sample sizes can be compared.
            let name = try catalog.uniqueDecodeProfileName("\(camera.displayName) Camera Match (\(result.photoCount) photos)")
            let id = try catalog.createDecodeProfile(name: name, params: result.params, camera: camera, notes: notes,
                                                     origin: DecodeProfile.Origin.cameraMatch)
            await setState(.finished(profileID: id, summary: result.summary))
        } catch {
            await setState(.failed(error.localizedDescription))
        }
    }

    private func setState(_ s: State) { state = s }
}
