//
//  TabSelectionView.swift
//  boringNotch
//
//  Created by Hugo Persson on 2024-08-25.
//

import Defaults
import KeyboardShortcuts
import SwiftUI

struct TabModel: Identifiable {
    let label: String
    let view: NotchViews
    let shortcut: KeyboardShortcuts.Name

    var id: NotchViews { view }

    static let main = [
        TabModel(label: "音乐", view: .music, shortcut: .toggleMusicTab),
        TabModel(label: "剪贴板", view: .clipboard, shortcut: .toggleClipboardTab),
        TabModel(label: "项目", view: .vscodeProjects, shortcut: .toggleVSCodeTab),
        TabModel(label: "备忘录", view: .memo, shortcut: .toggleMemoTab),
        TabModel(label: "待办", view: .todo, shortcut: .toggleTodoTab)
    ]

    static let utilities = [
        TabModel(label: "应用启动器", view: .appLauncher, shortcut: .toggleAppLauncherTab),
        TabModel(label: "工具集", view: .toolbox, shortcut: .toggleToolboxTab)
    ]

    static let all = main + utilities
}

struct PanelTabLayout: Codable, Defaults.Serializable, Equatable {
    private var order: [String] = []
    private var hidden: Set<String> = []

    var orderedTabs: [TabModel] {
        let saved = order.compactMap { id in TabModel.all.first { $0.view.rawValue == id } }
        var seen = Set<NotchViews>()
        return (saved + TabModel.all).filter { seen.insert($0.view).inserted }
    }

    var visibleTabs: [TabModel] {
        let ordered = orderedTabs
        let visible = ordered.filter { !hidden.contains($0.view.rawValue) }
        return visible.isEmpty ? Array(ordered.prefix(1)) : visible
    }

    var leadingTabs: [TabModel] {
        let visible = Set(visibleTabs.map(\.view))
        return orderedTabs.prefix(TabModel.main.count).filter { visible.contains($0.view) }
    }

    var trailingTabs: [TabModel] {
        let visible = Set(visibleTabs.map(\.view))
        return orderedTabs.dropFirst(TabModel.main.count).filter { visible.contains($0.view) }
    }

    func isVisible(_ tab: NotchViews) -> Bool {
        visibleTabs.contains { $0.view == tab }
    }

    func selection(preferred tab: NotchViews) -> NotchViews {
        let visible = visibleTabs
        return visible.contains { $0.view == tab } ? tab : (visible.first?.view ?? .music)
    }

    mutating func move(_ tab: NotchViews, onto target: NotchViews) {
        guard tab != target else { return }
        var updated = orderedTabs.map(\.view.rawValue)
        guard let source = updated.firstIndex(of: tab.rawValue),
              let destination = updated.firstIndex(of: target.rawValue) else { return }
        let moved = updated.remove(at: source)
        updated.insert(moved, at: destination)
        order = updated
    }

    mutating func setVisible(_ visible: Bool, for tab: NotchViews) {
        if visible {
            hidden.remove(tab.rawValue)
        } else if visibleTabs.contains(where: { $0.view != tab }) {
            hidden.insert(tab.rawValue)
        }
    }
}

private let notchHeaderIconSize: CGFloat = 15

struct NotchHeaderSymbol: View {
    let name: String

    var body: some View {
        Image(systemName: name)
            .resizable()
            .scaledToFit()
            .frame(width: notchHeaderIconSize, height: notchHeaderIconSize)
            .font(.system(size: notchHeaderIconSize, weight: .semibold))
    }
}

struct TabSelectionView: View {
    let tabs: [TabModel]
    @ObservedObject var coordinator = BoringViewCoordinator.shared
    @Namespace var animation
    @State private var hoveredTab: NotchViews? = nil

    var body: some View {
        HStack(spacing: 2) {
            ForEach(tabs) { tab in
                let isSelected = coordinator.currentView == tab.view
                Button {
                    withAnimation(.smooth) {
                        coordinator.currentView = tab.view
                    }
                } label: {
                    iconView(for: tab.view, isSelected: isSelected)
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 32, height: 26)
                        .background {
                            if isSelected {
                                Capsule()
                                    .fill(Color(nsColor: .secondarySystemFill))
                                    .matchedGeometryEffect(id: "selectedTabCapsule", in: animation)
                            } else if hoveredTab == tab.view {
                                Capsule()
                                    .fill(Color(nsColor: .secondarySystemFill))
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tab.label)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
                .help(tab.label)
                .zIndex(isSelected ? 1 : 0)
                .onHover { hovering in
                    hoveredTab = hovering ? tab.view : nil
                }
            }
        }
        .clipShape(Capsule())
    }

    @ViewBuilder
    private func iconView(for view: NotchViews, isSelected: Bool) -> some View {
        let color: Color = isSelected ? .white : .gray
        switch view {
        case .music:
            AppleMusicNoteShape()
                .fill(color)
                .frame(width: notchHeaderIconSize, height: notchHeaderIconSize)
                .foregroundStyle(color)
                .opacity(isSelected ? 0.98 : 0.82)
                .offset(y: -0.25)
        case .clipboard:
            Image(systemName: "doc.on.clipboard")
                .foregroundStyle(color)
        case .vscodeProjects:
            ProjectFolderShape()
                .stroke(color, style: StrokeStyle(lineWidth: 1.35, lineCap: .round, lineJoin: .round))
                .frame(width: notchHeaderIconSize, height: notchHeaderIconSize)
        case .memo:
            MemoNotepadShape()
                .stroke(color, lineWidth: 1.35)
                .frame(width: notchHeaderIconSize, height: notchHeaderIconSize)
        case .todo:
            TodoChecklistShape()
                .stroke(color, lineWidth: 1.25)
                .frame(width: notchHeaderIconSize, height: notchHeaderIconSize)
        case .appLauncher:
            AppLauncherGridShape()
                .fill(color, style: FillStyle(eoFill: true))
                .frame(width: notchHeaderIconSize, height: notchHeaderIconSize)
        case .toolbox:
            NotchHeaderSymbol(name: "cube")
                .foregroundStyle(color)
        }
    }
}

private struct MemoNotepadShape: Shape {
    func path(in rect: CGRect) -> Path {
        let outline = CGRect(x: 2.1, y: 3.0, width: 11.8, height: 12.1)
        var path = Path(roundedRect: outline, cornerRadius: 1.1)

        let bindingPositions: [CGFloat] = [5, 8, 11]
        for x in bindingPositions {
            path.move(to: CGPoint(x: x, y: 0.8))
            path.addLine(to: CGPoint(x: x, y: 4.8))
        }

        let lineEnds = [CGPoint(x: 10.5, y: 7), CGPoint(x: 11.6, y: 9.8), CGPoint(x: 9.5, y: 12.6)]
        for end in lineEnds {
            path.move(to: CGPoint(x: 4.5, y: end.y))
            path.addLine(to: end)
        }

        let scale = min(rect.width, rect.height) / 16
        let transform = CGAffineTransform(translationX: rect.midX - 8 * scale, y: rect.midY - 8 * scale)
            .scaledBy(x: scale, y: scale)
        return path.applying(transform)
    }
}

private struct TodoChecklistShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let rowCenters: [CGFloat] = [3.1, 8, 12.9]
        let diameter: CGFloat = 2.9

        for y in rowCenters {
            let circle = CGRect(x: 1.2, y: y - diameter / 2, width: diameter, height: diameter)
            path.addEllipse(in: circle)
            path.move(to: CGPoint(x: 6.6, y: y))
            path.addLine(to: CGPoint(x: 15.4, y: y))
        }

        let scale = min(rect.width, rect.height) / 16
        let transform = CGAffineTransform(translationX: rect.midX - 8 * scale, y: rect.midY - 8 * scale)
            .scaledBy(x: scale, y: scale)
        return path.applying(transform)
    }
}

private struct AppLauncherGridShape: Shape {
    func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height) * 0.87
        let diameter = side * 0.45
        let pitch = side - diameter
        let ringWidth = side * 0.085
        let left = rect.midX - side / 2
        let top = rect.midY - side / 2
        var path = Path()
        for y in [top, top + pitch] {
            for x in [left, left + pitch] {
                let ring = CGRect(x: x, y: y, width: diameter, height: diameter)
                path.addEllipse(in: ring)
                path.addEllipse(in: ring.insetBy(dx: ringWidth, dy: ringWidth))
            }
        }
        return path
    }
}

private struct AppleMusicNoteShape: Shape {
    private static let pathData = "M 108 4 L 110 4 L 110 5 L 112 5 L 112 6 L 113 6 L 113 8 L 114 8 L 114 92 L 113 92 L 113 116 L 112 116 L 112 118 L 111 118 L 111 120 L 110 120 L 110 122 L 109 122 L 109 123 L 108 123 L 108 124 L 107 124 L 107 125 L 105 125 L 105 126 L 104 126 L 104 127 L 101 127 L 101 128 L 98 128 L 98 129 L 84 129 L 84 128 L 82 128 L 82 127 L 81 127 L 81 126 L 79 126 L 79 125 L 78 125 L 78 124 L 77 124 L 77 122 L 76 122 L 76 120 L 75 120 L 75 117 L 74 117 L 74 110 L 75 110 L 75 107 L 76 107 L 76 105 L 77 105 L 77 104 L 78 104 L 78 103 L 79 103 L 79 102 L 80 102 L 80 101 L 81 101 L 81 100 L 83 100 L 83 99 L 85 99 L 85 98 L 89 98 L 89 97 L 93 97 L 93 96 L 98 96 L 98 95 L 102 95 L 102 94 L 104 94 L 104 93 L 105 93 L 105 92 L 106 92 L 106 39 L 105 39 L 105 38 L 99 38 L 99 39 L 94 39 L 94 40 L 89 40 L 89 41 L 84 41 L 84 42 L 79 42 L 79 43 L 74 43 L 74 44 L 69 44 L 69 45 L 64 45 L 64 46 L 59 46 L 59 47 L 54 47 L 54 48 L 49 48 L 49 49 L 46 49 L 46 50 L 45 50 L 45 51 L 44 51 L 44 125 L 43 125 L 43 130 L 42 130 L 42 133 L 41 133 L 41 134 L 40 134 L 40 136 L 39 136 L 39 137 L 38 137 L 38 138 L 37 138 L 37 139 L 36 139 L 36 140 L 34 140 L 34 141 L 32 141 L 32 142 L 28 142 L 28 143 L 21 143 L 21 144 L 20 144 L 20 143 L 14 143 L 14 142 L 12 142 L 12 141 L 11 141 L 11 140 L 9 140 L 9 139 L 8 139 L 8 137 L 7 137 L 7 136 L 6 136 L 6 134 L 5 134 L 5 129 L 4 129 L 4 127 L 5 127 L 5 122 L 6 122 L 6 120 L 7 120 L 7 118 L 8 118 L 8 117 L 9 117 L 9 116 L 10 116 L 10 115 L 12 115 L 12 114 L 14 114 L 14 113 L 16 113 L 16 112 L 19 112 L 19 111 L 24 111 L 24 110 L 29 110 L 29 109 L 33 109 L 33 108 L 34 108 L 34 107 L 35 107 L 35 106 L 36 106 L 36 102 L 37 102 L 37 92 L 36 92 L 36 24 L 37 24 L 37 20 L 38 20 L 38 19 L 40 19 L 40 18 L 43 18 L 43 17 L 48 17 L 48 16 L 53 16 L 53 15 L 58 15 L 58 14 L 63 14 L 63 13 L 67 13 L 67 12 L 72 12 L 72 11 L 77 11 L 77 10 L 82 10 L 82 9 L 87 9 L 87 8 L 92 8 L 92 7 L 97 7 L 97 6 L 102 6 L 102 5 L 108 5 Z"

    private static let logoPath: CGPath = {
        var tokens: [String] = []
        var tokBuf = ""
        for ch in pathData {
            if ch.isLetter {
                if !tokBuf.isEmpty { tokens.append(tokBuf); tokBuf = "" }
                tokens.append(String(ch))
            } else if ch.isWhitespace || ch == "," {
                if !tokBuf.isEmpty { tokens.append(tokBuf); tokBuf = "" }
            } else {
                tokBuf.append(ch)
            }
        }
        if !tokBuf.isEmpty { tokens.append(tokBuf) }

        let path = CGMutablePath()
        var i = 0
        var start = CGPoint.zero

        while i < tokens.count {
            switch tokens[i] {
            case "M":
                if i + 2 < tokens.count,
                   let x = Double(tokens[i + 1]),
                   let y = Double(tokens[i + 2]) {
                    let pt = CGPoint(x: x, y: y)
                    path.move(to: pt)
                    start = pt
                    i += 3
                } else {
                    i += 1
                }
            case "L":
                if i + 2 < tokens.count,
                   let x = Double(tokens[i + 1]),
                   let y = Double(tokens[i + 2]) {
                    path.addLine(to: CGPoint(x: x, y: y))
                    i += 3
                } else {
                    i += 1
                }
            case "Z", "z":
                path.closeSubpath()
                path.move(to: start)
                i += 1
            default:
                i += 1
            }
        }

        return path
    }()

    func path(in rect: CGRect) -> Path {
        let contentWidth: CGFloat = 110
        let contentHeight: CGFloat = 140
        let contentCenterX: CGFloat = 59
        let contentCenterY: CGFloat = 74
        let scale = min(rect.width / contentWidth, rect.height / contentHeight)

        var transform = CGAffineTransform(
            translationX: rect.midX - contentCenterX * scale,
            y: rect.midY - contentCenterY * scale
        ).scaledBy(x: scale, y: scale)

        guard let scaled = Self.logoPath.copy(using: &transform) else {
            return Path()
        }

        return Path(scaled)
    }
}

private struct ProjectFolderShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 2.3, y: 14.4))
        path.addQuadCurve(to: CGPoint(x: 0.9, y: 13), control: CGPoint(x: 0.9, y: 14.4))
        path.addLine(to: CGPoint(x: 0.9, y: 3))
        path.addQuadCurve(to: CGPoint(x: 2.3, y: 1.6), control: CGPoint(x: 0.9, y: 1.6))
        path.addLine(to: CGPoint(x: 5.9, y: 1.6))
        path.addLine(to: CGPoint(x: 7.8, y: 3.6))
        path.addLine(to: CGPoint(x: 13.7, y: 3.6))
        path.addQuadCurve(to: CGPoint(x: 15.1, y: 5), control: CGPoint(x: 15.1, y: 3.6))
        path.addLine(to: CGPoint(x: 15.1, y: 13))
        path.addQuadCurve(to: CGPoint(x: 13.7, y: 14.4), control: CGPoint(x: 15.1, y: 14.4))
        path.closeSubpath()

        for (x, height) in [(5.2, 3.8), (8.1, 2.4), (11.1, 4.6)] {
            path.move(to: CGPoint(x: x, y: 7.1))
            path.addLine(to: CGPoint(x: x, y: 7.1 + height))
        }

        let scale = min(rect.width, rect.height) / 16
        return path.applying(CGAffineTransform(translationX: rect.midX - 8 * scale, y: rect.midY - 8 * scale)
            .scaledBy(x: scale, y: scale))
    }
}

#Preview {
    BoringHeader().environmentObject(BoringViewModel())
}
