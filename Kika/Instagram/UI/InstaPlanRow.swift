//
//  InstaPlanRow.swift
//  Kika
//
//  A folder's Instagram plan in the sidebar: the first child row under its folder (FolderOutline). Selecting it
//  shows the plan board with the folder's photos to pick from. Context menu: new post / stories, delete
//  (confirmed; photos are never touched).
//

import SwiftUI

struct InstaPlanRow: View {
    let plan: InstaPlan

    var body: some View {
        Label("Instagram", systemImage: "square.grid.3x3")
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .help("Instagram plan: arrange this folder's photos into posts and stories")
    }

    @ViewBuilder
    static func menuItems(_ plan: InstaPlan, model: AppModel) -> some View {
        Button("New Post") { show(plan, model: model); InstaActions.newPost(.post, model: model) }
        Button("New Stories") { show(plan, model: model); InstaActions.newPost(.story, model: model) }
        Divider()
        Button("Delete Instagram Plan…") { InstaStore.shared.pendingPlanDeletion = plan }
    }

    private static func show(_ plan: InstaPlan, model: AppModel) {
        if model.mode != .library { model.mode = .library }
        model.selectSidebarItem(.plan(plan.id))
    }
}

extension View {
    /// Confirmation for "Delete Instagram Plan…" (sidebar).
    func instaPlanDeletionAlert(model: AppModel) -> some View {
        let store = InstaStore.shared
        return alert("Delete the Instagram plan?", isPresented: Binding(
            get: { store.pendingPlanDeletion != nil },
            set: { if !$0 { store.pendingPlanDeletion = nil } }
        ), presenting: store.pendingPlanDeletion) { plan in
            Button("Delete", role: .destructive) { InstaActions.deletePlan(plan, model: model) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Its posts and stories, captions and dates are deleted. Photos stay in the catalog and the folder.")
        }
    }
}

/// "P1 S2" on a grid cell: the Instagram posts / story sets the photo is in (nothing when unused).
struct InstaUsageBadge: View {
    let photoID: Int64

    var body: some View {
        let store = InstaStore.shared
        if let label = store.usageLabel(photoID) {
            Text(label)
                .font(.caption2.weight(.semibold))
                .lineLimit(1)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(Color.accentColor.opacity(0.85), in: RoundedRectangle(cornerRadius: 3))
                .foregroundStyle(.white)
                .help(store.usageHelp(photoID))
                .accessibilityLabel("Used on Instagram: \(label)")
        }
    }
}

/// Library › Calendar (shown once a folder has a plan): badge = posts planned from today on, not posted yet.
struct InstaCalendarRow: View {
    var body: some View {
        let start = Calendar.current.startOfDay(for: Date())
        let upcoming = InstaStore.shared.allPosts.filter { $0.status != .posted && ($0.scheduledAt.map { $0 >= start } ?? false) }.count
        Label("Calendar", systemImage: "calendar")
            .badge(upcoming)
            .help("Every plan's posts and stories by planned date")
    }
}
