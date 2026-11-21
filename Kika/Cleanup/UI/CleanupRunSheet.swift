//
//  CleanupRunSheet.swift
//  Kika
//
//  "Find Photos to Clean Up…": where to look (All Photographs, Previous Import, or chosen folders with their
//  subfolders), which checks (each with a sensitivity), and whether imports run them too. Starts a
//  `CleanupStore` run and shows Library › Clean Up. Presented by `.cleanupSupport(model:)` on the main window.
//

import SwiftUI

struct CleanupRunSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: CleanupStore.RunSheetRequest

    enum Scope: String, CaseIterable, Identifiable {
        case all, lastImport, folders
        var id: String { rawValue }
    }

    @State private var scope: Scope = .all
    @State private var folderIDs: Set<Int64> = []
    @State private var options = CleanupStore.shared.options
    private var store: CleanupStore { .shared }

    var body: some View {
        @Bindable var store = store
        VStack(alignment: .leading, spacing: 16) {
            Text("Find Photos to Clean Up").font(.title3.weight(.semibold))
            Text("Everything runs on this Mac. Nothing is removed: you review what's found and keep or reject it.")
                .font(.callout).foregroundStyle(.secondary)

            GroupBox("Look In") {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("Look in", selection: $scope) {
                        Text("All Photographs (\(model.totalPhotoCount.formatted()))").tag(Scope.all)
                        Text("Previous Import").tag(Scope.lastImport)
                        Text("These Folders (with subfolders)").tag(Scope.folders)
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()
                    if scope == .folders {
                        List {
                            OutlineGroup(model.folderTree, children: \.childrenOrNil) { node in
                                Toggle(isOn: Binding(get: { folderIDs.contains(node.id) },
                                                     set: { if $0 { folderIDs.insert(node.id) } else { folderIDs.remove(node.id) } })) {
                                    Text(node.folder.name)
                                }
                                .toggleStyle(.checkbox)
                            }
                        }
                        .listStyle(.bordered)
                        .frame(minHeight: 160, maxHeight: 240)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            }

            GroupBox("Look For") {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                    row(.similar, $options.similarSensitivity, "Shots taken one after another that look alike, as stacks: keep the best, reject the rest")
                    row(.blurry, $options.blurSensitivity, "The subject is out of focus or shaken (a soft background is fine)")
                    row(.cropped, $options.cropSensitivity, "A face or head cut by the frame")
                }
                .padding(6)
            }

            Toggle("Also check photos when importing", isOn: $store.runOnImport)
                .toggleStyle(.checkbox)
                .help("Run these checks on every import, so you can clean up right away (Library › Clean Up)")

            HStack {
                Text(countText).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Find Photos") { start() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(options.checks.isEmpty || (scope == .folders && folderIDs.isEmpty))
            }
        }
        .padding(20)
        .frame(width: 560)
        .onAppear {
            folderIDs = request.folderIDs
            scope = request.folderIDs.isEmpty ? .all : .folders
        }
    }

    private func row(_ check: CleanupCheck, _ sensitivity: Binding<CleanupSensitivity>, _ help: String) -> some View {
        GridRow {
            Toggle(isOn: Binding(get: { options.checks.contains(check) },
                                 set: { if $0 { options.checks.insert(check) } else { options.checks.remove(check) } })) {
                Label(check.title, systemImage: check.symbol)
            }
            .toggleStyle(.checkbox)
            .help(help)
            Picker(check.title, selection: sensitivity) {
                ForEach(CleanupSensitivity.allCases) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            .disabled(!options.checks.contains(check))
            .help("Only Obvious finds fewer, More finds more (and some you'll keep)")
        }
    }

    private var countText: String {
        let n = store.analysedCount
        return n == 0 ? "Each photo is analysed once (a few photos a second); later runs only look at new or edited ones." : "\(n.formatted()) photos analysed before: they're not analysed again."
    }

    private func start() {
        store.options = options
        let catalog = model.catalog
        var ids: [Int64] = []
        let title: String
        do {
            switch scope {
            case .all:
                ids = try catalog.photos(in: .all).map(\.id)
                title = "All Photographs"
            case .lastImport:
                ids = try catalog.photos(in: .lastImport).map(\.id)
                title = "Previous Import"
            case .folders:
                var seen = Set<Int64>()
                for id in folderIDs {
                    for p in try catalog.photos(in: .folder(id: id, includeSubfolders: true)) where seen.insert(p.id).inserted { ids.append(p.id) }
                }
                let names = model.folders.filter { folderIDs.contains($0.id) }.map(\.name).sorted()
                title = names.count == 1 ? "“\(names[0])”" : "\(names.count) folders"
            }
        } catch {
            model.report(error)
            return
        }
        dismiss()
        store.run(title: title, photoIDs: ids, options: options)
        model.selectSidebarItem(.cleanup)
    }
}

extension View {
    /// The Clean Up run sheet (main window).
    func cleanupSupport(model: AppModel) -> some View {
        modifier(CleanupSupport(model: model))
    }
}

private struct CleanupSupport: ViewModifier {
    let model: AppModel
    func body(content: Content) -> some View {
        @Bindable var store = CleanupStore.shared
        content.sheet(item: $store.sheet) { request in
            CleanupRunSheet(request: request).environment(model)
        }
    }
}

/// Sidebar Library › Clean Up: badge = groups + photos to review; a spinner while a run is going.
struct CleanupSidebarRow: View {
    var body: some View {
        let store = CleanupStore.shared
        HStack {
            Label("Clean Up", systemImage: "sparkles.rectangle.stack")
            if store.isRunning {
                Spacer()
                ProgressView().controlSize(.mini)
            }
        }
        .badge(store.isRunning ? 0 : store.reviewCount)
        .help(store.isRunning ? store.progressText : "Similar shots, blurry and cropped subjects to review")
    }
}
