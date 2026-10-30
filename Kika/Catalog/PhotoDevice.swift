//
//  PhotoDevice.swift
//  Kika
//
//  Where a photo's file lives: this Mac's startup disk, or a mounted volume (`/Volumes/<name>`: an
//  external drive, a NAS share, a card). Derived from the photo's path, never stored, so it can't
//  disagree with where the catalog points (Move to Device and Relink rewrite paths). Engine: no UI.
//

import Foundation

nonisolated enum PhotoDevice: Hashable, Sendable, Comparable {
    /// The startup disk (any path not under /Volumes/).
    case thisMac
    /// A volume mounted at /Volumes/<name>.
    case volume(String)

    static let volumesPrefix = "/Volumes/"

    init(path: String) {
        let p = Catalog.normalizedPath(path)
        guard p.hasPrefix(Self.volumesPrefix) else { self = .thisMac; return }
        let name = p.dropFirst(Self.volumesPrefix.count).prefix { $0 != "/" }
        self = name.isEmpty ? .thisMac : .volume(String(name))
    }

    var title: String {
        switch self {
        case .thisMac: "This Mac"
        case .volume(let name): name
        }
    }

    var symbol: String {
        switch self {
        case .thisMac: "laptopcomputer"
        case .volume: "externaldrive"
        }
    }

    /// Mount point: "/" or "/Volumes/<name>".
    var mountPath: String {
        switch self {
        case .thisMac: "/"
        case .volume(let name): Self.volumesPrefix + name
        }
    }

    /// The startup disk is always online; a volume when it is mounted (`mounted` = normalized mount
    /// points, e.g. from `PhotoDevice.mountedVolumePaths()`).
    func isOnline(mounted: Set<String>) -> Bool {
        self == .thisMac || mounted.contains(mountPath)
    }

    static func mountedVolumePaths() -> Set<String> {
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: []) ?? []
        return Set(urls.map { Catalog.normalizedPath($0.path) })
    }

    /// SQL condition on a path column (e.g. "p.path"). Byte ranges instead of LIKE / substr: exact
    /// for any volume name (no wildcards, no character counting) and index friendly. "/" + 1 = "0".
    func sqlCondition(column: String) -> (sql: String, args: [any SQLBindable]) {
        switch self {
        case .thisMac:
            ("NOT (\(column) >= '/Volumes/' AND \(column) < '/Volumes0')", [])
        case .volume(let name):
            ("(\(column) >= ? AND \(column) < ?)", [Self.volumesPrefix + name + "/", Self.volumesPrefix + name + "0"])
        }
    }

    /// SQL expression for the volume name of a path column, NULL on this Mac (for GROUP BY).
    static func sqlVolumeName(column c: String) -> String {
        let rest = "substr(\(c), \(volumesPrefix.count + 1))"
        return """
            CASE WHEN \(c) >= '/Volumes/' AND \(c) < '/Volumes0' THEN
                CASE instr(\(rest), '/') WHEN 0 THEN \(rest) ELSE substr(\(rest), 1, instr(\(rest), '/') - 1) END
            END
            """
    }

    /// This Mac first, then volumes by name.
    static func < (a: Self, b: Self) -> Bool {
        switch (a, b) {
        case (.thisMac, .thisMac): false
        case (.thisMac, .volume): true
        case (.volume, .thisMac): false
        case (.volume(let x), .volume(let y)): x.localizedStandardCompare(y) == .orderedAscending
        }
    }
}

/// A device that holds catalogued photos.
nonisolated struct DeviceSummary: Hashable, Sendable, Identifiable {
    var device: PhotoDevice
    /// Catalogued files (masters; virtual copies share their master's file).
    var photoCount: Int
    var bytes: Int64
    var id: PhotoDevice { device }
}
