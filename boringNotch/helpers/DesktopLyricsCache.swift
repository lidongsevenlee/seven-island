import CryptoKit
import Foundation

actor DesktopLyricsCache {
    struct Key: Encodable, Hashable, Sendable {
        private let player: String
        private let title: String
        private let artist: String
        private let album: String
        private let duration: Int
        private let isPreview: Bool
        private let songID: String?

        init?(bundleIdentifier: String?, title: String, artist: String, album: String, duration: Double, songID: String? = nil) {
            guard let bundleIdentifier, let source = PlayerLyricsCatalog.Source(bundleIdentifier: bundleIdentifier),
                  let seconds = Int(exactly: duration.rounded()), seconds > 0 else { return nil }
            self.player = bundleIdentifier.lowercased()
            self.songID = songID
            self.title = songID == nil ? Self.normalized(title) : ""
            self.artist = songID == nil ? Self.normalized(artist) : ""
            self.album = songID == nil ? Self.normalized(album) : ""
            self.duration = seconds
            self.isPreview = source == .netease && PlayerLyricsCatalog.Recording.isPreviewDuration(duration)
            guard songID != nil || (!self.title.isEmpty && !self.artist.isEmpty) else { return nil }
        }

        private static func normalized(_ text: String) -> String {
            text.precomposedStringWithCanonicalMapping
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
        }
    }

    struct Entry: Codable, Sendable {
        struct Line: Codable, Sendable {
            let time: Double
            let text: String
        }

        let text: String
        let lines: [Line]
        let characterTimings: [[LyricsDisplayText.CharacterTiming]]

        var quality: Int {
            if characterTimings.contains(where: { !$0.isEmpty }) { return 3 }
            if !lines.isEmpty { return 2 }
            return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0 : 1
        }
    }

    static let shared = DesktopLyricsCache(directory: defaultDirectory())

    private let directory: URL

    init(directory: URL) {
        self.directory = directory
    }

    func load(for key: Key) -> Entry? {
        guard let url = fileURL(for: key), let entry = read(from: url), entry.quality > 0 else { return nil }
        return entry
    }

    func store(_ entry: Entry, for key: Key) {
        guard entry.quality > 0, let url = fileURL(for: key),
              (read(from: url)?.quality ?? 0) <= entry.quality else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(entry).write(to: url, options: .atomic)
        } catch {
            NSLog("Could not persist desktop music lyrics: %@", error.localizedDescription)
        }
    }

    private func read(from url: URL) -> Entry? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Entry.self, from: data)
    }

    private func fileURL(for key: Key) -> URL? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(key) else { return nil }
        let name = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(name).appendingPathExtension("json")
    }

    private static func defaultDirectory() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return appSupport
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.local.seven-island", isDirectory: true)
            .appendingPathComponent("Lyrics", isDirectory: true)
    }
}
