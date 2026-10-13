//
//  SidebarSectionHeader.swift
//  Kika
//
//  Sidebar section header with an always-visible show / hide chevron. Replaces `Section(isExpanded:)`, whose
//  chevron only appears while the pointer is over the header: it pushed the header's buttons left on hover
//  (a click aimed at one button hit the next) and sometimes stayed after the pointer left. Nothing here
//  depends on hover, so the header never changes layout. Use with a plain `Section { if shown { … } }`.
//

import SwiftUI

struct SidebarSectionHeader<Accessory: View, Actions: View>: View {
    let title: String
    @Binding var isExpanded: Bool
    /// Next to the title (e.g. the folder tag filter).
    @ViewBuilder var accessory: () -> Accessory
    /// Trailing buttons, before the chevron (e.g. "+").
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
            accessory()
            Spacer(minLength: 4)
            actions()
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
            } label: {
                Image(systemName: "chevron.right")
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .font(.caption.weight(.semibold))
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help(isExpanded ? "Hide \(title)" : "Show \(title)")
            .accessibilityLabel(isExpanded ? "Hide \(title)" : "Show \(title)")
        }
        .padding(.vertical, 2)
    }
}

extension SidebarSectionHeader where Accessory == EmptyView, Actions == EmptyView {
    init(_ title: String, isExpanded: Binding<Bool>) {
        self.init(title: title, isExpanded: isExpanded, accessory: { EmptyView() }, actions: { EmptyView() })
    }
}

extension SidebarSectionHeader where Accessory == EmptyView {
    init(_ title: String, isExpanded: Binding<Bool>, @ViewBuilder actions: @escaping () -> Actions) {
        self.init(title: title, isExpanded: isExpanded, accessory: { EmptyView() }, actions: actions)
    }
}
