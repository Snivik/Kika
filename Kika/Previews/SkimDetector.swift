//
//  SkimDetector.swift
//  Kika
//
//  Skimming = opening photos faster than `PreviewSettings.fullPreviewDelay` apart (arrowing
//  through Develop or Full Screen Preview). A photo opened while skimming waits that long before
//  its full decode / render starts; callers cancel the wait when the next photo opens, so photos
//  passed on the way cost only their cached preview and the one you stop on renders first.
//  Opening a photo after a pause (a double-click, the first arrow press) renders at once.
//

import Foundation

nonisolated final class SkimDetector: @unchecked Sendable {
    private let lock = NSLock()
    private var lastOpen = Date.distantPast

    /// Call when a photo opens: how long to wait before its full render (zero when not skimming).
    func delayForOpen(now: Date = Date()) -> Duration {
        let delay = PreviewService.shared.settings.fullPreviewDelay
        lock.lock()
        let skimming = now.timeIntervalSince(lastOpen) < delay
        lastOpen = now
        lock.unlock()
        return skimming ? .milliseconds(Int(delay * 1000)) : .zero
    }
}
