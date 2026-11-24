//
//  SoftwareUpdater.swift
//  boringNotch
//
//  Created by Richard Kunkli on 09/08/2024.
//

import SwiftUI
import Sparkle

@MainActor
final class SoftwareUpdateFeed: NSObject, ObservableObject, SPUUpdaterDelegate {
    static let shared = SoftwareUpdateFeed()

    @Published private(set) var isRefreshing = false
    private var manualFeedURL: URL?

    func checkForUpdates(using updater: SPUUpdater) async {
        guard updater.canCheckForUpdates, !isRefreshing else { return }
        guard !updater.sessionInProgress, let feedURL = updater.feedURL else {
            updater.checkForUpdates()
            return
        }

        isRefreshing = true
        defer { isRefreshing = false }
        let refreshedURL = await Self.refreshedAppcastURL(for: feedURL)
        guard updater.canCheckForUpdates else { return }
        if !updater.sessionInProgress {
            manualFeedURL = refreshedURL
        }
        updater.checkForUpdates()
    }

    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        if updateCheck != .updates {
            manualFeedURL = nil
        }
    }

    func feedURLString(for updater: SPUUpdater) -> String? {
        manualFeedURL?.absoluteString
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        manualFeedURL = nil
    }

    static func refreshedAppcastURL(for feedURL: URL, session: URLSession = .shared) async -> URL? {
        let path = feedURL.pathComponents
        guard feedURL.scheme == "https", feedURL.host == "github.com", path.count == 7,
              path[3] == "raw", path.suffix(2) == ["updater", "appcast.xml"] else { return nil }

        let repository = path[1...2].joined(separator: "/")
        let branch = path[4]
        var reference = URLComponents()
        reference.scheme = "https"
        reference.host = "api.github.com"
        reference.path = "/repos/\(repository)/git/ref/heads/\(branch)"
        reference.queryItems = [URLQueryItem(name: "refresh", value: UUID().uuidString)]
        guard let referenceURL = reference.url else { return nil }

        var request = URLRequest(url: referenceURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 5)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")

        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let result = try? JSONDecoder().decode(GitHubReference.self, from: data),
              result.ref == "refs/heads/\(branch)" else { return nil }
        let commit = result.object.sha
        guard commit.count == 40, commit.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { return nil }
        return URL(string: "https://raw.githubusercontent.com/\(repository)/\(commit)/updater/appcast.xml")
    }

    private struct GitHubReference: Decodable {
        struct Object: Decodable {
            let sha: String
        }

        let ref: String
        let object: Object
    }
}

final class CheckForUpdatesViewModel: ObservableObject {
    @Published var canCheckForUpdates = false

    init(updater: SPUUpdater) {
        updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }
}

struct CheckForUpdatesView: View {
    @ObservedObject private var checkForUpdatesViewModel: CheckForUpdatesViewModel
    @ObservedObject private var updateFeed = SoftwareUpdateFeed.shared
    private let updater: SPUUpdater
    
    init(updater: SPUUpdater) {
        self.updater = updater
        
        // Create our view model for our CheckForUpdatesView
        self.checkForUpdatesViewModel = CheckForUpdatesViewModel(updater: updater)
    }
    
    var body: some View {
        Button(updateFeed.isRefreshing ? "正在检查更新…" : "检查更新…") {
            Task { await updateFeed.checkForUpdates(using: updater) }
        }
        .disabled(updateFeed.isRefreshing || !checkForUpdatesViewModel.canCheckForUpdates)
    }
}

struct UpdaterSettingsView: View {
    private let updater: SPUUpdater
    
    @State private var automaticallyChecksForUpdates: Bool
    @State private var automaticallyDownloadsUpdates: Bool
    
    init(updater: SPUUpdater) {
        self.updater = updater
        self.automaticallyChecksForUpdates = updater.automaticallyChecksForUpdates
        self.automaticallyDownloadsUpdates = updater.automaticallyDownloadsUpdates
    }
    
    var body: some View {
        Section {
            Toggle("自动检查更新", isOn: $automaticallyChecksForUpdates)
                .onChange(of: automaticallyChecksForUpdates) { _, newValue in
                    updater.automaticallyChecksForUpdates = newValue
                }
            
            Toggle("自动下载更新", isOn: $automaticallyDownloadsUpdates)
                .disabled(!automaticallyChecksForUpdates)
                .onChange(of: automaticallyDownloadsUpdates) { _, newValue in
                    updater.automaticallyDownloadsUpdates = newValue
                }
        } header: {
            HStack {
                Text("软件更新")
            }
        }
    }
}
