import AppKit
import Defaults

@MainActor
final class LyricsResolver {
    struct Result: Sendable {
        enum Source: Sendable {
            case appleMusicOfficial
            case desktopPlayer
            case web
        }

        let entry: DesktopLyricsCache.Entry
        let source: Source
        let syncedLines: [LyricsDisplayText.SyncedLine]

        init(entry: DesktopLyricsCache.Entry, source: Source) {
            self.entry = entry
            self.source = source
            syncedLines = entry.syncedLines
        }
    }

    struct Readers: Sendable {
        let desktop: @Sendable (PlayerLyricsCatalog.Recording, PlayerLyricsCatalog.Source) async -> DesktopLyricsCache.Entry?
        let appleCache: @Sendable (PlayerLyricsCatalog.Recording) async -> DesktopLyricsCache.Entry?
        let appleAccessibility: @Sendable (PlayerLyricsCatalog.Recording) async -> DesktopLyricsCache.Entry?
        let appleTrack: @Sendable () async -> String?
        let request: LyricsHTTPRequest

        static let live = Readers(
            desktop: { await DesktopPlayerLyrics.read($0, source: $1) },
            appleCache: { recording in
                guard let bookmark = Defaults[.appleMusicLyricsCacheBookmark],
                      let timeline = await AppleMusicCachedLyrics.read(
                        bookmark: bookmark, title: recording.title, artist: recording.artist,
                        album: recording.album, duration: recording.duration
                      ) else { return nil }
                return .init(text: timeline.lines.map(\.text).joined(separator: "\n"),
                             lines: timeline.lines.map { .init(time: $0.time, text: $0.text) },
                             characterTimings: timeline.characterTimings)
            },
            appleAccessibility: { recording in
                guard let music = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music").first,
                      let lyrics = await AppleMusicAccessibilityLyrics.read(
                        pid: music.processIdentifier, title: recording.title, duration: recording.duration
                      ) else { return nil }
                return .init(text: lyrics.text, lines: lyrics.syncedLines.map { .init(time: $0.time, text: $0.text) },
                             characterTimings: [])
            },
            appleTrack: { await appleTrackLyrics() },
            request: { try await URLSession.shared.data(for: $0) }
        )

        private static func appleTrackLyrics() async -> String? {
            guard !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music").isEmpty else { return nil }
            let script = """
            tell application "Music"
                if it is running then
                    if player state is playing or player state is paused then
                        try
                            set l to lyrics of current track
                            if l is missing value then
                                return ""
                            else
                                return l
                            end if
                        on error
                            return ""
                        end try
                    end if
                end if
                return ""
            end tell
            """
            let result = try? await AppleScriptHelper.execute(script)
            return result?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    struct Timing: Sendable {
        let desktopPollOffsets: [Duration]
        let desktopFallbackDelay: Duration
        let retryDelay: Duration

        static let live = Timing(
            desktopPollOffsets: [.milliseconds(300), .milliseconds(850), .milliseconds(1600), .seconds(3), .seconds(5), .seconds(8)],
            desktopFallbackDelay: .milliseconds(400),
            retryDelay: .milliseconds(450)
        )
    }

    private struct TrackKey: Hashable, Sendable {
        let title: String
        let artist: String
        let album: String
        let bundleIdentifier: String
        let songID: String?
        let desktopCacheKey: DesktopLyricsCache.Key?

        init(_ state: PlaybackState) {
            title = normalizedLyricsQuery(state.title).lowercased()
            artist = normalizedLyricsQuery(state.artist).lowercased()
            album = normalizedLyricsQuery(state.album).lowercased()
            bundleIdentifier = state.bundleIdentifier
            songID = state.lyricsSongID
            desktopCacheKey = DesktopLyricsCache.Key(
                bundleIdentifier: state.bundleIdentifier, title: state.title, artist: state.artist,
                album: state.album, duration: state.duration, songID: state.lyricsSongID
            )
        }
    }

    private struct Lookup: Sendable {
        let id = UUID()
        let key: TrackKey
        let recording: PlayerLyricsCatalog.Recording
        let desktopSource: PlayerLyricsCatalog.Source?

        init(_ state: PlaybackState) {
            key = TrackKey(state)
            recording = .init(title: state.title, artist: state.artist, album: state.album,
                              duration: state.duration, songID: state.lyricsSongID)
            desktopSource = PlayerLyricsCatalog.Source(bundleIdentifier: state.bundleIdentifier)
        }
    }

    private enum DesktopLookupResult: Sendable {
        case local(DesktopLyricsCache.Entry?)
        case fallbackFinished
    }

    private let cache: DesktopLyricsCache
    private let readers: Readers
    private let timing: Timing
    private let catalog: PlayerLyricsCatalog
    private let web: WebLyrics
    private let publish: @MainActor @Sendable (Result?) -> Void

    private var playback: PlaybackState?
    private var enabled = false
    private var active: Lookup?
    private var completedKey: TrackKey?
    private var task: Task<Void, Never>?
    private var result: Result?

    nonisolated init(cache: DesktopLyricsCache = .shared, readers: Readers = .live, timing: Timing = .live,
                     publish: @escaping @MainActor @Sendable (Result?) -> Void) {
        self.cache = cache
        self.readers = readers
        self.timing = timing
        self.publish = publish
        catalog = PlayerLyricsCatalog(request: readers.request)
        web = WebLyrics(request: readers.request)
    }

    deinit {
        task?.cancel()
    }

    @discardableResult
    func updatePlayback(_ state: PlaybackState, lyricsEnabled: Bool) -> Task<Void, Never>? {
        let previous = playback
        let enabledChanged = enabled != lyricsEnabled
        playback = state
        enabled = lyricsEnabled

        guard lyricsEnabled, !state.title.isEmpty else {
            reset()
            return nil
        }

        let metadataChanged = state.title != previous?.title || state.artist != previous?.artist
            || state.album != previous?.album || state.bundleIdentifier != previous?.bundleIdentifier
        let artworkChanged = state.artwork != nil && state.artwork != previous?.artwork
        let desktopChanged = PlayerLyricsCatalog.Source(bundleIdentifier: state.bundleIdentifier) != nil
            && (state.duration != previous?.duration || state.lyricsSongID != previous?.lyricsSongID
                || (state.isPlaying && previous?.isPlaying != true && result == nil))
        guard enabledChanged || metadataChanged || artworkChanged || desktopChanged else { return nil }
        return start(state, force: enabledChanged)
    }

    @discardableResult
    func refresh(lyricsEnabled: Bool) -> Task<Void, Never>? {
        enabled = lyricsEnabled
        guard lyricsEnabled, let playback, !playback.title.isEmpty else {
            reset()
            return nil
        }
        return start(playback, force: true)
    }

    func stop() {
        playback = nil
        enabled = false
        reset()
    }

    private func reset() {
        task?.cancel()
        task = nil
        active = nil
        completedKey = nil
        if result != nil {
            result = nil
            publish(nil)
        }
    }

    private func start(_ state: PlaybackState, force: Bool) -> Task<Void, Never>? {
        let lookup = Lookup(state)
        guard force || (active?.key != lookup.key && completedKey != lookup.key) else { return nil }
        reset()
        active = lookup
        let task = Task { [weak self] in
            guard let self else { return }
            await resolve(lookup)
            guard active?.id == lookup.id else { return }
            completedKey = !Task.isCancelled && result != nil ? lookup.key : nil
            active = nil
            self.task = nil
        }
        self.task = task
        return task
    }

    private func isCurrent(_ lookup: Lookup) -> Bool {
        active?.id == lookup.id && !Task.isCancelled
    }

    private func offer(_ entry: DesktopLyricsCache.Entry, source: Result.Source, for lookup: Lookup) -> Bool {
        guard isCurrent(lookup), entry.quality > 0, entry.quality >= (result?.entry.quality ?? 0) else { return false }
        let result = Result(entry: entry, source: source)
        self.result = result
        publish(result)
        return true
    }

    private func store(_ entry: DesktopLyricsCache.Entry, for lookup: Lookup) async {
        guard isCurrent(lookup), let key = lookup.key.desktopCacheKey else { return }
        await cache.store(entry, for: key)
    }

    private func resolve(_ lookup: Lookup) async {
        guard isCurrent(lookup) else { return }
        if let key = lookup.key.desktopCacheKey, let entry = await cache.load(for: key) {
            _ = offer(entry, source: .web, for: lookup)
            return
        }

        guard isCurrent(lookup) else { return }
        if let source = lookup.desktopSource, lookup.recording.canMatchLocalLyrics {
            await resolveDesktop(lookup, source: source)
        } else {
            await fetchWithRetries(lookup)
        }
    }

    private func resolveDesktop(_ lookup: Lookup, source: PlayerLyricsCatalog.Source) async {
        let reader = readers.desktop
        let recording = lookup.recording
        if let entry = await reader(recording, source), offer(entry, source: .desktopPlayer, for: lookup) {
            await store(entry, for: lookup)
            return
        }

        guard isCurrent(lookup) else { return }
        let timing = self.timing
        await withTaskGroup(of: DesktopLookupResult.self) { group in
            group.addTask {
                let clock = ContinuousClock()
                let started = clock.now
                for offset in timing.desktopPollOffsets {
                    do {
                        try await clock.sleep(until: started.advanced(by: offset))
                    } catch {
                        return .local(nil)
                    }
                    guard !Task.isCancelled else { return .local(nil) }
                    if let entry = await reader(recording, source) { return .local(entry) }
                }
                return .local(nil)
            }
            group.addTask {
                do {
                    try await Task.sleep(for: timing.desktopFallbackDelay)
                    await self.fetchWithRetries(lookup)
                } catch { }
                return .fallbackFinished
            }

            for await completion in group {
                guard isCurrent(lookup) else { return }
                if case .local(let entry?) = completion, offer(entry, source: .desktopPlayer, for: lookup) {
                    group.cancelAll()
                    await store(entry, for: lookup)
                    return
                }
            }
        }
    }

    private func fetchWithRetries(_ lookup: Lookup) async {
        let maxAttempts = 3
        for attempt in 0..<maxAttempts {
            guard isCurrent(lookup) else { return }
            if await fetchOnce(lookup) { return }
            if attempt + 1 < maxAttempts {
                try? await Task.sleep(for: timing.retryDelay)
            }
        }
    }

    private func fetchOnce(_ lookup: Lookup) async -> Bool {
        if lookup.key.bundleIdentifier.contains("com.apple.Music") {
            return await fetchAppleLyrics(lookup)
        }
        if let source = lookup.desktopSource {
            return await fetchDesktopFallback(lookup, source: source)
        }
        return await fetchWeb(lookup)
    }

    private func fetchAppleLyrics(_ lookup: Lookup) async -> Bool {
        let recording = lookup.recording
        if let entry = await readers.appleCache(recording), offer(entry, source: .appleMusicOfficial, for: lookup) {
            if entry.quality == 2 {
                _ = await fetchWeb(lookup, matching: .timeline(entry.syncedLines))
            }
            return true
        }

        guard isCurrent(lookup) else { return false }
        let accessible = await readers.appleAccessibility(recording)
        if let accessible, !accessible.lines.isEmpty, offer(accessible, source: .appleMusicOfficial, for: lookup) {
            return true
        }
        guard isCurrent(lookup) else { return false }
        if let text = await readers.appleTrack() {
            let entry = DesktopLyricsCache.Entry(text: text, lines: [], characterTimings: [])
            if offer(entry, source: .appleMusicOfficial, for: lookup) { return true }
        }
        if let accessible, offer(accessible, source: .appleMusicOfficial, for: lookup) {
            _ = await fetchWeb(lookup, matching: .lyrics(accessible.text))
            return true
        }
        return await fetchWeb(lookup, matching: .recording)
    }

    private func fetchWeb(_ lookup: Lookup, matching reference: WebLyrics.Reference? = nil) async -> Bool {
        guard isCurrent(lookup), let entry = await web.find(lookup.recording, matching: reference),
              offer(entry, source: .web, for: lookup) else { return false }
        await store(entry, for: lookup)
        return true
    }

    private func fetchDesktopFallback(_ lookup: Lookup, source: PlayerLyricsCatalog.Source) async -> Bool {
        let recording = lookup.recording
        if let id = recording.songID, let entry = await desktopLyricsByID(id, recording: recording, source: source),
           offer(entry, source: .web, for: lookup) {
            await store(entry, for: lookup)
            return true
        }

        for provider in [source, source.alternate] {
            guard isCurrent(lookup) else { return false }
            let songs = await catalog.search(recording, in: provider, allowPreview: source == .netease,
                                             allowQQAliases: source == .qq)
            for song in songs.prefix(2) {
                guard isCurrent(lookup) else { return false }
                if provider == .qq {
                    if await fetchQQDesktopLyrics(song, for: lookup) { return true }
                } else if let candidate = await Self.catalogEntry(catalog, song: song, source: provider) {
                    let isPreview = source == .netease && recording.matchesNetEasePreview(song)
                    let entry = isPreview
                        ? DesktopLyricsCache.Entry(text: candidate.text, lines: [], characterTimings: [])
                        : candidate
                    if offer(entry, source: .web, for: lookup) {
                        await store(entry, for: lookup)
                        return true
                    }
                }
            }
        }
        return await fetchWeb(lookup, matching: .desktopRecording(recording))
    }

    private func desktopLyricsByID(_ id: String, recording: PlayerLyricsCatalog.Recording,
                                   source: PlayerLyricsCatalog.Source) async -> DesktopLyricsCache.Entry? {
        switch source {
        case .qq:
            guard let number = Int(id) else { return nil }
            return await catalog.qqWordLyrics(id: number)
        case .netease:
            guard let lyric = await catalog.netEaseLyric(id: id), let entry = Self.catalogEntry(lyric) else { return nil }
            if PlayerLyricsCatalog.Recording.isPreviewDuration(recording.duration) {
                return .init(text: entry.text, lines: [], characterTimings: [])
            }
            return entry
        }
    }

    private nonisolated static func catalogEntry(
        _ catalog: PlayerLyricsCatalog, song: PlayerLyricsCatalog.Song, source: PlayerLyricsCatalog.Source
    ) async -> DesktopLyricsCache.Entry? {
        guard let lyric = await catalog.lyric(for: song, in: source) else { return nil }
        return catalogEntry(lyric)
    }

    private nonisolated static func catalogEntry(_ lyric: PlayerLyricsCatalog.Lyric) -> DesktopLyricsCache.Entry? {
        if let words = lyric.words, let entry = DesktopPlayerLyrics.netEaseTimeline(words) { return entry }
        return DesktopPlayerLyrics.lrcTimeline(lyric.lines)
    }

    private func fetchQQDesktopLyrics(_ song: PlayerLyricsCatalog.Song, for lookup: Lookup) async -> Bool {
        let catalog = self.catalog
        let web = self.web
        return await withTaskGroup(of: DesktopLyricsCache.Entry?.self) { group in
            group.addTask { await Self.catalogEntry(catalog, song: song, source: .qq) }
            group.addTask {
                if let primary = await catalog.qqWordLyrics(for: song) { return primary }
                guard !Task.isCancelled else { return nil }
                return await web.qqLyrics(forSongID: song.id)
            }
            var found = false
            for await entry in group {
                guard isCurrent(lookup) else { return false }
                guard let entry, offer(entry, source: .web, for: lookup) else { continue }
                found = true
                let hasCharacterTiming = entry.characterTimings.contains { !$0.isEmpty }
                if hasCharacterTiming { group.cancelAll() }
                await store(entry, for: lookup)
                if hasCharacterTiming { return true }
            }
            return found
        }
    }
}
