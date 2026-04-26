import SwiftUI

struct VSCodeProjectsView: View {
    @ObservedObject private var service = VSCodeRecentProjectsService.shared
    @EnvironmentObject private var vm: BoringViewModel
    @AppStorage("sevenIslandShowMissingVSCodeProjects") private var showMissingProjects = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // HStack {
            //     Spacer()
            //     HoverButton(icon: "arrow.clockwise", iconColor: .gray, scale: .medium) {
            //         service.refresh(includeMissing: showMissingProjects)
            //     }
            //     .help("Refresh recent projects")
            // }
            // .frame(height: 18)

            if service.projects.isEmpty {
                Spacer(minLength: 8)
                EmptyStateView(message: "No recent local folders")
                    .frame(maxWidth: .infinity)
                Spacer(minLength: 8)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(service.projects) { project in
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
                .frame(maxHeight: 144)
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
        .onAppear {
            service.refresh(includeMissing: showMissingProjects)
        }
        .onChange(of: showMissingProjects) {
            service.refresh(includeMissing: showMissingProjects)
        }
        .preferredColorScheme(.dark)
    }
}

private struct VSCodeProjectRow: View {
    let project: VSCodeProjectItem

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
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}
