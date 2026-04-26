//
//  TabSelectionView.swift
//  boringNotch
//
//  Created by Hugo Persson on 2024-08-25.
//

import SwiftUI

struct TabModel: Identifiable {
    let id = UUID()
    let label: String
    let view: NotchViews
}

let tabs = [
    TabModel(label: "Home", view: .home),
    TabModel(label: "Shelf", view: .shelf),
    TabModel(label: "Clipboard", view: .clipboard),
    TabModel(label: "VS Code", view: .vscodeProjects),
    TabModel(label: "Codex", view: .codexStatus)
]

struct TabSelectionView: View {
    @ObservedObject var coordinator = BoringViewCoordinator.shared
    @Namespace var animation

    var body: some View {
        HStack(spacing: 2) {
            ForEach(tabs) { tab in
                let isSelected = coordinator.currentView == tab.view
                Button {
                    withAnimation(.smooth) {
                        coordinator.currentView = tab.view
                    }
                } label: {
                    ZStack {
                        if isSelected {
                            Capsule()
                                .fill(Color(nsColor: .secondarySystemFill))
                                .matchedGeometryEffect(id: "selectedTabCapsule", in: animation)
                        }

                        iconView(for: tab.view, isSelected: isSelected)
                            .font(.system(size: 12, weight: .semibold))
                            .frame(width: 32, height: 26)
                    }
                    .frame(width: 32, height: 26)
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(tab.label)
                .zIndex(isSelected ? 1 : 0)
            }
        }
        .padding(.horizontal, 2)
        .clipShape(Capsule())
    }

    @ViewBuilder
    private func iconView(for view: NotchViews, isSelected: Bool) -> some View {
        let color: Color = isSelected ? .white : .gray
        switch view {
        case .home:
            Image(systemName: "house.fill")
                .foregroundStyle(color)
        case .shelf:
            Image(systemName: "tray.fill")
                .foregroundStyle(color)
        case .clipboard:
            Image(systemName: "doc.on.clipboard")
                .foregroundStyle(color)
        case .vscodeProjects:
            Image(systemName: "chevron.left.forwardslash.chevron.right")
                .foregroundStyle(color)
        case .codexStatus:
            CodexTabIcon(color: color)
        }
    }
}

private struct CodexTabIcon: View {
    let color: Color

    var body: some View {
        CodexGlyphIcon(size: 15, foreground: color)
    }
}

#Preview {
    BoringHeader().environmentObject(BoringViewModel())
}
