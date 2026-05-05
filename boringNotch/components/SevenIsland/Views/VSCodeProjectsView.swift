import Defaults
import SwiftUI

struct VSCodeProjectsView: View {
    @ObservedObject private var service = VSCodeRecentProjectsService.shared
    @EnvironmentObject private var vm: BoringViewModel
    @Default(.vscodeProjectsDirectory) private var vscodeProjectsDirectory
    @State private var searchText = ""
    @FocusState private var isSearchFocused: Bool

    private var emptyMessage: String {
        if vscodeProjectsDirectory.isEmpty {
            return "No folders in ~/Projects"
        }
        return "No folders in \(vscodeProjectsDirectory)"
    }

    private var filteredProjects: [VSCodeProjectItem] {
        guard !searchText.trimmingCharacters(in: .whitespaces).isEmpty else {
            return service.projects
        }
        let query = searchText.lowercased()
        return service.projects
            .filter { $0.matches(query: query) }
            .sorted { lhs, rhs in
                let lhPrefix = lhs.name.lowercased().hasPrefix(query)
                let rhPrefix = rhs.name.lowercased().hasPrefix(query)
                if lhPrefix != rhPrefix { return lhPrefix }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 12))
                TextField("Search projects...", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(.white)
                    .focused($isSearchFocused)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))

            if service.projects.isEmpty {
                Spacer(minLength: 8)
                EmptyStateView(message: emptyMessage)
                    .frame(maxWidth: .infinity)
                Spacer(minLength: 8)
            } else if filteredProjects.isEmpty {
                Spacer(minLength: 8)
                EmptyStateView(message: "No matching projects")
                    .frame(maxWidth: .infinity)
                Spacer(minLength: 8)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(filteredProjects) { project in
                            Button {
                                service.open(project)
                                withAnimation(.smooth(duration: 0.2)) {
                                    vm.close()
                                }
                            } label: {
                                VSCodeProjectRow(project: project)
                            }
                            .buttonStyle(.plain)
                            .help("Open in a new VS Code window")
                        }
                    }
                }
                .frame(maxHeight: 300)
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
        .onAppear {
            service.refresh()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                isSearchFocused = true
            }
        }
        .preferredColorScheme(.dark)
    }
}

private struct VSCodeProjectRow: View {
    let project: VSCodeProjectItem

    @State private var isHovering = false

    private var iconName: String {
        project.exists ? "folder" : "folder.badge.questionmark"
    }

    private var iconColor: Color {
        project.exists ? .secondary : .orange
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: iconName)
                .foregroundStyle(iconColor)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(project.name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(project.detail)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            (isHovering ? Color.white.opacity(0.15) : Color.white.opacity(0.08)),
            in: RoundedRectangle(cornerRadius: 8)
        )
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovering = hovering
            }
            hovering ? NSCursor.pointingHand.push() : NSCursor.pop()
        }
    }
}
