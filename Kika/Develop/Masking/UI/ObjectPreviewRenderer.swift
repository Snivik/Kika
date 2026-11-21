//
//  ObjectPreviewRenderer.swift
//  Kika
//
//  Pick Object's preview: every object Vision finds on the photo (AIMaskEngine.objects), each tinted its own
//  colour in DISPLAYED space, so the overlay can show what a click would pick and light up the one under the
//  pointer. Found off-main once per photo (Vision is fast); re-tinted when the crop or view size changes.
//  Latest request wins, like MaskCoverageRenderer.
//

import CoreGraphics
import CoreImage
import Foundation
import Observation

@Observable
final class ObjectPreviewRenderer {
    struct Request: Equatable {
        var source: RenderSource
        var geometry: Geometry
        var fullSize: CGSize
        var targetSize: CGSize

        static func == (a: Request, b: Request) -> Bool {
            ObjectIdentifier(a.source) == ObjectIdentifier(b.source) && a.geometry == b.geometry
                && a.fullSize == b.fullSize && a.targetSize == b.targetSize
        }
    }

    /// What was found (nil while looking).
    private(set) var objects: AIMaskEngine.Objects?
    /// `objects.masks[i]` tinted, displayed space.
    private(set) var images: [CGImage] = []
    @ObservationIgnored private var inFlight = false
    @ObservationIgnored private var pending: Request?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var last: Request?

    /// Distinct, light hues that read on most photos.
    nonisolated static let palette: [(CGFloat, CGFloat, CGFloat)] = [
        (0.30, 0.65, 1.00), (1.00, 0.75, 0.20), (0.40, 0.90, 0.45), (1.00, 0.40, 0.70),
        (0.65, 0.50, 1.00), (0.25, 0.90, 0.90), (1.00, 0.55, 0.35), (0.85, 0.95, 0.30),
    ]

    func request(_ r: Request) {
        guard r != last else { return }
        if inFlight { pending = r; return }
        inFlight = true
        last = r
        let gen = generation
        Task.detached(priority: .userInitiated) { [weak self] in
            let objects = AIMaskEngine.objects(source: r.source)
            let images = Self.tint(objects, r)
            await self?.finished(objects, images, generation: gen)
        }
    }

    func clear() {
        generation += 1
        pending = nil
        last = nil
        objects = nil
        images = []
    }

    private nonisolated static func tint(_ objects: AIMaskEngine.Objects?, _ r: Request) -> [CGImage] {
        // Half the view's pixels is plenty for a tint.
        let target = CGSize(width: r.targetSize.width / 2, height: r.targetSize.height / 2)
        guard let objects, let context = MaskRenderer.overlayContext(fullSize: r.fullSize, geometry: r.geometry,
                                                                   targetSize: target, source: r.source) else { return [] }
        let w = context.imageSize.width, h = context.imageSize.height
        return objects.masks.enumerated().compactMap { i, mask in
            let m = CIImage(cgImage: mask, options: [.colorSpace: NSNull()])
                .clampedToExtent()
                .transformed(by: CGAffineTransform(scaleX: w / CGFloat(mask.width), y: h / CGFloat(mask.height)))
                .cropped(to: CGRect(x: 0, y: 0, width: w, height: h))
            return MaskRenderer.displayedTint(m, geometry: r.geometry, context: context, color: palette[i % palette.count], opacity: 1)
        }
    }

    private func finished(_ objects: AIMaskEngine.Objects?, _ images: [CGImage], generation gen: Int) {
        inFlight = false
        if gen == generation {
            self.objects = objects
            self.images = images
        }
        if let next = pending {
            pending = nil
            request(next)
        }
    }
}
