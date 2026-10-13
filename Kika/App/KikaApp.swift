//
//  KikaApp.swift
//  Kika
//
//  Created by Alexander Troshchenko on 29/09/2026.
//

import SwiftUI

@main
struct KikaApp: App {
    @State private var model = AppModel.makeDefault()

    var body: some Scene {
        Window("Кика", id: "main") {
            MainWindowView()
                .environment(model)
                .frame(minWidth: 900, minHeight: 600)
        }
        .commands {
            KikaCommands(model: model)
            PreviewCommands(model: model)
            ExportCommands(model: model)
            CatalogTransferCommands(model: model)
        }

        Settings {
            SettingsRootView()
                .environment(model)
        }
    }
}

/// Settings window: Previews, Drives, Raw Decode, Keyboard (the selected tab is `SettingsNavigation.shared.tab`
/// so menu items can open a specific tab).
struct SettingsRootView: View {
    @Bindable private var navigation = SettingsNavigation.shared

    var body: some View {
        TabView(selection: $navigation.tab) {
            Tab("Previews", systemImage: "photo.stack", value: SettingsTab.previews) {
                PreviewSettingsView(showsDoneButton: false)
            }
            Tab("Drives", systemImage: "externaldrive", value: SettingsTab.drives) {
                ScrollView {
                    RootsAccessView()
                        .padding(20)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minWidth: 520, minHeight: 280)
            }
            Tab("Raw Decode", systemImage: "camera.aperture", value: SettingsTab.rawDecode) {
                DecodeProfilesSettingsView()
            }
            Tab("Keyboard", systemImage: "keyboard", value: SettingsTab.keyboard) {
                KeyboardSettingsView()
            }
        }
        .toolbarHelp([
            "Previews": "Preview sizes, quality, Develop render cache, cache size",
            "Drives": "Folders and drives Кика may read; grant access or relink",
            "Raw Decode": "Decode profiles: global and per-camera defaults, edit, import and export",
            "Keyboard": "Keyboard shortcuts: view and change them",
        ])
    }
}
