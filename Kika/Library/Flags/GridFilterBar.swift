//
//  GridFilterBar.swift
//  Kika
//
//  Bar above the Library grid: the Filter menu + chips of active conditions (flag, rating, tags;
//  Tags/UI/PhotoFilterControls.swift), "Include Subfolders" (when a folder is shown), "By Date" grouping,
//  photo / selection count.
//

import SwiftUI

struct GridFilterBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        HStack(spacing: 12) {
            PhotoFilterMenu()
                .fixedSize()
            // Chips scroll instead of widening the window.
            ScrollView(.horizontal, showsIndicators: false) { PhotoFilterChips() }
                .frame(maxWidth: 520)
                .fixedSize(horizontal: false, vertical: true)

            if model.shownFolderID != nil {
                Toggle("Subfolders", isOn: $model.includeSubfolders)
                    .toggleStyle(.checkbox)
                    .fixedSize()
                    .help("Also show photos of this folder's subfolders")
                    .accessibilityLabel("Include Subfolders")
            }

            Toggle(isOn: $model.groupByDate) {
                Label("By Date", systemImage: "calendar")
            }
            .toggleStyle(.button)
            .fixedSize()
            .help("Group photos by day (View > Group by Date)")

            Spacer(minLength: 8)

            Text(countText)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize()
        }
        .controlSize(.small)
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private var countText: String {
        let n = model.photos.count
        let s = model.selection.count
        let photos = "\(n.formatted()) photo\(n == 1 ? "" : "s")"
        return s > 0 ? "\(photos), \(s.formatted()) selected" : photos
    }
}

extension FlagFilter {
    /// Tooltip of the filter segment.
    var help: String {
        switch self {
        case .all: "Show all photos"
        case .picked: "Show picked photos only"
        case .rejected: "Show rejected photos only"
        case .unflagged: "Show photos without a flag"
        case .notRejected: "Show picked and unflagged photos (hide rejects)"
        }
    }
}
