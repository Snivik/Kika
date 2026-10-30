//
//  DeviceMoveController.swift
//  Kika
//
//  State of the Move to Device sheet (MainActor): the photos (their distinct files, by device), the
//  destination folder (registered as a catalog root, so the moved photos keep their access; remembered),
//  the layout (remembered), Trash originals (asked every time, off by default), the running
//  `DeviceMoveJob` and its result. Open it with `DeviceMoveController.shared.present(ids:model:)`.
//

import AppKit
import Foundation
import Observation

@Observable
final class DeviceMoveController {
    static let shared = DeviceMoveController()

    enum Phase { case idle, moving, finished }

    private enum Keys {
        static let path = "deviceMove.destinationPath"
        static let layout = "deviceMove.layout"
    }

    /// Files to move from one device.
    struct SourceGroup: Identifiable, Hashable {
        var device: PhotoDevice
        var count: Int
        var bytes: Int64
        var isOnline: Bool
        var id: PhotoDevice { device }
    }

    // MARK: Sheet
    var isPresented = false
    private(set) var photoIDs: [Int64] = []
    private(set) var sources: [SourceGroup] = []

    // MARK: Options
    private(set) var destination: Root?
    /// Why the destination can't be used (not connected, no write access); nil = fine / unchecked.
    private(set) var destinationProblem: String?
    private(set) var isCheckingDestination = false
    var layout: DeviceMoveLayout = DeviceMoveLayout(rawValue: UserDefaults.standard.string(forKey: Keys.layout) ?? "") ?? .yearAndDay {
        didSet { UserDefaults.standard.set(layout.rawValue, forKey: Keys.layout) }
    }
    var trashOriginals = false

    // MARK: Job
    private(set) var phase: Phase = .idle
    private(set) var progress = DeviceMoveProgress()
    private(set) var result: DeviceMoveResult?

    private var model: AppModel?
    private var job: DeviceMoveJob?
    /// The running destination check (DevScript awaits it).
    private(set) var probeTask: Task<Void, Never>?

    var fileCount: Int { sources.reduce(0) { $0 + $1.count } }
    var onlineCount: Int { sources.filter(\.isOnline).reduce(0) { $0 + $1.count } }

    var title: String { fileCount == 1 ? "Move 1 Photo to Another Device" : "Move \(fileCount) Photos to Another Device" }

    var canMove: Bool {
        phase == .idle && onlineCount > 0 && destination != nil && destinationProblem == nil && !isCheckingDestination
    }

    var progressText: String {
        let size = { (b: Int64) in ByteCountFormatter.string(fromByteCount: b, countStyle: .file) }
        let current = min(progress.done + 1, max(progress.total, 1))
        return "Copying and checking \(current) of \(progress.total)… \(size(min(progress.bytesDone, progress.bytesTotal))) of \(size(progress.bytesTotal))"
    }

    // MARK: - Presenting

    /// Opens the sheet for `ids` (virtual copies stand for their master's file). Beeps when empty.
    func present(ids: [Int64], model: AppModel) {
        if phase == .moving { isPresented = true; return }
        guard !ids.isEmpty else { NSSound.beep(); return }
        self.model = model
        photoIDs = ids
        do {
            let masters = try DeviceMoveJob.masters(of: ids, catalog: model.catalog)
            let mounted = PhotoDevice.mountedVolumePaths()
            sources = Dictionary(grouping: masters) { PhotoDevice(path: $0.path) }
                .map { device, photos in
                    SourceGroup(device: device, count: photos.count, bytes: photos.reduce(0) { $0 + $1.fileSize },
                                isOnline: device.isOnline(mounted: mounted))
                }
                .sorted { $0.device < $1.device }
        } catch {
            model.report(error)
            return
        }
        phase = .idle
        result = nil
        trashOriginals = false   // asked every time
        progress = DeviceMoveProgress(total: fileCount)
        if destination == nil { restoreDestination() } else if let destination { probe(destination) }
        isPresented = true
    }

    func close() {
        guard phase != .moving else { return }
        isPresented = false
        if phase == .finished { phase = .idle; result = nil }
    }

    // MARK: - Destination

    func chooseDestination() {
        guard let model else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose the folder the photos move to (e.g. the photo folder on your drive or NAS)."
        panel.directoryURL = destination?.url
        guard panel.runModal() == .OK, let url = panel.url else { return }
        useDestination(url)
    }

    /// Uses `url` as destination (right after a panel granted it, or a folder the app can always write to).
    func useDestination(_ url: URL) {
        guard let model else { return }
        do {
            // A root keeps read/write access to the moved photos across launches.
            setDestination(try SecurityScopeManager.shared.registerRoot(url: url, in: model.catalog))
        } catch {
            destinationProblem = "Can't use \(url.path): \(error)"
        }
    }

    private func restoreDestination() {
        guard let model, let path = UserDefaults.standard.string(forKey: Keys.path),
              let root = try? model.catalog.allRoots().first(where: { $0.path == Catalog.normalizedPath(path) }) else { return }
        setDestination(root)
    }

    private func setDestination(_ root: Root) {
        destination = root
        UserDefaults.standard.set(root.path, forKey: Keys.path)
        probe(root)
    }

    /// Checks off-main that the destination is connected and writable (a sleeping drive can take a while).
    private func probe(_ root: Root) {
        guard let catalog = model?.catalog else { return }
        destinationProblem = nil
        isCheckingDestination = true
        probeTask = Task {
            let problem = await Task.detached(priority: .userInitiated) { () -> String? in
                SecurityScopeManager.shared.ensureAccess(forPath: root.path, rootID: root.id, catalog: catalog)
                guard FileManager.default.fileExists(atPath: root.path) else {
                    return "\(PhotoDevice(path: root.path).title) is not connected. Connect it or choose another folder."
                }
                do { try ImportFiles.checkWriteAccess(root.url); return nil } catch { return "\(error)" }
            }.value
            guard self.destination == root else { return }
            self.destinationProblem = problem
            self.isCheckingDestination = false
        }
    }

    // MARK: - Move

    func start() {
        guard canMove, let model, let destination else { return }
        let job = DeviceMoveJob(catalog: model.catalog, photoIDs: photoIDs,
                                options: DeviceMoveOptions(destination: destination.url, layout: layout, trashOriginals: trashOriginals))
        self.job = job
        phase = .moving
        result = nil
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                job.run { p in Task { @MainActor in DeviceMoveController.shared.update(p) } }
            }.value
            self.job = nil
            self.result = result
            self.phase = .finished
            if !result.updatedPhotoIDs.isEmpty {
                PreviewJobs.notifyChanged(result.updatedPhotoIDs)   // thumbnails that were offline retry at the new place
                model.reloadPhotos()
            }
            if let error = result.stopError { self.destinationProblem = error }   // destination gone / not writable
        }
    }

    private func update(_ p: DeviceMoveProgress) {
        guard phase == .moving, p.done >= progress.done else { return }
        progress = p
    }

    func cancel() { job?.cancel() }

    func showInFinder() {
        guard let result else { return }
        if result.targets.isEmpty, let destination { NSWorkspace.shared.activateFileViewerSelecting([destination.url]) }
        else { NSWorkspace.shared.activateFileViewerSelecting(Array(result.targets.prefix(200))) }
    }
}
