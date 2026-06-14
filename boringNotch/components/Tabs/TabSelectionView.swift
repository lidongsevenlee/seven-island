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
    TabModel(label: "音乐", view: .music),
    TabModel(label: "文件架", view: .shelf),
    TabModel(label: "剪贴板", view: .clipboard),
    TabModel(label: "VS Code", view: .vscodeProjects),
    TabModel(label: "菜单栏", view: .menuBarItems),
    TabModel(label: "Hooks", view: .hooksActivity)
]

struct TabSelectionView: View {
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
                    ZStack {
                        if isSelected {
                            Capsule()
                                .fill(Color(nsColor: .secondarySystemFill))
                                .matchedGeometryEffect(id: "selectedTabCapsule", in: animation)
                        } else if hoveredTab == tab.view {
                            Capsule()
                                .fill(Color(nsColor: .secondarySystemFill))
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
                .onHover { hovering in
                    hoveredTab = hovering ? tab.view : nil
                }
            }
        }
        .padding(.leading, 2)
        .padding(.trailing, 12)
        .clipShape(Capsule())
    }

    @ViewBuilder
    private func iconView(for view: NotchViews, isSelected: Bool) -> some View {
        let color: Color = isSelected ? .white : .gray
        switch view {
        case .music:
            AppleMusicNoteShape()
                .fill(color)
                .frame(width: 15, height: 15)
                .foregroundStyle(color)
                .opacity(isSelected ? 0.98 : 0.82)
                .offset(y: -0.25)
        case .shelf:
            Image(systemName: "tray.fill")
                .foregroundStyle(color)
        case .clipboard:
            Image(systemName: "doc.on.clipboard")
                .foregroundStyle(color)
        case .vscodeProjects:
            VSCodeSymbolShape()
                .fill(color, style: FillStyle(eoFill: true))
                .frame(width: 15, height: 15)
                .opacity(isSelected ? 0.98 : 0.82)
                .offset(y: -0.15)
        case .menuBarItems:
            Image(systemName: "menubar.rectangle")
                .foregroundStyle(color)
        case .hooksActivity:
            Image(systemName: "bell.badge")
                .foregroundStyle(color)
        }
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

private struct VSCodeSymbolShape: Shape {
    private static let pathData = "M 129 2 L 133 2 L 133 3 L 136 3 L 136 4 L 138 4 L 138 5 L 140 5 L 140 6 L 142 6 L 142 7 L 144 7 L 144 8 L 146 8 L 146 9 L 148 9 L 148 10 L 150 10 L 150 11 L 152 11 L 152 12 L 154 12 L 154 13 L 156 13 L 156 14 L 159 14 L 159 15 L 161 15 L 161 16 L 163 16 L 163 17 L 165 17 L 165 18 L 167 18 L 167 19 L 169 19 L 169 20 L 171 20 L 171 21 L 173 21 L 173 22 L 174 22 L 174 23 L 175 23 L 175 24 L 176 24 L 176 26 L 177 26 L 177 28 L 178 28 L 178 151 L 177 151 L 177 153 L 176 153 L 176 155 L 175 155 L 175 156 L 174 156 L 174 157 L 173 157 L 173 158 L 171 158 L 171 159 L 169 159 L 169 160 L 167 160 L 167 161 L 165 161 L 165 162 L 163 162 L 163 163 L 161 163 L 161 164 L 159 164 L 159 165 L 157 165 L 157 166 L 154 166 L 154 167 L 152 167 L 152 168 L 150 168 L 150 169 L 148 169 L 148 170 L 146 170 L 146 171 L 144 171 L 144 172 L 142 172 L 142 173 L 140 173 L 140 174 L 138 174 L 138 175 L 136 175 L 136 176 L 133 176 L 133 177 L 129 177 L 129 176 L 125 176 L 125 175 L 124 175 L 124 174 L 123 174 L 123 173 L 121 173 L 121 172 L 120 172 L 120 171 L 119 171 L 119 170 L 118 170 L 118 169 L 117 169 L 117 168 L 116 168 L 116 167 L 115 167 L 115 166 L 114 166 L 114 165 L 113 165 L 113 164 L 112 164 L 112 163 L 110 163 L 110 162 L 109 162 L 109 161 L 108 161 L 108 160 L 107 160 L 107 159 L 106 159 L 106 158 L 105 158 L 105 157 L 104 157 L 104 156 L 103 156 L 103 155 L 102 155 L 102 154 L 101 154 L 101 153 L 99 153 L 99 152 L 98 152 L 98 151 L 97 151 L 97 150 L 96 150 L 96 149 L 95 149 L 95 148 L 94 148 L 94 147 L 93 147 L 93 146 L 92 146 L 92 145 L 91 145 L 91 144 L 90 144 L 90 143 L 89 143 L 89 142 L 88 142 L 88 141 L 86 141 L 86 140 L 85 140 L 85 139 L 84 139 L 84 138 L 83 138 L 83 137 L 82 137 L 82 136 L 81 136 L 81 135 L 80 135 L 80 134 L 79 134 L 79 133 L 78 133 L 78 132 L 77 132 L 77 131 L 75 131 L 75 130 L 74 130 L 74 129 L 73 129 L 73 128 L 72 128 L 72 127 L 71 127 L 71 126 L 70 126 L 70 125 L 69 125 L 69 124 L 68 124 L 68 123 L 67 123 L 67 122 L 65 122 L 65 121 L 64 121 L 64 120 L 63 120 L 63 119 L 62 119 L 62 118 L 61 118 L 61 117 L 60 117 L 60 116 L 59 116 L 59 115 L 58 115 L 58 114 L 57 114 L 57 113 L 56 113 L 56 112 L 55 112 L 55 111 L 53 111 L 53 112 L 51 112 L 51 113 L 50 113 L 50 114 L 49 114 L 49 115 L 47 115 L 47 116 L 46 116 L 46 117 L 45 117 L 45 118 L 44 118 L 44 119 L 42 119 L 42 120 L 41 120 L 41 121 L 40 121 L 40 122 L 38 122 L 38 123 L 37 123 L 37 124 L 36 124 L 36 125 L 34 125 L 34 126 L 33 126 L 33 127 L 32 127 L 32 128 L 30 128 L 30 129 L 29 129 L 29 130 L 28 130 L 28 131 L 26 131 L 26 132 L 25 132 L 25 133 L 24 133 L 24 134 L 22 134 L 22 135 L 17 135 L 17 134 L 15 134 L 15 133 L 14 133 L 14 132 L 13 132 L 13 131 L 12 131 L 12 130 L 11 130 L 11 129 L 9 129 L 9 128 L 8 128 L 8 127 L 7 127 L 7 126 L 6 126 L 6 125 L 5 125 L 5 124 L 4 124 L 4 123 L 3 123 L 3 121 L 2 121 L 2 116 L 3 116 L 3 114 L 4 114 L 4 113 L 5 113 L 5 112 L 6 112 L 6 111 L 8 111 L 8 110 L 9 110 L 9 109 L 10 109 L 10 108 L 11 108 L 11 107 L 12 107 L 12 106 L 13 106 L 13 105 L 14 105 L 14 104 L 15 104 L 15 103 L 16 103 L 16 102 L 17 102 L 17 101 L 18 101 L 18 100 L 19 100 L 19 99 L 20 99 L 20 98 L 22 98 L 22 97 L 23 97 L 23 96 L 24 96 L 24 95 L 25 95 L 25 94 L 26 94 L 26 93 L 27 93 L 27 92 L 28 92 L 28 91 L 29 91 L 29 90 L 30 90 L 30 89 L 29 89 L 29 88 L 28 88 L 28 87 L 27 87 L 27 86 L 26 86 L 26 85 L 25 85 L 25 84 L 24 84 L 24 83 L 23 83 L 23 82 L 22 82 L 22 81 L 20 81 L 20 80 L 19 80 L 19 79 L 18 79 L 18 78 L 17 78 L 17 77 L 16 77 L 16 76 L 15 76 L 15 75 L 14 75 L 14 74 L 13 74 L 13 73 L 12 73 L 12 72 L 11 72 L 11 71 L 10 71 L 10 70 L 9 70 L 9 69 L 8 69 L 8 68 L 6 68 L 6 67 L 5 67 L 5 66 L 4 66 L 4 65 L 3 65 L 3 63 L 2 63 L 2 58 L 3 58 L 3 56 L 4 56 L 4 55 L 5 55 L 5 54 L 6 54 L 6 53 L 7 53 L 7 52 L 8 52 L 8 51 L 9 51 L 9 50 L 10 50 L 10 49 L 12 49 L 12 48 L 13 48 L 13 47 L 14 47 L 14 46 L 15 46 L 15 45 L 17 45 L 17 44 L 22 44 L 22 45 L 24 45 L 24 46 L 25 46 L 25 47 L 26 47 L 26 48 L 28 48 L 28 49 L 29 49 L 29 50 L 30 50 L 30 51 L 32 51 L 32 52 L 33 52 L 33 53 L 34 53 L 34 54 L 36 54 L 36 55 L 37 55 L 37 56 L 38 56 L 38 57 L 40 57 L 40 58 L 41 58 L 41 59 L 42 59 L 42 60 L 44 60 L 44 61 L 45 61 L 45 62 L 46 62 L 46 63 L 47 63 L 47 64 L 49 64 L 49 65 L 50 65 L 50 66 L 51 66 L 51 67 L 53 67 L 53 68 L 54 68 L 54 67 L 56 67 L 56 66 L 57 66 L 57 65 L 58 65 L 58 64 L 59 64 L 59 63 L 60 63 L 60 62 L 61 62 L 61 61 L 62 61 L 62 60 L 63 60 L 63 59 L 64 59 L 64 58 L 65 58 L 65 57 L 67 57 L 67 56 L 68 56 L 68 55 L 69 55 L 69 54 L 70 54 L 70 53 L 71 53 L 71 52 L 72 52 L 72 51 L 73 51 L 73 50 L 74 50 L 74 49 L 75 49 L 75 48 L 77 48 L 77 47 L 78 47 L 78 46 L 79 46 L 79 45 L 80 45 L 80 44 L 81 44 L 81 43 L 82 43 L 82 42 L 83 42 L 83 41 L 84 41 L 84 40 L 85 40 L 85 39 L 86 39 L 86 38 L 88 38 L 88 37 L 89 37 L 89 36 L 90 36 L 90 35 L 91 35 L 91 34 L 92 34 L 92 33 L 93 33 L 93 32 L 94 32 L 94 31 L 95 31 L 95 30 L 96 30 L 96 29 L 97 29 L 97 28 L 98 28 L 98 27 L 99 27 L 99 26 L 101 26 L 101 25 L 102 25 L 102 24 L 103 24 L 103 23 L 104 23 L 104 22 L 105 22 L 105 21 L 106 21 L 106 20 L 107 20 L 107 19 L 108 19 L 108 18 L 109 18 L 109 17 L 110 17 L 110 16 L 112 16 L 112 15 L 113 15 L 113 14 L 114 14 L 114 13 L 115 13 L 115 12 L 116 12 L 116 11 L 117 11 L 117 10 L 118 10 L 118 9 L 119 9 L 119 8 L 120 8 L 120 7 L 121 7 L 121 6 L 123 6 L 123 5 L 124 5 L 124 4 L 125 4 L 125 3 L 129 3 Z M 133 51 L 132 51 L 132 52 L 131 52 L 131 53 L 129 53 L 129 54 L 128 54 L 128 55 L 127 55 L 127 56 L 125 56 L 125 57 L 124 57 L 124 58 L 123 58 L 123 59 L 121 59 L 121 60 L 120 60 L 120 61 L 119 61 L 119 62 L 117 62 L 117 63 L 116 63 L 116 64 L 115 64 L 115 65 L 113 65 L 113 66 L 112 66 L 112 67 L 111 67 L 111 68 L 109 68 L 109 69 L 108 69 L 108 70 L 107 70 L 107 71 L 105 71 L 105 72 L 104 72 L 104 73 L 103 73 L 103 74 L 102 74 L 102 75 L 100 75 L 100 76 L 99 76 L 99 77 L 98 77 L 98 78 L 96 78 L 96 79 L 95 79 L 95 80 L 94 80 L 94 81 L 92 81 L 92 82 L 91 82 L 91 83 L 90 83 L 90 84 L 88 84 L 88 85 L 87 85 L 87 86 L 86 86 L 86 87 L 84 87 L 84 88 L 83 88 L 83 89 L 82 89 L 82 90 L 83 90 L 83 91 L 84 91 L 84 92 L 86 92 L 86 93 L 87 93 L 87 94 L 88 94 L 88 95 L 90 95 L 90 96 L 91 96 L 91 97 L 92 97 L 92 98 L 94 98 L 94 99 L 95 99 L 95 100 L 96 100 L 96 101 L 98 101 L 98 102 L 99 102 L 99 103 L 100 103 L 100 104 L 102 104 L 102 105 L 103 105 L 103 106 L 104 106 L 104 107 L 105 107 L 105 108 L 107 108 L 107 109 L 108 109 L 108 110 L 109 110 L 109 111 L 111 111 L 111 112 L 112 112 L 112 113 L 113 113 L 113 114 L 115 114 L 115 115 L 116 115 L 116 116 L 117 116 L 117 117 L 119 117 L 119 118 L 120 118 L 120 119 L 121 119 L 121 120 L 123 120 L 123 121 L 124 121 L 124 122 L 125 122 L 125 123 L 127 123 L 127 124 L 128 124 L 128 125 L 129 125 L 129 126 L 131 126 L 131 127 L 132 127 L 132 128 L 133 128 Z"

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
        let contentWidth: CGFloat = 176
        let contentHeight: CGFloat = 175
        let contentCenterX: CGFloat = 90
        let contentCenterY: CGFloat = 89.5
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

#Preview {
    BoringHeader().environmentObject(BoringViewModel())
}
