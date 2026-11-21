//
//  FullScreenPreview.swift
//  Kika
//
//  F: the current photo alone on black, filling the screen (Library: focused / selected photo;
//  Develop: the photo being edited, with its live settings). A borderless window over the whole
//  screen of the main window (menu bar and Dock hidden while it is up), not the window's own
//  full-screen mode, so it opens instantly.
//
//    ← / →        previous / next photo of the current list (model.moveFocus)
//    Z / click    Fit ↔ 1:1 at the pointer (drag / scroll pans, pinch / ⌘-scroll zooms, ⌘= / ⌘-)
//    F / Esc      close
//
//  Quick Look (Space in Library, as in Finder): the same preview in a floating window centred on the
//  main window and sized to the photo, titled with its file name; the grid stays usable behind it.
//    ← → ↑ ↓      move through the grid (the grid's own handlers; ↑ / ↓ by row), ⇧ extends
//    Space / Esc  close        F  switch to full screen
//  It follows the grid's focused photo (clicks, arrows in the main window) and closes on leaving Library.
//  Animation (as in Finder): Quick Look zooms out of the photo's grid thumbnail (`GridCellFrames`) and back into it,
//  crossfades between photos and resizes to each photo's shape; the full-screen preview fades in and out. Closing
//  freezes the window on its last image and animates that, so the preview's state resets at once. Reduce motion:
//  fades only.
//
//  Rendering: the cached standard preview shows at once, then a render at screen resolution
//  (RenderPipeline, off-main); the neighbours in the direction of travel are pre-rendered.
//  While skimming (← / → faster than the full preview delay) the render waits for that delay
//  and is cancelled by the next photo.
//  Zoomed tiles come from its own ZoomController / RegionRenderer.
//

import AppKit
import CoreGraphics
import Foundation
import Observation
import SwiftUI

@Observable
final class FullScreenPreview {
    static let shared = FullScreenPreview()

    enum Style { case fullScreen, quickLook }

    private(set) var isShowing = false
    private(set) var style = Style.fullScreen
    /// Photo shown and the image for it (placeholder preview until the render arrives).
    private(set) var photoID: Int64?
    private(set) var image: CGImage?
    private(set) var isPlaceholder = true
    /// Displayed (cropped) size of the photo in full-resolution pixels.
    private(set) var displayedSize: CGSize = .zero
    /// Last screen render time (ms).
    private(set) var lastRenderMS: Double = 0
    let zoom = ZoomController()

    @ObservationIgnored private(set) var window: NSWindow?
    @ObservationIgnored private weak var model: AppModel?
    @ObservationIgnored private let shortcutToken = UUID()
    @ObservationIgnored private var savedPresentation: NSApplication.PresentationOptions = []
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var direction = 1
    /// Recent renders (photo id + edit key → image) incl. prefetched neighbours.
    @ObservationIgnored private var cache: [CacheKey: CGImage] = [:]
    @ObservationIgnored private var cacheOrder: [CacheKey] = []
    @ObservationIgnored private var sources: [Int64: RenderSource] = [:]
    @ObservationIgnored private var sourceOrder: [Int64] = []
    @ObservationIgnored private var currentSource: RenderSource?
    @ObservationIgnored private var currentSettings = EditSettings()
    /// Placeholder request + render of the photo shown; the next photo cancels them before they
    /// start, so skimming renders only where you stop (Previews/SkimDetector.swift).
    @ObservationIgnored private var placeholderTask: Task<Void, Never>?
    @ObservationIgnored private var renderTask: Task<Void, Never>?
    @ObservationIgnored private let skim = SkimDetector()

    private struct CacheKey: Hashable {
        let photoID: Int64
        let settings: String
        let size: CGSize
        func hash(into h: inout Hasher) { h.combine(photoID); h.combine(settings); h.combine(size.width); h.combine(size.height) }
    }

    // MARK: - Show / close

    func toggle(model: AppModel) {
        if isShowing { close() } else { show(model: model) }
    }

    /// Space: Quick Look on / off.
    func toggleQuickLook(model: AppModel) {
        if isShowing { close() } else { show(model: model, style: .quickLook) }
    }

    /// Whether `window` is the Quick Look window (key events from it drive the grid).
    func isQuickLook(_ window: NSWindow?) -> Bool { isShowing && style == .quickLook && window != nil && window === self.window }

    func show(model: AppModel, style: Style = .fullScreen) {
        if isShowing, self.style == .quickLook, style == .fullScreen { close(animated: false) }   // F from Quick Look
        guard !isShowing else { return }
        let id = model.focusedPhotoID ?? model.photos.first(where: { model.selection.contains($0.id) })?.id
        guard let id, let photo = model.photo(id: id) else { NSSound.beep(); return }
        if model.focusedPhotoID != id { model.focusedPhotoID = id }
        self.model = model
        self.style = style
        let main = NSApp.windows.first { $0.isVisible && !($0 is NSPanel) && $0 !== window }
        guard let screen = main?.screen ?? NSScreen.main else { return }
        if style == .quickLook {
            showQuickLook(photo: photo, over: main, screen: screen, model: model)
            return
        }

        let w = FullScreenWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        w.backgroundColor = .black
        w.isOpaque = true
        w.hasShadow = false
        w.isReleasedWhenClosed = false
        w.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        w.animationBehavior = .none
        w.title = "Full Screen Preview"
        w.contentView = NSHostingView(rootView: FullScreenPreviewView(preview: self).environment(model))
        w.setFrame(screen.frame, display: false)
        window = w
        zoom.window = w
        zoom.setLevel(.fit, anchor: nil, showHUD: false)
        isShowing = true

        // Hide the menu bar and Dock (not needed when the main window is in its own full screen).
        savedPresentation = NSApp.presentationOptions
        if !(main?.styleMask.contains(.fullScreen) ?? false) {
            NSApp.presentationOptions = savedPresentation.union([.hideDock, .hideMenuBar])
        }
        w.alphaValue = 0
        w.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            w.animator().alphaValue = 1
        }
        installKeys()
        load(photoID: id)
    }

    /// A floating, resizable window centred on the main window, the photo's shape, up to 85 % of the main window.
    private func showQuickLook(photo: Photo, over main: NSWindow?, screen: NSScreen, model: AppModel) {
        let area = (main?.frame ?? screen.visibleFrame).intersection(screen.visibleFrame)
        quickLookArea = area
        let content = quickLookContentSize(for: photo, in: area)

        let w = QuickLookWindow(contentRect: CGRect(origin: .zero, size: content), styleMask: [.titled, .closable, .resizable, .miniaturizable],
                                backing: .buffered, defer: false)
        w.backgroundColor = .black
        w.appearance = NSAppearance(named: .darkAqua)
        w.isReleasedWhenClosed = false
        w.level = .floating
        w.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        w.title = photo.displayTitle
        w.onClose = { [weak self] in self?.close(animated: false) }
        let host = NSHostingView(rootView: QuickLookView(preview: self).environment(model))
        host.sizingOptions = []   // the window sets the size (it starts thumbnail-small)
        w.contentView = host
        w.contentMinSize = CGSize(width: 320, height: 240)
        w.setContentSize(content)
        let final = CGRect(origin: CGPoint(x: (area.midX - w.frame.width / 2).rounded(), y: (area.midY - w.frame.height / 2).rounded()),
                           size: w.frame.size)
        window = w
        isShowing = true
        // Zoom out of the thumbnail (or grow a little, when it isn't on screen).
        let start: CGRect
        if reduceMotion { start = final }
        else if let thumb = thumbnailRect(photo) { start = w.frameRect(forContentRect: thumb) }
        else { start = final.insetBy(dx: final.width * 0.04, dy: final.height * 0.04) }
        w.setFrame(start, display: false)
        w.alphaValue = 0
        w.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = reduceMotion ? 0.15 : 0.24
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            w.animator().setFrame(final, display: true)
            w.animator().alphaValue = 1
        }
        installKeys()
        load(photoID: photo.id)
    }

    // MARK: - Animation

    /// The main window's part of the screen when Quick Look opened (its windows are sized within it).
    @ObservationIgnored private var quickLookArea: CGRect = .zero

    /// System Settings › Accessibility › Display › Reduce motion: fade, don't zoom or resize.
    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// Quick Look's content size for a photo: its shape, up to 85 % of `area` (at least 320 × 240).
    private func quickLookContentSize(for photo: Photo, in area: CGRect) -> CGSize {
        let shape = GeometryMath(sourceSize: photo.orientedSize, geometry: photo.editSettings.geometry).croppedSize
        let bound = CGSize(width: max(480, area.width * 0.85), height: max(360, area.height * 0.85 - 28))
        let k = shape.width > 0 && shape.height > 0 ? min(bound.width / shape.width, bound.height / shape.height) : 1
        return CGSize(width: max(320, (shape.width * k).rounded()), height: max(240, (shape.height * k).rounded()))
    }

    /// The photo's thumbnail in the grid, screen coordinates: its shape fitted into the cell's image square.
    /// nil when the cell isn't (mostly) visible in the main window.
    private func thumbnailRect(_ photo: Photo) -> CGRect? {
        guard let main = ShortcutDispatcher.shared.mainWindow, let content = main.contentView,
              let cell = GridCellFrames.frames[photo.id] else { return nil }
        // SwiftUI's global space is the content view, top-left origin.
        let square = CGRect(x: cell.minX, y: content.bounds.height - cell.minY - cell.width, width: cell.width, height: cell.width)
        guard square.intersection(main.contentLayoutRect).width > square.width * 0.5 else { return nil }
        let shape = GeometryMath(sourceSize: photo.orientedSize, geometry: photo.editSettings.geometry).croppedSize
        let inner = square.insetBy(dx: 6, dy: 6)
        guard shape.width > 0, shape.height > 0 else { return nil }
        let k = min(inner.width / shape.width, inner.height / shape.height)
        let fitted = CGRect(x: inner.midX - shape.width * k / 2, y: inner.midY - shape.height * k / 2,
                            width: shape.width * k, height: shape.height * k)
        return main.convertToScreen(fitted)
    }

    /// Quick Look follows a new photo: refit the window to its shape around the same centre.
    private func refitQuickLook(to photo: Photo) {
        guard style == .quickLook, let w = window, w.isVisible else { return }
        let content = quickLookContentSize(for: photo, in: quickLookArea)
        let size = w.frameRect(forContentRect: CGRect(origin: .zero, size: content)).size
        guard abs(size.width - w.frame.width) > 1 || abs(size.height - w.frame.height) > 1 else { return }
        var frame = CGRect(x: (w.frame.midX - size.width / 2).rounded(), y: (w.frame.midY - size.height / 2).rounded(),
                           width: size.width, height: size.height)
        if let visible = w.screen?.visibleFrame {   // keep it on screen
            frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
            frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)
        }
        if reduceMotion { w.setFrame(frame, display: true); return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            w.animator().setFrame(frame, display: true)
        }
    }

    /// Shows the window's last image without the live view, then zooms it into `target` (screen, content rect) or
    /// just fades it, and orders it out.
    private func animateOut(_ w: NSWindow, to target: CGRect?) {
        let frozen = NSImageView()
        frozen.image = image.map { NSImage(cgImage: $0, size: .zero) }
        frozen.imageScaling = .scaleProportionallyUpOrDown
        frozen.wantsLayer = true
        frozen.layer?.backgroundColor = NSColor.black.cgColor
        w.contentView = frozen
        w.ignoresMouseEvents = true
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = target == nil ? 0.15 : 0.22
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            if let target { w.animator().setFrame(w.frameRect(forContentRect: target), display: true) }
            w.animator().alphaValue = 0
        }, completionHandler: {
            w.orderOut(nil)
            w.contentView = nil
        })
    }

    /// `animated` false: gone at once (Quick Look → full screen, the window's close button).
    func close(animated: Bool = true) {
        guard isShowing else { return }
        isShowing = false
        ShortcutDispatcher.shared.unregister(shortcutToken)
        if style == .fullScreen { NSApp.presentationOptions = savedPresentation }
        (window as? QuickLookWindow)?.onClose = nil
        if let w = window, w.isVisible, animated {
            let target = style == .quickLook && !reduceMotion ? (photoID.flatMap { model?.photo(id: $0) }).flatMap(thumbnailRect) : nil
            animateOut(w, to: target)
        } else {
            window?.orderOut(nil)
            window?.contentView = nil
        }
        window = nil
        zoom.purge()
        zoom.window = nil
        generation += 1
        placeholderTask?.cancel()
        renderTask?.cancel()
        cache.removeAll(); cacheOrder.removeAll()
        sources.removeAll(); sourceOrder.removeAll()
        currentSource = nil
        image = nil
        photoID = nil
        NSApp.windows.first { $0.isVisible && !($0 is NSPanel) }?.makeKeyAndOrderFront(nil)
    }

    /// Keys of the full-screen window (registry actions; defaults ← / → / F / Esc); Quick Look: Space / Esc / F.
    private func installKeys() {
        let mine: @MainActor (NSEvent) -> Bool = { [weak self] event in
            guard let self, self.isShowing, let w = self.window else { return false }
            return event.window === w
        }
        if style == .quickLook {
            ShortcutDispatcher.shared.register(shortcutToken, [
                ShortcutHandler(.exitFullScreen, when: mine) { [weak self] _ in self?.close() },
                ShortcutHandler(.quickLook, when: mine) { [weak self] _ in self?.close() },
                ShortcutHandler(.fullScreenPreview, when: mine) { [weak self] _ in
                    guard let self, let model = self.model else { return }
                    self.show(model: model, style: .fullScreen)
                },
            ])
            return
        }
        ShortcutDispatcher.shared.register(shortcutToken, [
            ShortcutHandler(.exitFullScreen, when: mine) { [weak self] _ in self?.close() },
            ShortcutHandler(.fullScreenPreview, when: mine) { [weak self] _ in self?.close() },
            ShortcutHandler(.previousPhoto, when: mine) { [weak self] _ in self?.move(by: -1) },
            ShortcutHandler(.nextPhoto, when: mine) { [weak self] _ in self?.move(by: 1) },
        ])
    }

    func move(by delta: Int) {
        guard let model else { return }
        direction = delta >= 0 ? 1 : -1
        model.moveFocus(by: delta)
        if let id = model.focusedPhotoID, id != photoID { load(photoID: id) }
    }

    /// Called when the model's focused photo changes while showing (filmstrip click, arrows).
    func focusChanged(to id: Int64?) {
        guard isShowing, let id, id != photoID else { return }
        load(photoID: id)
    }

    /// The develop session's settings changed (live edits of the shown photo).
    func refreshIfEdited() {
        guard isShowing, let photoID, let photo = model?.photo(id: photoID) else { return }
        let (settings, source) = editState(for: photo)
        if settings != currentSettings { load(photoID: photoID, keepImage: true) }
        else if currentSource == nil, let source { currentSource = source; updateZoomInputs() }
    }

    // MARK: - Rendering

    private var screenPixelSize: CGSize {
        guard let window, let screen = window.screen ?? NSScreen.main else { return CGSize(width: 2560, height: 1600) }
        let s = screen.backingScaleFactor
        return CGSize(width: (screen.frame.width * s).rounded(), height: (screen.frame.height * s).rounded())
    }

    /// Settings + source for a photo: the develop session's live state when it shows that photo.
    private func editState(for photo: Photo) -> (EditSettings, RenderSource?) {
        if let s = model?.developSession, s.photo.id == photo.id { return (s.zoomDisplaySettings, s.source) }
        return (photo.editSettings, sources[photo.id])
    }

    private func load(photoID id: Int64, keepImage: Bool = false) {
        guard let model, let photo = model.photo(id: id) else { return }
        generation += 1
        let gen = generation
        let (settings, knownSource) = editState(for: photo)
        let size = screenPixelSize
        let key = CacheKey(photoID: id, settings: settings.jsonString() ?? "", size: size)
        let isNewPhoto = photoID != id
        let isNextPhoto = isNewPhoto && photoID != nil   // not the first one (Quick Look is still zooming open)
        if isNewPhoto { zoom.setInputs(nil) }
        placeholderTask?.cancel()
        renderTask?.cancel()
        photoID = id
        currentSettings = settings
        currentSource = knownSource
        if style == .quickLook {
            window?.title = photo.displayTitle
            if isNextPhoto { refitQuickLook(to: photo) }
        }
        displayedSize = GeometryMath(sourceSize: knownSource?.orientedSize ?? photo.orientedSize, geometry: settings.geometry).croppedSize
        if let hit = cache[key] {
            image = hit
            isPlaceholder = false
        } else if !keepImage || image == nil {
            image = PreviewService.shared.cachedImage(for: photo, level: .standard)
                ?? PreviewService.shared.cachedImage(for: photo, level: .thumbnail)
            isPlaceholder = true
            if image == nil {
                placeholderTask = Task { [weak self] in
                    let preview = await PreviewService.shared.image(for: photo, level: .standard)
                    guard let self, self.generation == gen, self.image == nil else { return }
                    self.image = preview
                }
            }
        }
        updateZoomInputs()
        let catalog = model.catalog
        let needsRender = cache[key] == nil
        // Live edits of the shown photo render at once; a new photo waits while skimming.
        let delay = isNewPhoto && needsRender ? skim.delayForOpen() : .zero
        renderTask = Task.detached(priority: .userInitiated) { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            if Task.isCancelled { return }
            let source = knownSource ?? RenderPipeline.makeSource(url: SecurityScopeManager.shared.accessibleURL(for: photo, catalog: catalog))
            var cg: CGImage?
            var ms = 0.0
            if needsRender, let source {
                let t = Date()
                cg = RenderPipeline.renderCGImage(source: source, settings: settings, targetSize: size)
                ms = Date().timeIntervalSince(t) * 1000
            }
            await self?.rendered(cg, source: source, key: key, gen: gen, ms: ms)
        }
    }

    private func rendered(_ cg: CGImage?, source: RenderSource?, key: CacheKey, gen: Int, ms: Double) {
        guard isShowing else { return }
        if let source { remember(source, for: key.photoID) }
        if let cg { store(cg, key) }
        guard gen == generation, key.photoID == photoID else { return }
        if let source {
            currentSource = source
            displayedSize = GeometryMath(sourceSize: source.orientedSize, geometry: currentSettings.geometry).croppedSize
        }
        if let cg {
            image = cg
            isPlaceholder = false
            lastRenderMS = ms
        }
        updateZoomInputs()
        prefetchNeighbour()
    }

    private func updateZoomInputs() {
        guard style == .fullScreen, let photoID, let source = currentSource, let image, !isPlaceholder, displayedSize.width > 0 else { return }
        zoom.setInputs(ZoomRenderInputs(photoID: photoID, source: source, settings: currentSettings, applyCrop: true,
                                        baseRatio: CGFloat(image.width) / displayedSize.width))
    }

    /// Pre-renders the next photo in the direction of travel.
    private func prefetchNeighbour() {
        guard let model, let id = photoID, let i = model.index(of: id) else { return }
        let j = i + direction
        guard model.photos.indices.contains(j) else { return }
        let photo = model.photos[j]
        let (settings, knownSource) = editState(for: photo)
        let size = screenPixelSize
        let key = CacheKey(photoID: photo.id, settings: settings.jsonString() ?? "", size: size)
        guard cache[key] == nil else { return }
        let catalog = model.catalog
        Task.detached(priority: .utility) { [weak self] in
            let source = knownSource ?? RenderPipeline.makeSource(url: SecurityScopeManager.shared.accessibleURL(for: photo, catalog: catalog))
            guard let source else { return }
            let cg = RenderPipeline.renderCGImage(source: source, settings: settings, targetSize: size)
            await self?.prefetched(cg, source: source, key: key)
        }
    }

    private func prefetched(_ cg: CGImage?, source: RenderSource, key: CacheKey) {
        guard isShowing else { return }
        remember(source, for: key.photoID)
        if let cg { store(cg, key) }
    }

    private func store(_ cg: CGImage, _ key: CacheKey) {
        cache[key] = cg
        cacheOrder.removeAll { $0 == key }
        cacheOrder.append(key)
        while cacheOrder.count > 3 { cache[cacheOrder.removeFirst()] = nil }
    }

    private func remember(_ source: RenderSource, for id: Int64) {
        sources[id] = source
        sourceOrder.removeAll { $0 == id }
        sourceOrder.append(id)
        while sourceOrder.count > 3 { sources[sourceOrder.removeFirst()] = nil }
    }
}

/// Borderless windows can't become key by default (they need to, for keys).
private final class FullScreenWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// The Quick Look window; its close button closes the preview.
private final class QuickLookWindow: NSWindow {
    var onClose: (() -> Void)?

    override func close() {
        let done = onClose
        onClose = nil
        super.close()
        done?()
    }
}

/// Quick Look: the photo fitted to the window on black.
struct QuickLookView: View {
    let preview: FullScreenPreview
    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack {
            Color.black
            if let image = preview.image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .id(preview.photoID)            // a new photo crossfades; its sharper render replaces it in place
                    .transition(.opacity)
            } else {
                ProgressView().controlSize(.large)
            }
        }
        .animation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .easeInOut(duration: 0.18), value: preview.photoID)
        .onTapGesture(count: 2) {
            guard let id = preview.photoID else { return }
            preview.close()
            model.openInDevelop(id)
        }
        .help("Double-click to open in Develop")
        .onChange(of: model.focusedPhotoID) { _, id in preview.focusChanged(to: id) }
        .onChange(of: model.mode) { _, mode in if mode != .library { preview.close() } }
    }
}

struct FullScreenPreviewView: View {
    let preview: FullScreenPreview
    @Environment(AppModel.self) private var model
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        let zoom = preview.zoom
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                Color.black
                if let image = preview.image {
                    let rect = zoom.viewport.isValid && zoom.viewport.canvasSize == geo.size
                        ? zoom.imageRect
                        : CanvasGeometry.aspectFitRect(imageSize: CGSize(width: image.width, height: image.height),
                                                       in: CGRect(origin: .zero, size: geo.size))
                    ZoomedImageLayer(image: image, imageRect: rect, zoom: zoom)
                    HandToolLayer(zoom: zoom)
                } else {
                    ProgressView().controlSize(.large).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                ZoomHUD(zoom: zoom)
            }
            .onAppear { zoom.canvasFrame = geo.frame(in: .global) }
            .onChange(of: geo.frame(in: .global)) { _, f in zoom.canvasFrame = f }
            .onChange(of: LayoutKey(size: geo.size, displayed: preview.displayedSize, scale: displayScale), initial: true) { _, k in
                zoom.setLayout(canvasSize: k.size, displayedSize: k.displayed, displayScale: k.scale, margin: 0)
            }
        }
        .ignoresSafeArea()
        .background(.black)
        .canvasPointerRoot()   // the window's only pointerStyle (Develop/Overlays/CanvasPointer.swift)
        .zoomEventMonitor(zoom) { FullScreenPreview.shared.isShowing }
        .onChange(of: model.focusedPhotoID) { _, id in preview.focusChanged(to: id) }
        .onChange(of: model.developSession?.zoomDisplaySettings) { _, _ in preview.refreshIfEdited() }
    }

    private struct LayoutKey: Equatable {
        let size: CGSize
        let displayed: CGSize
        let scale: CGFloat
    }
}

extension View {
    /// F (registry action `fullScreenPreview`) opens the full-screen preview from the main window (Library and Develop).
    func fullScreenPreviewShortcut(model: AppModel) -> some View {
        modifier(FullScreenShortcut(model: model))
    }
}

private struct FullScreenShortcut: ViewModifier {
    let model: AppModel

    func body(content: Content) -> some View {
        content.shortcutHandlers { [model] in
            [ShortcutHandler(.fullScreenPreview, when: { event in
                let fs = FullScreenPreview.shared
                return event.window === ShortcutDispatcher.shared.mainWindow && (!fs.isShowing || fs.style == .quickLook)
            }) { _ in FullScreenPreview.shared.show(model: model) },
             // Space in Library: Quick Look of the focused photo (again: close it).
             ShortcutHandler(.quickLook, when: { event in
                 event.window === ShortcutDispatcher.shared.mainWindow && model.mode == .library
             }) { _ in FullScreenPreview.shared.toggleQuickLook(model: model) }]
        }
    }
}
