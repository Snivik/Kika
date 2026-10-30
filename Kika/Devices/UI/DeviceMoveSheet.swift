//
//  DeviceMoveSheet.swift
//  Kika
//
//  The Move to Device sheet: where the photos are now (per device; offline ones are skipped), the
//  destination folder, the folder layout, "Move the originals to the Trash", Move / Cancel; then progress
//  and a summary with "Show in Finder".
//
//  Entry points: the photo actions registry's `moveToDevice` (context menus, Photo menu, Develop's
//  actions menu; Actions/), the folder context menu "Move Photos to Device…" (SidebarView), and
//  `.deviceMoveSheet()` on the main window.
//

import SwiftUI

struct DeviceMoveSheet: View {
    @Bindable var controller: DeviceMoveController

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(controller.title).font(.headline)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 14) {
                GridRow {
                    Text("From:").gridColumnAlignment(.trailing)
                    sourcesList
                }
                GridRow {
                    Text("To:")
                    destinationRow
                }
                GridRow {
                    Text("Folders:")
                    Picker("Folders", selection: $controller.layout) {
                        ForEach(DeviceMoveLayout.allCases) { layout in
                            Text(layout.title).tag(layout).help(layout.help)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .help(controller.layout.help)
                }
                GridRow {
                    Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                    Toggle("Move the originals to the Trash", isOn: $controller.trashOriginals)
                        .help("After each copy is checked and the catalog points at it, its original goes to the Trash. Off: the originals stay where they are")
                }
            }
            .disabled(controller.phase != .idle)
            Text("Each copy is compared byte for byte with its original before the catalog points at it. Edits, flags, tags, folders and virtual copies stay with every photo.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            statusSection
            buttons
        }
        .padding(20)
        .frame(width: 520)
        .interactiveDismissDisabled(controller.phase == .moving)
    }

    private var sourcesList: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(controller.sources) { group in
                HStack(spacing: 6) {
                    Image(systemName: group.device.symbol).foregroundStyle(.secondary)
                    Text("\(group.device.title) · \(group.count) photo\(group.count == 1 ? "" : "s") · \(ByteCountFormatter.string(fromByteCount: group.bytes, countStyle: .file))")
                    if !group.isOnline {
                        Text("not connected, skipped").foregroundStyle(.orange)
                    }
                }
                .opacity(group.isOnline ? 1 : 0.7)
            }
        }
    }

    private var destinationRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if let d = controller.destination {
                    Image(systemName: PhotoDevice(path: d.path).symbol).foregroundStyle(.secondary)
                    Text(d.path)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(d.path)
                } else {
                    Image(systemName: "folder").foregroundStyle(.secondary)
                    Text("No folder chosen").foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if controller.isCheckingDestination { ProgressView().controlSize(.small) }
                Button("Choose…") { controller.chooseDestination() }
                    .help("Choose the folder the photos move to")
            }
            if let problem = controller.destinationProblem {
                Text(problem)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var statusSection: some View {
        switch controller.phase {
        case .idle:
            EmptyView()
        case .moving:
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: Double(min(controller.progress.bytesDone, controller.progress.bytesTotal)),
                             total: Double(max(controller.progress.bytesTotal, 1)))
                Text(controller.progressText).font(.callout).foregroundStyle(.secondary).monospacedDigit()
            }
        case .finished:
            if let result = controller.result {
                let clean = result.skipped.isEmpty && result.stopError == nil && result.trashFailures.isEmpty && !result.wasCancelled
                VStack(alignment: .leading, spacing: 4) {
                    Label(result.summary, systemImage: clean ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(clean ? Color.primary : Color.orange)
                    ForEach(result.skipped.prefix(5), id: \.photoID) { s in
                        Text("\(s.fileName): \(s.reason.description)").font(.caption).foregroundStyle(.secondary)
                    }
                    if result.skipped.count > 5 {
                        Text("and \(result.skipped.count - 5) more").font(.caption).foregroundStyle(.secondary)
                    }
                    if !result.trashFailures.isEmpty {
                        Text("Couldn't move \(result.trashFailures.count) original\(result.trashFailures.count == 1 ? "" : "s") to the Trash (e.g. \(result.trashFailures[0])); they are still at their old place.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    if let error = result.stopError {
                        Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var buttons: some View {
        HStack {
            if controller.phase == .finished, controller.result?.moved.isEmpty == false {
                Button("Show in Finder") { controller.showInFinder() }
                    .help("Reveal the moved files in Finder")
            }
            Spacer()
            switch controller.phase {
            case .idle:
                Button("Cancel") { controller.close() }
                    .keyboardShortcut(.cancelAction)
                    .help("Close without moving anything (Esc)")
                Button("Move") { controller.start() }
                    .keyboardShortcut(.defaultAction)
                    .help(controller.onlineCount == 0 ? "None of these photos are on a connected device" : "Copy, check, and point the catalog at the copies (Return)")
                    .disabled(!controller.canMove)
            case .moving:
                Button("Stop") { controller.cancel() }
                    .keyboardShortcut(.cancelAction)
                    .help("Stop after the current photo is cleaned up (Esc); photos already moved stay moved")
            case .finished:
                Button("Done") { controller.close() }
                    .keyboardShortcut(.defaultAction)
                    .help("Close (Return)")
            }
        }
    }
}

extension View {
    /// Presents the Move to Device sheet (Devices/UI/DeviceMoveSheet.swift).
    func deviceMoveSheet() -> some View {
        modifier(DeviceMoveSheetModifier())
    }
}

private struct DeviceMoveSheetModifier: ViewModifier {
    @Bindable private var controller = DeviceMoveController.shared

    func body(content: Content) -> some View {
        content.sheet(isPresented: $controller.isPresented, onDismiss: { controller.close() }) {
            DeviceMoveSheet(controller: controller)
        }
    }
}
