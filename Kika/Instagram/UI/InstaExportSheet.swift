//
//  InstaExportSheet.swift
//  Kika
//
//  Exporting Instagram slides, posts / story sets and plans (InstaExport.swift): "Export Slide…" (slide menu),
//  "Export Post…" / "Export Stories…" (a card's More menu), "Export Plan…" (board header, the plan's sidebar row).
//  Each asks for a folder (remembered), then exports at once; the sheet shows progress with Cancel, then a summary
//  with Show in Finder. Posted (locked) cards export too.
//

import AppKit
import SwiftUI

@Observable
final class InstaExportController {
    static let shared = InstaExportController()

    enum Phase { case idle, exporting, finished }

    private static let folderKey = "insta.export.folder"

    var isPresented = false
    private(set) var phase: Phase = .idle
    /// What is exported ("Post 1", "Trip").
    private(set) var name = ""
    private(set) var destination: URL?
    private(set) var progress = InstaExportProgress()
    private(set) var result: InstaExportResult?
    private var job: InstaExportJob?

    var title: String { phase == .finished ? "Exported “\(name)”" : "Exporting “\(name)”" }

    var progressText: String {
        progress.total == 0 ? "Preparing…" : "\(min(progress.done + 1, progress.total)) of \(progress.total) files…"
    }

    /// Asks for the folder to export into, then exports `scope`.
    func export(_ scope: InstaExportScope, name: String, model: AppModel) {
        guard phase != .exporting else { isPresented = true; return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Export"
        panel.message = switch scope {
        case .slide: "Choose the folder to save the slide’s images to."
        case .post: "Choose where to save “\(name)”. Its images go into a new folder named after it."
        case .plan: "Choose the folder to save the plan to. Each post and set of stories gets a folder of its own."
        }
        if let path = UserDefaults.standard.string(forKey: Self.folderKey) { panel.directoryURL = URL(fileURLWithPath: path, isDirectory: true) }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        UserDefaults.standard.set(url.path, forKey: Self.folderKey)
        start(scope, name: name, destination: url, catalog: model.catalog)
    }

    /// Exports into `destination` (which must be writable) and shows the sheet.
    func start(_ scope: InstaExportScope, name: String, destination: URL, catalog: Catalog) {
        guard phase != .exporting else { return }
        self.name = name
        self.destination = destination
        result = nil
        progress = InstaExportProgress()
        isPresented = true
        let job: InstaExportJob
        do { job = try InstaExportJob(catalog: catalog, scope: scope, destination: destination) } catch {
            result = InstaExportResult(stopError: .io("Can't read the plan (\(error))", EIO))
            phase = .finished
            return
        }
        self.job = job
        phase = .exporting
        progress.total = job.fileCount
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                job.run { p in Task { @MainActor in InstaExportController.shared.update(p) } }
            }.value
            self.job = nil
            self.result = result
            self.phase = .finished
        }
    }

    private func update(_ p: InstaExportProgress) {
        guard phase == .exporting, p.done >= progress.done else { return }
        progress = p
    }

    func cancel() { job?.cancel() }

    func close() {
        guard phase != .exporting else { return }
        isPresented = false
        phase = .idle
        result = nil
    }

    func showInFinder() {
        guard let result else { return }
        let urls = result.folders.isEmpty ? result.files : result.folders
        if urls.isEmpty, let destination { NSWorkspace.shared.activateFileViewerSelecting([destination]) }
        else { NSWorkspace.shared.activateFileViewerSelecting(urls) }
    }
}

struct InstaExportSheet: View {
    @Bindable var controller: InstaExportController

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(controller.title).font(.headline)
            if let d = controller.destination {
                Label(d.path, systemImage: "folder")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(d.path)
            }
            status
            Text("Each photo as its own image, 1080 px wide · sRGB JPEG")
                .font(.caption)
                .foregroundStyle(.secondary)
            buttons
        }
        .padding(20)
        .frame(width: 440)
        .interactiveDismissDisabled(controller.phase == .exporting)
    }

    @ViewBuilder
    private var status: some View {
        switch controller.phase {
        case .idle:
            EmptyView()
        case .exporting:
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: Double(controller.progress.done), total: Double(max(controller.progress.total, 1)))
                Text(controller.progressText).font(.callout).foregroundStyle(.secondary).monospacedDigit()
            }
        case .finished:
            if let result = controller.result {
                let clean = result.skipped.isEmpty && result.stopError == nil && !result.wasCancelled
                VStack(alignment: .leading, spacing: 4) {
                    Label(result.summary, systemImage: clean ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(clean ? Color.primary : Color.orange)
                    ForEach(Array(result.skipped.prefix(5).enumerated()), id: \.offset) { _, s in
                        Text("\(s.fileName) (\(s.photoName)): \(s.reason.description)").font(.caption).foregroundStyle(.secondary)
                    }
                    if result.skipped.count > 5 {
                        Text("and \(result.skipped.count - 5) more").font(.caption).foregroundStyle(.secondary)
                    }
                    if let error = result.stopError {
                        Text(error.description).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private var buttons: some View {
        HStack {
            if controller.phase == .finished, controller.result?.files.isEmpty == false {
                Button("Show in Finder") { controller.showInFinder() }
                    .help("Reveal the exported files in Finder")
            }
            Spacer()
            if controller.phase == .exporting {
                Button("Cancel") { controller.cancel() }
                    .keyboardShortcut(.cancelAction)
                    .help("Stop exporting (Esc); finished files are kept")
            } else {
                Button("Done") { controller.close() }
                    .keyboardShortcut(.defaultAction)
                    .help("Close (Return)")
            }
        }
    }
}

extension View {
    /// Presents the Instagram export progress sheet (main window).
    func instaExportSheet() -> some View {
        modifier(InstaExportSheetModifier())
    }
}

private struct InstaExportSheetModifier: ViewModifier {
    @Bindable private var controller = InstaExportController.shared

    func body(content: Content) -> some View {
        content.sheet(isPresented: $controller.isPresented, onDismiss: { controller.close() }) {
            InstaExportSheet(controller: controller)
        }
    }
}
