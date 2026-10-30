//
//  DeviceStore.swift
//  Kika
//
//  The devices holding catalogued photos (with counts), which are connected, and the folders with photos
//  on each device, for the Device filter (photo Filter menu, Folders filter menu) and the Move to Device
//  sheet. Reloads off-main when photos are added / removed / relocated (`.roots`) or folder membership
//  changes, and when a volume mounts or unmounts. `load(_:)` on catalog open / replace (AppModel).
//

import AppKit
import Foundation
import Observation

@Observable
final class DeviceStore {
    static let shared = DeviceStore()

    private(set) var devices: [DeviceSummary] = []
    /// Normalized mount points of the mounted volumes.
    private(set) var mounted: Set<String> = PhotoDevice.mountedVolumePaths()
    private(set) var foldersByDevice: [PhotoDevice: Set<Int64>] = [:]

    @ObservationIgnored private var catalog: Catalog?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var generation = 0

    private init() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            _ = center.addObserver(forName: name, object: nil, queue: .main) { _ in
                Task { @MainActor in DeviceStore.shared.mounted = PhotoDevice.mountedVolumePaths() }
            }
        }
    }

    func load(_ catalog: Catalog) {
        self.catalog = catalog
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = [NotificationCenter.default.addObserver(forName: Catalog.didChange, object: catalog, queue: .main) { note in
            guard let change = Catalog.change(from: note) else { return }
            switch change {
            case .photosInsertedOrRemoved, .roots, .folders, .folderMembership:
                Task { @MainActor in DeviceStore.shared.reload() }
            default:
                break
            }
        }]
        reload()
    }

    func isOnline(_ device: PhotoDevice) -> Bool { device.isOnline(mounted: mounted) }

    /// "T9 · 12,345 photos" / "T9 · offline".
    func menuTitle(_ summary: DeviceSummary) -> String {
        let count = summary.photoCount.formatted()
        return "\(summary.device.title) · \(count) photo\(summary.photoCount == 1 ? "" : "s")" + (isOnline(summary.device) ? "" : " · offline")
    }

    private func reload() {
        guard let catalog else { return }
        generation += 1
        let generation = generation
        Task {
            let loaded = await Task.detached(priority: .utility) { () -> ([DeviceSummary], [PhotoDevice: Set<Int64>])? in
                guard let devices = try? catalog.deviceSummaries(), let folders = try? catalog.folderIDsByDevice() else { return nil }
                return (devices, folders)
            }.value
            guard let loaded, generation == self.generation else { return }
            devices = loaded.0
            foldersByDevice = loaded.1
            mounted = PhotoDevice.mountedVolumePaths()
        }
    }
}
