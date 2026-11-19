//
//  MusicManager.swift
//  boringNotch
//
//  Created by Harsh Vardhan  Goswami  on 03/08/24.
//
import AppKit
import Combine
import Defaults
import SwiftUI

let defaultImage: NSImage = .init(
    systemSymbolName: "heart.fill",
    accessibilityDescription: "Album Art"
)!

class MusicManager: ObservableObject {
    typealias DesktopLyricsReader = @Sendable (PlayerLyricsCatalog.Recording, PlayerLyricsCatalog.Source) async -> DesktopLyricsCache.Entry?

    enum LyricsSource: Equatable {
        case none
        case appleMusicOfficial
        case desktopPlayer
        case web
    }

    // MARK: - Properties
    static let shared = MusicManager()
    private var cancellables = Set<AnyCancellable>()
    private var controllerCancellables = Set<AnyCancellable>()
    private var debounceIdleTask: Task<Void, Never>?

    // Helper to check if macOS has removed support for NowPlayingController
    public private(set) var isNowPlayingDeprecated: Bool = false
    private let mediaChecker = MediaChecker()

    // Active controller
    private var activeController: (any MediaControllerProtocol)?

    // Published properties for UI
    @Published var songTitle: String = "I'm Handsome"
    @Published var artistName: String = "Me"
    @Published var albumArt: NSImage = defaultImage
    @Published var isPlaying = false
    @Published var album: String = "Self Love"
    @Published var isPlayerIdle: Bool = true
    @Published var animations: BoringAnimations = .init()
    @Published var avgColor: NSColor = .white
    @Published var bundleIdentifier: String? = nil
    @Published var songDuration: TimeInterval = 0
    @Published var elapsedTime: TimeInterval = 0
    @Published var timestampDate: Date = .init()
    @Published var playbackRate: Double = 1
    @Published var isShuffled: Bool = false
    @Published var repeatMode: RepeatMode = .off
    @Published var volume: Double = 0.5
    @Published var volumeControlSupported: Bool = true
    @ObservedObject var coordinator = BoringViewCoordinator.shared
    @Published var usingAppIconForArtwork: Bool = false
    @Published var currentLyrics: String = ""
    @Published var syncedLyrics: [(time: Double, text: String)] = []
    @Published var syncedLyricCharacterTimings: [[LyricsDisplayText.CharacterTiming]] = []
    @Published var lyricsSource: LyricsSource = .none
    @Published var canFavoriteTrack: Bool = false
    @Published var isFavoriteTrack: Bool = false

    private var artworkData: Data? = nil
    private struct LyricsTrackKey: Hashable {
        let title: String
        let artist: String
        let album: String
        let bundleIdentifier: String?
        let desktopCacheKey: DesktopLyricsCache.Key?
    }

    var hasLyrics: Bool {
        !syncedLyrics.isEmpty || !currentLyrics.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private let desktopLyricsCache: DesktopLyricsCache
    private let readDesktopLyrics: DesktopLyricsReader
    private let maxLyricsFetchAttempts = 3
    private static let desktopLyricRetryOffsets: [Duration] = [
        .milliseconds(300), .milliseconds(850), .milliseconds(1600), .seconds(3), .seconds(5), .seconds(8),
    ]
    private static let desktopWebFallbackDelay: Duration = .milliseconds(400)
    private var completedLyricsFetchKey: LyricsTrackKey?
    private var activeLyricsFetchKey: LyricsTrackKey?
    private var lyricsFetchTask: Task<Void, Never>?

    private enum DesktopLyricLookup: Sendable {
        case local(DesktopLyricsCache.Entry?)
        case web(Bool)
    }

    private enum WebLyricsReference {
        case timeline([LyricsDisplayText.SyncedLine])
        case lyrics(String)
        case recording
        case desktopRecording(PlayerLyricsCatalog.Recording)
    }

    private struct WebLyricsCandidate {
        let plain: String
        let synced: String
        let parsed: (lines: [LyricsDisplayText.SyncedLine], characterTimes: [[Double]])
        /// Duration reported by LRCLIB for this entry (seconds). Used to rank candidates
        /// when multiple results match the same title/artist — the entry whose duration
        /// is closest to the actual track duration wins.
        let lrclibDuration: Double
        let recording: (title: String, artist: String, album: String)?

        init(plain: String, synced: String, parsed: (lines: [LyricsDisplayText.SyncedLine], characterTimes: [[Double]]), lrclibDuration: Double = 0,
             recording: (title: String, artist: String, album: String)? = nil) {
            self.plain = plain
            self.synced = synced
            self.parsed = parsed
            self.lrclibDuration = lrclibDuration
            self.recording = recording
        }

        var hasText: Bool {
            !plain.isEmpty || !synced.isEmpty || !parsed.lines.isEmpty
        }

        var hasCharacterTiming: Bool {
            parsed.characterTimes.contains { !$0.isEmpty }
        }

        var displayLyrics: String {
            if !plain.isEmpty { return plain }
            if !synced.isEmpty { return synced }
            return parsed.lines.map(\.text).joined(separator: "\n")
        }

        var entry: DesktopLyricsCache.Entry {
            .init(text: displayLyrics, lines: parsed.lines.map { .init(time: $0.time, text: $0.text) },
                  characterTimings: hasCharacterTiming ? parsed.characterTimes.map { $0.map { .init(start: $0) } } : [])
        }
    }

    // Track the last processed media item independently from artwork updates.
    private var lastTrackTitle: String = "I'm Handsome"
    private var lastTrackArtist: String = "Me"
    private var lastTrackAlbum: String = "Self Love"
    private var lastTrackBundleIdentifier: String? = nil
    private var lyricsSongID: String?

    @Published var isFlipping: Bool = false
    private var flipWorkItem: DispatchWorkItem?

    @Published var isTransitioning: Bool = false
    private var transitionWorkItem: DispatchWorkItem?

    // MARK: - Initialization
    init(desktopLyricsCache: DesktopLyricsCache = .shared,
         readDesktopLyrics: @escaping DesktopLyricsReader = { await DesktopPlayerLyrics.read($0, source: $1) }) {
        self.desktopLyricsCache = desktopLyricsCache
        self.readDesktopLyrics = readDesktopLyrics
        // Listen for changes to the default controller preference
        NotificationCenter.default.publisher(for: Notification.Name.mediaControllerChanged)
            .sink { [weak self] _ in
                self?.setActiveControllerBasedOnPreference()
            }
            .store(in: &cancellables)

        // Initialize deprecation check asynchronously
        Task { @MainActor in
            do {
                self.isNowPlayingDeprecated = try await self.mediaChecker.checkDeprecationStatus()
                print("Deprecation check completed: \(self.isNowPlayingDeprecated)")
            } catch {
                print("Failed to check deprecation status: \(error). Defaulting to false.")
                self.isNowPlayingDeprecated = false
            }
            
            // Initialize the active controller after deprecation check
            self.setActiveControllerBasedOnPreference()
        }
    }

    deinit {
        destroy()
    }
    
    public func destroy() {
        debounceIdleTask?.cancel()
        lyricsFetchTask?.cancel()
        cancellables.removeAll()
        controllerCancellables.removeAll()
        flipWorkItem?.cancel()
        transitionWorkItem?.cancel()

        // Release active controller
        activeController = nil
    }

    // MARK: - Setup Methods
    private func createController(for type: MediaControllerType) -> (any MediaControllerProtocol)? {
        // Cleanup previous controller
        if activeController != nil {
            controllerCancellables.removeAll()
            activeController = nil
        }

        let newController: (any MediaControllerProtocol)?

        switch type {
        case .nowPlaying, .neteaseMusic, .qqMusic:
            // Only create NowPlayingController if not deprecated on this macOS version
            if !self.isNowPlayingDeprecated {
                newController = NowPlayingController(sourceBundleIdentifier: type.systemPlayerBundleIdentifier)
            } else {
                return nil
            }
        case .appleMusic:
            newController = AppleMusicController()
        case .spotify:
            newController = SpotifyController()
        case .youtubeMusic:
            newController = YouTubeMusicController()
        }

        // Set up state observation for the new controller
        if let controller = newController {
            controller.playbackStatePublisher
                .receive(on: DispatchQueue.main)
                .sink { [weak self] state in
                    guard let self = self,
                          self.activeController === controller else { return }
                    self.updateFromPlaybackState(state)
                }
                .store(in: &controllerCancellables)
        }

        return newController
    }

    private func setActiveControllerBasedOnPreference() {
        let preferredType = Defaults[.mediaController]
        print("Preferred Media Controller: \(preferredType)")

        // If NowPlaying is deprecated but that's the preference, use Apple Music instead
        let controllerType = (self.isNowPlayingDeprecated && preferredType.usesSystemPlayback)
            ? .appleMusic
            : preferredType

        if let controller = createController(for: controllerType) {
            setActiveController(controller)
        } else if controllerType != .appleMusic, let fallbackController = createController(for: .appleMusic) {
            // Fallback to Apple Music if preferred controller couldn't be created
            setActiveController(fallbackController)
        }
    }

    private func setActiveController(_ controller: any MediaControllerProtocol) {
        // Cancel any existing flip animation
        flipWorkItem?.cancel()

        // Set new active controller
        activeController = controller
        
        self.canFavoriteTrack = controller.supportsFavorite

        // Get current state from active controller
        forceUpdate()
    }

    // MARK: - Update Methods
    @MainActor
    private func updateFromPlaybackState(_ state: PlaybackState) {
        let playbackStarted = state.isPlaying && !isPlaying
        // Check for playback state changes (playing/paused)
        if state.isPlaying != self.isPlaying {
            NSLog("Playback state changed: \(state.isPlaying ? "Playing" : "Paused")")
            withAnimation(.smooth) {
                self.isPlaying = state.isPlaying
                self.updateIdleState(state: state.isPlaying)
            }

            if state.isPlaying && !state.title.isEmpty && !state.artist.isEmpty {
                self.updateSneakPeek()
            }
        }

        // Track metadata changes independently from artwork delivery timing.
        let titleChanged = state.title != self.lastTrackTitle
        let artistChanged = state.artist != self.lastTrackArtist
        let albumChanged = state.album != self.lastTrackAlbum
        let bundleChanged = state.bundleIdentifier != self.lastTrackBundleIdentifier

        // Check for artwork changes
        let artworkChanged = state.artwork != nil && state.artwork != self.artworkData
        let metadataChanged = titleChanged || artistChanged || albumChanged || bundleChanged
        let hasContentChange = metadataChanged || artworkChanged

        // Handle artwork and visual transitions for changed content
        if hasContentChange {
            self.triggerFlipAnimation()

            if artworkChanged, let artwork = state.artwork {
                self.updateArtwork(artwork)
            } else if metadataChanged && (albumChanged || bundleChanged) {
                // Avoid showing the previous cover with the next track's metadata while
                // Apple Music is still catching up with fresh artwork for the new item.
                if let appIconImage = AppIconAsNSImage(for: state.bundleIdentifier) {
                    self.usingAppIconForArtwork = true
                    self.updateAlbumArt(newAlbumArt: appIconImage)
                } else {
                    self.usingAppIconForArtwork = false
                    self.updateAlbumArt(newAlbumArt: defaultImage)
                }
            } else if state.artwork == nil {
                // Try to use app icon if no artwork but track changed
                if let appIconImage = AppIconAsNSImage(for: state.bundleIdentifier) {
                    self.usingAppIconForArtwork = true
                    self.updateAlbumArt(newAlbumArt: appIconImage)
                }
            }
            self.artworkData = state.artwork

            self.lastTrackTitle = state.title
            self.lastTrackArtist = state.artist
            self.lastTrackAlbum = state.album
            self.lastTrackBundleIdentifier = state.bundleIdentifier

            // Only update sneak peek if there's actual content and something changed
            if !state.title.isEmpty && !state.artist.isEmpty && state.isPlaying {
                self.updateSneakPeek()
            }
        }

        let timeChanged = state.currentTime != self.elapsedTime
        let durationChanged = state.duration != self.songDuration
        let songIDChanged = state.lyricsSongID != lyricsSongID
        lyricsSongID = state.lyricsSongID
        let desktopLyricsChanged = PlayerLyricsCatalog.Source(bundleIdentifier: state.bundleIdentifier) != nil &&
            (durationChanged || songIDChanged || (playbackStarted && !hasLyrics))
        if hasContentChange || desktopLyricsChanged {
            fetchLyricsIfAvailable(bundleIdentifier: state.bundleIdentifier, title: state.title,
                                   artist: state.artist, album: state.album, duration: state.duration, songID: state.lyricsSongID)
        }
        let playbackRateChanged = state.playbackRate != self.playbackRate
        let shuffleChanged = state.isShuffled != self.isShuffled
        let repeatModeChanged = state.repeatMode != self.repeatMode
        let volumeChanged = state.volume != self.volume
        
        if state.title != self.songTitle {
            self.songTitle = state.title
        }

        if state.artist != self.artistName {
            self.artistName = state.artist
        }

        if state.album != self.album {
            self.album = state.album
        }

        if timeChanged {
            self.elapsedTime = state.currentTime
        }

        if durationChanged {
            self.songDuration = state.duration
        }

        if playbackRateChanged {
            self.playbackRate = state.playbackRate
        }
        
        if shuffleChanged {
            self.isShuffled = state.isShuffled
        }

        if state.bundleIdentifier != self.bundleIdentifier {
            self.bundleIdentifier = state.bundleIdentifier
            // Update volume control support from active controller
            self.volumeControlSupported = activeController?.supportsVolumeControl ?? false
        }

        if repeatModeChanged {
            self.repeatMode = state.repeatMode
        }
        if state.isFavorite != self.isFavoriteTrack {
            self.isFavoriteTrack = state.isFavorite
        }
        
        if volumeChanged {
            self.volume = state.volume
        }
        
        self.timestampDate = state.lastUpdated
    }

    func toggleFavoriteTrack() {
        guard canFavoriteTrack else { return }
        // Toggle based on current state
        setFavorite(!isFavoriteTrack)
    }

    @MainActor
    private func toggleAppleMusicFavorite() async {
        let runningApps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music")
        guard !runningApps.isEmpty else { return }

        let script = """
        tell application \"Music\"
            if it is running then
                try
                    set loved of current track to (not loved of current track)
                    return loved of current track
                on error
                    return false
                end try
            else
                return false
            end if
        end tell
        """

        if let result = try? await AppleScriptHelper.execute(script) {
            let loved = result.booleanValue
            self.isFavoriteTrack = loved
            self.forceUpdate()
        }
    }

    func setFavorite(_ favorite: Bool) {
        guard canFavoriteTrack else { return }
        guard let controller = activeController else { return }

        Task { @MainActor in
            await controller.setFavorite(favorite)
            try? await Task.sleep(for: .milliseconds(150))
            await controller.updatePlaybackInfo()
        }
    }

    /// Placeholder dislike function
    func dislikeCurrentTrack() {
        setFavorite(false)
    }

    // MARK: - Lyrics
    @MainActor
    func refreshLyricsForCurrentTrack() {
        fetchLyricsIfAvailable(bundleIdentifier: bundleIdentifier, title: songTitle, artist: artistName, album: album,
                               duration: songDuration, songID: lyricsSongID, force: true)
    }

    private func lyricsTrackKey(bundleIdentifier: String?, title: String, artist: String, album: String,
                                duration: Double, songID: String?) -> LyricsTrackKey {
        LyricsTrackKey(
            title: normalizedQuery(title).lowercased(),
            artist: normalizedQuery(artist).lowercased(),
            album: normalizedQuery(album).lowercased(),
            bundleIdentifier: bundleIdentifier,
            desktopCacheKey: DesktopLyricsCache.Key(bundleIdentifier: bundleIdentifier, title: title, artist: artist, album: album,
                                                     duration: duration, songID: songID)
        )
    }

    @MainActor
    private func fetchLyricsIfAvailable(bundleIdentifier: String?, title: String, artist: String, album: String,
                                        duration: Double = 0, songID: String? = nil, force: Bool = false) {
        guard Defaults[.enableLyrics], !title.isEmpty else {
            lyricsFetchTask?.cancel()
            activeLyricsFetchKey = nil
            completedLyricsFetchKey = nil
            applyLyrics("", synced: [], source: .none)
            return
        }

        let key = lyricsTrackKey(bundleIdentifier: bundleIdentifier, title: title, artist: artist, album: album,
                                 duration: duration, songID: songID)
        guard force || activeLyricsFetchKey != key else { return }
        guard force || completedLyricsFetchKey != key else { return }

        lyricsFetchTask?.cancel()
        completedLyricsFetchKey = nil
        activeLyricsFetchKey = key
        applyLyrics("", synced: [], source: .none)
        lyricsFetchTask = Task { @MainActor in
            let recording = PlayerLyricsCatalog.Recording(title: title, artist: artist, album: album, duration: duration, songID: songID)
            let foundLyrics: Bool
            if let cacheKey = key.desktopCacheKey, let entry = await self.desktopLyricsCache.load(for: cacheKey) {
                guard !Task.isCancelled else { return }
                self.applyDesktopLyrics(entry, source: .web)
                foundLyrics = true
            } else if let source = PlayerLyricsCatalog.Source(bundleIdentifier: bundleIdentifier), recording.canMatchLocalLyrics {
                foundLyrics = await self.fetchDesktopLyricsWithPolling(recording, source: source,
                                                                       bundleIdentifier: bundleIdentifier, cacheKey: key.desktopCacheKey)
            } else {
                foundLyrics = await self.fetchLyricsWithRetries(bundleIdentifier: bundleIdentifier, recording: recording,
                                                               cacheKey: key.desktopCacheKey)
            }

            if !Task.isCancelled, self.activeLyricsFetchKey == key {
                self.completedLyricsFetchKey = foundLyrics ? key : nil
                self.activeLyricsFetchKey = nil
            }
        }
    }

    @MainActor
    private func fetchDesktopLyricsWithPolling(_ recording: PlayerLyricsCatalog.Recording, source: PlayerLyricsCatalog.Source,
                                               bundleIdentifier: String?, cacheKey: DesktopLyricsCache.Key?) async -> Bool {
        guard !Task.isCancelled else { return false }
        let reader = readDesktopLyrics
        let initial = await reader(recording, source)
        guard !Task.isCancelled else { return false }
        if let initial {
            applyDesktopLyrics(initial, source: .desktopPlayer)
            await cacheDisplayedLyrics(for: cacheKey)
            return true
        }

        return await withTaskGroup(of: DesktopLyricLookup.self) { group in
            group.addTask { .local(await Self.pollDesktopLyrics(recording, source: source, reader: reader)) }
            group.addTask { @MainActor in
                do {
                    try await Task.sleep(for: Self.desktopWebFallbackDelay)
                } catch {
                    return .web(false)
                }
                return .web(await self.fetchLyricsWithRetries(bundleIdentifier: bundleIdentifier, recording: recording, cacheKey: cacheKey))
            }

            var webFound = false
            for await result in group {
                guard !Task.isCancelled else { return false }
                switch result {
                case .local(let lyrics):
                    guard let lyrics, lyrics.quality >= displayedLyricsEntry.quality else { continue }
                    group.cancelAll()
                    applyDesktopLyrics(lyrics, source: .desktopPlayer)
                    await cacheDisplayedLyrics(for: cacheKey)
                    return true
                case .web(let found):
                    webFound = found
                }
            }
            return webFound
        }
    }

    private static func pollDesktopLyrics(_ recording: PlayerLyricsCatalog.Recording, source: PlayerLyricsCatalog.Source,
                                         reader: DesktopLyricsReader) async -> DesktopLyricsCache.Entry? {
        let clock = ContinuousClock()
        let started = clock.now
        for offset in desktopLyricRetryOffsets {
            do {
                try await clock.sleep(until: started.advanced(by: offset))
            } catch {
                return nil
            }
            guard !Task.isCancelled else { return nil }
            if let entry = await reader(recording, source) { return entry }
        }
        return nil
    }

    @MainActor
    private func fetchLyricsWithRetries(bundleIdentifier: String?, recording: PlayerLyricsCatalog.Recording,
                                        cacheKey: DesktopLyricsCache.Key?) async -> Bool {
        for attempt in 0..<maxLyricsFetchAttempts {
            guard !Task.isCancelled else { return false }
            if await fetchLyricsOnce(bundleIdentifier: bundleIdentifier, recording: recording, cacheKey: cacheKey) {
                return true
            }
            if attempt + 1 < maxLyricsFetchAttempts { try? await Task.sleep(for: .milliseconds(450)) }
        }
        return false
    }

    @MainActor
    private func fetchLyricsOnce(bundleIdentifier: String?, recording: PlayerLyricsCatalog.Recording,
                                 cacheKey: DesktopLyricsCache.Key?) async -> Bool {
        let (title, artist, album, duration) = (recording.title, recording.artist, recording.album, recording.duration)
        if let bundleIdentifier = bundleIdentifier, bundleIdentifier.contains("com.apple.Music") {
            if let bookmark = Defaults[.appleMusicLyricsCacheBookmark] {
                let timeline = await AppleMusicCachedLyrics.read(
                    bookmark: bookmark, title: title, artist: artist, album: album, duration: duration
                )
                guard !Task.isCancelled else { return false }
                if let timeline {
                    applyLyrics(
                        timeline.lines.map(\.text).joined(separator: "\n"),
                        synced: timeline.lines,
                        characterTimings: timeline.characterTimings, source: .appleMusicOfficial
                    )
                    if timeline.characterTimings.allSatisfy(\.isEmpty) {
                        _ = await fetchLyricsFromWeb(
                            title: title, artist: artist, album: album, duration: duration, matching: .timeline(timeline.lines)
                        )
                    }
                    return !Task.isCancelled
                }
            }
            if let music = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music").first {
                let accessibleLyrics = await AppleMusicAccessibilityLyrics.read(pid: music.processIdentifier, title: title, duration: duration)
                guard !Task.isCancelled else { return false }
                if let accessibleLyrics, !accessibleLyrics.syncedLines.isEmpty {
                    applyLyrics(accessibleLyrics.text, synced: accessibleLyrics.syncedLines, source: .appleMusicOfficial)
                    return true
                }
                do {
                    if let lyrics = try await fetchLyricsFromAppleMusic(), !lyrics.isEmpty {
                        guard !Task.isCancelled else { return false }
                        applyLyrics(lyrics, synced: [], source: .appleMusicOfficial)
                        return true
                    }
                } catch {
                    // Fall through to web lookup.
                }
                guard !Task.isCancelled else { return false }
                if let accessibleLyrics {
                    applyLyrics(accessibleLyrics.text, synced: [], source: .appleMusicOfficial)
                    _ = await fetchLyricsFromWeb(
                        title: title, artist: artist, album: album, duration: duration, matching: .lyrics(accessibleLyrics.text)
                    )
                    return !Task.isCancelled
                }
            }
            return await fetchLyricsFromWeb(title: title, artist: artist, album: album, duration: duration, matching: .recording)
        }

        if let source = PlayerLyricsCatalog.Source(bundleIdentifier: bundleIdentifier) {
            if let id = recording.songID, let lyrics = await Self.desktopLyricsByID(id, recording: recording, source: source),
               !Task.isCancelled {
                applyDesktopLyrics(lyrics, source: .web)
                await cacheDisplayedLyrics(for: cacheKey)
                return true
            }
            if await fetchDesktopLyrics(recording, preferredSource: source, cacheKey: cacheKey) { return true }
            let found = await fetchLyricsFromWeb(title: title, artist: artist, album: album, duration: duration,
                                                 matching: .desktopRecording(recording))
            if found { await cacheDisplayedLyrics(for: cacheKey) }
            return found
        }

        return await fetchLyricsFromWeb(title: title, artist: artist, album: album, duration: duration)
    }

    private static func desktopLyricsByID(_ id: String, recording: PlayerLyricsCatalog.Recording,
                                          source: PlayerLyricsCatalog.Source) async -> DesktopLyricsCache.Entry? {
        switch source {
        case .qq:
            guard let number = Int(id) else { return nil }
            return await PlayerLyricsCatalog.qqWordLyrics(id: number)
        case .netease:
            guard let lyric = await PlayerLyricsCatalog.netEaseLyric(id: id), let entry = desktopLyricsEntry(lyric) else { return nil }
            if PlayerLyricsCatalog.Recording.isPreviewDuration(recording.duration) {
                return .init(text: entry.text, lines: [], characterTimings: [])
            }
            return entry
        }
    }

    @MainActor
    private func fetchDesktopLyrics(_ recording: PlayerLyricsCatalog.Recording, preferredSource: PlayerLyricsCatalog.Source,
                                    cacheKey: DesktopLyricsCache.Key?) async -> Bool {
        for source in [preferredSource, preferredSource.alternate] {
            guard !Task.isCancelled else { return false }
            let songs = await PlayerLyricsCatalog.search(recording, in: source, allowPreview: preferredSource == .netease,
                                                         allowQQAliases: preferredSource == .qq)
            for song in songs.prefix(2) {
                guard !Task.isCancelled else { return false }
                if source == .qq {
                    if await fetchQQDesktopLyrics(for: song, cacheKey: cacheKey) { return true }
                } else if let candidate = await Self.desktopLyricsCandidate(for: song, in: source), !Task.isCancelled {
                    let isPreview = preferredSource == .netease && recording.matchesNetEasePreview(song)
                    let lyrics = isPreview
                        ? DesktopLyricsCache.Entry(text: candidate.text, lines: [], characterTimings: [])
                        : candidate
                    applyDesktopLyrics(lyrics, source: .web)
                    await cacheDisplayedLyrics(for: cacheKey)
                    return true
                }
            }
        }
        return false
    }

    private static func desktopLyricsCandidate(
        for song: PlayerLyricsCatalog.Song, in source: PlayerLyricsCatalog.Source
    ) async -> DesktopLyricsCache.Entry? {
        guard let lyric = await PlayerLyricsCatalog.lyric(for: song, in: source) else { return nil }
        return desktopLyricsEntry(lyric)
    }

    private static func desktopLyricsEntry(_ lyric: PlayerLyricsCatalog.Lyric) -> DesktopLyricsCache.Entry? {
        if let words = lyric.words, let entry = DesktopPlayerLyrics.netEaseTimeline(words) { return entry }
        return DesktopPlayerLyrics.lrcTimeline(lyric.lines)
    }

    @MainActor
    private func fetchQQDesktopLyrics(for song: PlayerLyricsCatalog.Song, cacheKey: DesktopLyricsCache.Key?) async -> Bool {
        await withTaskGroup(of: DesktopLyricsCache.Entry?.self) { group in
            group.addTask { await Self.desktopLyricsCandidate(for: song, in: .qq) }
            group.addTask {
                if let primary = await PlayerLyricsCatalog.qqWordLyrics(for: song) { return primary }
                guard !Task.isCancelled else { return nil }
                return await Self.fetchQQMusicLyricByID(song.id)?.entry
            }
            var displayedLyrics = false
            for await result in group {
                guard !Task.isCancelled else { return false }
                guard let result else { continue }
                applyDesktopLyrics(result, source: .web)
                await cacheDisplayedLyrics(for: cacheKey)
                if result.characterTimings.contains(where: { !$0.isEmpty }) {
                    group.cancelAll()
                    return true
                }
                displayedLyrics = true
            }
            return displayedLyrics
        }
    }

    @MainActor
    private func applyDesktopLyrics(_ entry: DesktopLyricsCache.Entry, source: LyricsSource) {
        applyLyrics(entry.text, synced: entry.lines.map { ($0.time, $0.text) },
                    characterTimings: entry.characterTimings, source: source)
    }

    @MainActor
    private func cacheDisplayedLyrics(for key: DesktopLyricsCache.Key?) async {
        guard let key, !Task.isCancelled, hasLyrics else { return }
        await desktopLyricsCache.store(displayedLyricsEntry, for: key)
    }

    @MainActor
    private var displayedLyricsEntry: DesktopLyricsCache.Entry {
        DesktopLyricsCache.Entry(
            text: currentLyrics,
            lines: syncedLyrics.map { .init(time: $0.time, text: $0.text) },
            characterTimings: syncedLyricCharacterTimings
        )
    }

    @MainActor
    private func applyLyrics(
        _ text: String,
        synced: [LyricsDisplayText.SyncedLine],
        characterTimings: [[LyricsDisplayText.CharacterTiming]] = [],
        source: LyricsSource
    ) {
        currentLyrics = text
        syncedLyrics = synced
        syncedLyricCharacterTimings = characterTimings
        lyricsSource = source
    }

    @MainActor
    private func fetchLyricsFromAppleMusic() async throws -> String? {
        let script = """
        tell application \"Music\"
            if it is running then
                if player state is playing or player state is paused then
                    try
                        set l to lyrics of current track
                        if l is missing value then
                            return \"\"
                        else
                            return l
                        end if
                    on error
                        return \"\"
                    end try
                else
                    return \"\"
                end if
            else
                return \"\"
            end if
        end tell
        """
        let result = try await AppleScriptHelper.execute(script)
        return result?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func normalizedQuery(_ string: String) -> String {
        string
            .folding(options: .diacriticInsensitive, locale: .current)
            .replacingOccurrences(of: "\u{FFFD}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func lyricTitleQueries(from title: String) -> [String] {
        let normalized = normalizedQuery(title)
        let withoutParentheses = normalized
            .replacingOccurrences(of: #"\s*[\(\[].*?[\)\]]"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let withoutFeaturing = withoutParentheses
            .replacingOccurrences(of: #"\s+-\s+.*$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+(feat\.?|ft\.?|featuring)\s+.*$"#, with: "", options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return [normalized, withoutParentheses, withoutFeaturing].reduce(into: [String]()) { result, query in
            guard !query.isEmpty, !result.contains(query) else { return }
            result.append(query)
        }
    }

    private func lyricSearchURL(title: String, artist: String) -> URL? {
        var components = URLComponents(string: "https://lrclib.net/api/search")
        components?.queryItems = [
            URLQueryItem(name: "track_name", value: title),
            URLQueryItem(name: "artist_name", value: artist)
        ]
        return components?.url
    }

    /// LRCLIB /api/get — exact lookup with duration for tiebreaking.
    /// Returns nil on 404 or network error.
    private func lyricExactURL(title: String, artist: String, album: String, duration: Double) -> URL? {
        guard !title.isEmpty, !artist.isEmpty else { return nil }
        var components = URLComponents(string: "https://lrclib.net/api/get")
        var items: [URLQueryItem] = [
            URLQueryItem(name: "track_name", value: title),
            URLQueryItem(name: "artist_name", value: artist),
        ]
        if !album.isEmpty {
            items.append(URLQueryItem(name: "album_name", value: album))
        }
        if duration > 0 {
            items.append(URLQueryItem(name: "duration", value: String(Int(duration.rounded()))))
        }
        components?.queryItems = items
        return components?.url
    }

    @MainActor
    private func fetchLyricsFromWeb(
        title: String, artist: String, album: String = "", duration: Double = 0,
        matching reference: WebLyricsReference? = nil
    ) async -> Bool {
        guard !Task.isCancelled else { return false }
        let cleanArtist = normalizedQuery(artist)
        let cleanAlbum = normalizedQuery(album)
        let cleanTitle = normalizedQuery(title)
        var fallbackCandidate: WebLyricsCandidate?

        func matchesReference(_ candidate: WebLyricsCandidate) -> Bool {
            switch reference {
            case .timeline(let lines):
                return candidate.hasCharacterTiming && LyricsDisplayText.matchesPlaybackTimeline(candidate.parsed.lines, reference: lines)
            case .lyrics(let text):
                guard let end = candidate.parsed.lines.last?.time, duration <= 0 || end < duration else { return false }
                return LyricsDisplayText.matchesLyricText(candidate.parsed.lines, reference: text)
            case .recording:
                guard let recording = candidate.recording, duration.isFinite, duration > 0,
                      !album.isEmpty, abs(candidate.lrclibDuration - duration) <= 2 else { return false }
                return normalizedQuery(recording.title).caseInsensitiveCompare(cleanTitle) == .orderedSame &&
                    normalizedQuery(recording.artist).caseInsensitiveCompare(cleanArtist) == .orderedSame &&
                    normalizedQuery(recording.album).caseInsensitiveCompare(cleanAlbum) == .orderedSame
            case .desktopRecording(let target):
                guard let recording = candidate.recording else { return false }
                return target.matches(title: recording.title, artists: [recording.artist], album: recording.album,
                                      duration: candidate.lrclibDuration)
            case nil:
                return true
            }
        }

        // ── Step 1: LRCLIB /api/get — exact match (title + artist + album + duration) ──
        // This endpoint returns a single result and matches on duration when provided,
        // giving accurate version selection without needing to sort a search result list.
        if let exactURL = lyricExactURL(title: cleanTitle, artist: cleanArtist, album: cleanAlbum, duration: duration) {
            if let candidate = try? await fetchLrclibSingle(url: exactURL), candidate.hasText, matchesReference(candidate) {
                guard !Task.isCancelled else { return false }
                applyWebLyricsCandidate(candidate)
                return true
            }
        }

        // ── Step 2: LRCLIB /api/search — ranked by duration proximity ──
        // Falls back here when the exact endpoint returns 404 (album name mismatch,
        // simplified/traditional Chinese differences, etc.).
        for titleQuery in lyricTitleQueries(from: title) {
            guard !Task.isCancelled else { return false }
            guard let url = lyricSearchURL(title: titleQuery, artist: cleanArtist) else { continue }
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { continue }
                guard let jsonArray = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { continue }

                var candidates = jsonArray.compactMap(lrclibCandidate).filter(matchesReference)

                // Sort by duration proximity when we have actual track duration.
                // Candidates within 2 s are considered equally good; outside that,
                // prefer closer ones to avoid picking live/demo/remix variants.
                if duration > 0 {
                    candidates.sort {
                        let da = abs($0.lrclibDuration - duration)
                        let db = abs($1.lrclibDuration - duration)
                        // Prefer character-timed entries when both are close enough.
                        if max(da, db) < 2 { return $0.hasCharacterTiming && !$1.hasCharacterTiming }
                        return da < db
                    }
                }

                if let enhanced = candidates.first(where: \.hasCharacterTiming) {
                    guard !Task.isCancelled else { return false }
                    applyWebLyricsCandidate(enhanced)
                    return true
                }

                if fallbackCandidate == nil {
                    fallbackCandidate = candidates.first
                }
            } catch {
                continue
            }
        }

        guard !Task.isCancelled else { return false }
        let allowsQQMusic = switch reference {
        case .recording, .desktopRecording: false
        default: true
        }
        let recording = PlayerLyricsCatalog.Recording(title: title, artist: artist, album: album, duration: duration)
        if allowsQQMusic, let enhanced = await fetchEnhancedLyricsFromQQMusic(recording),
           matchesReference(enhanced) {
            guard !Task.isCancelled else { return false }
            applyWebLyricsCandidate(enhanced)
            return true
        }

        guard !Task.isCancelled else { return false }
        if let fallbackCandidate {
            applyWebLyricsCandidate(fallbackCandidate)
            return true
        }

        return false
    }

    /// Fetch a single LRCLIB result from the given URL (used for /api/get exact endpoint).
    private func fetchLrclibSingle(url: URL) async throws -> WebLyricsCandidate? {
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
        guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return lrclibCandidate(result)
    }

    private func lrclibCandidate(_ result: [String: Any]) -> WebLyricsCandidate? {
        let plain = (result["plainLyrics"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let synced = (result["syncedLyrics"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let parsed = synced.isEmpty ? (lines: [], characterTimes: []) : LyricsDisplayText.parseSyncedLyrics(synced)
        let lrclibDuration = result["duration"] as? Double ?? 0
        let recording = (title: result["trackName"] as? String ?? "", artist: result["artistName"] as? String ?? "",
                         album: result["albumName"] as? String ?? "")
        let candidate = WebLyricsCandidate(plain: plain, synced: synced, parsed: parsed, lrclibDuration: lrclibDuration, recording: recording)
        return candidate.hasText ? candidate : nil
    }

    @MainActor
    private func applyWebLyricsCandidate(_ candidate: WebLyricsCandidate) {
        let timings: [[LyricsDisplayText.CharacterTiming]] = candidate.hasCharacterTiming
            ? candidate.parsed.characterTimes.map { $0.map { .init(start: $0) } }
            : []
        applyLyrics(candidate.displayLyrics, synced: candidate.parsed.lines, characterTimings: timings, source: .web)
    }

    private func fetchEnhancedLyricsFromQQMusic(_ recording: PlayerLyricsCatalog.Recording) async -> WebLyricsCandidate? {
        let query = [normalizedQuery(recording.title), normalizedQuery(recording.artist)]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !query.isEmpty,
              var components = URLComponents(string: "https://oiapi.net/api/QQMusicLyric") else {
            return nil
        }

        components.queryItems = [
            URLQueryItem(name: "keyword", value: query),
            URLQueryItem(name: "format", value: "qrc"),
            URLQueryItem(name: "type", value: "json")
        ]

        guard let url = components.url else { return nil }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }

            if let candidate = Self.qrcCandidate(from: json) {
                return candidate
            }

            for song in PlayerLyricsCatalog.qqProxySongs(from: json, for: recording).prefix(3) {
                if let candidate = await Self.fetchQQMusicLyricByID(song.id) {
                    return candidate
                }
            }

            return nil
        } catch {
            return nil
        }
    }

    private static func fetchQQMusicLyricByID(_ id: String) async -> WebLyricsCandidate? {
        guard var components = URLComponents(string: "https://oiapi.net/api/QQMusicLyric") else {
            return nil
        }

        components.queryItems = [
            URLQueryItem(name: "id", value: id),
            URLQueryItem(name: "format", value: "qrc"),
            URLQueryItem(name: "type", value: "json")
        ]

        guard let url = components.url else { return nil }

        do {
            let (data, response) = try await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 5))
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }

            return qrcCandidate(from: json)
        } catch {
            return nil
        }
    }

    private static func qrcCandidate(from json: [String: Any]) -> WebLyricsCandidate? {
        if let lyric = lyricPayloadText(from: json) {
            let parsed = LyricsDisplayText.parseQQMusicQRC(lyric)
            let candidate = WebLyricsCandidate(plain: "", synced: lyric, parsed: parsed)
            return candidate.hasCharacterTiming ? candidate : nil
        }

        if let data = json["data"] as? [String: Any],
           let lyric = lyricPayloadText(from: data) {
            let parsed = LyricsDisplayText.parseQQMusicQRC(lyric)
            let candidate = WebLyricsCandidate(plain: "", synced: lyric, parsed: parsed)
            return candidate.hasCharacterTiming ? candidate : nil
        }

        return nil
    }

    private static func lyricPayloadText(from dictionary: [String: Any]) -> String? {
        let keys = ["conteng", "content", "lyric", "lyrics", "qrc", "lrc"]
        for key in keys {
            if let value = dictionary[key] as? String,
               !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return value.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        if let base64 = dictionary["base64"] as? String,
           let data = Data(base64Encoded: base64),
           let decoded = String(data: data, encoding: .utf8),
           !decoded.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return decoded.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return nil
    }

    // MARK: - Synced lyrics helpers
    private func parseLRC(_ lrc: String) -> [(time: Double, text: String)] {
        LyricsDisplayText.parseSyncedLyrics(lrc).lines
    }

    func lyricLine(at elapsed: Double) -> String {
        guard !syncedLyrics.isEmpty else { return currentLyrics }
        // Binary search for last line with time <= elapsed
        var low = 0
        var high = syncedLyrics.count - 1
        var idx = 0
        while low <= high {
            let mid = (low + high) / 2
            if syncedLyrics[mid].time <= elapsed {
                idx = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return syncedLyrics[idx].text
    }

    private func triggerFlipAnimation() {
        // Cancel any existing animation
        flipWorkItem?.cancel()

        // Create a new animation
        let workItem = DispatchWorkItem { [weak self] in
            self?.isFlipping = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                self?.isFlipping = false
            }
        }

        flipWorkItem = workItem
        DispatchQueue.main.async(execute: workItem)
    }

    private func updateArtwork(_ artworkData: Data) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            if let artworkImage = NSImage(data: artworkData) {
                DispatchQueue.main.async { [weak self] in
                    self?.usingAppIconForArtwork = false
                    self?.updateAlbumArt(newAlbumArt: artworkImage)
                }
            }
        }
    }

    private func updateIdleState(state: Bool) {
        if state {
            isPlayerIdle = false
            debounceIdleTask?.cancel()
        } else {
            debounceIdleTask?.cancel()
            debounceIdleTask = Task { [weak self] in
                guard let self = self else { return }
                try? await Task.sleep(for: .seconds(Defaults[.waitInterval]))
                withAnimation {
                    self.isPlayerIdle = !self.isPlaying
                }
            }
        }
    }

    private var workItem: DispatchWorkItem?

    func updateAlbumArt(newAlbumArt: NSImage) {
        workItem?.cancel()
        withAnimation(.smooth) {
            self.albumArt = newAlbumArt
            if Defaults[.coloredSpectrogram] {
                self.calculateAverageColor()
            }
        }
    }

    // MARK: - Playback Position Estimation
    public func estimatedPlaybackPosition(at date: Date = Date()) -> TimeInterval {
        guard isPlaying else { return min(elapsedTime, songDuration) }

        let timeDifference = date.timeIntervalSince(timestampDate)
        let estimated = elapsedTime + (timeDifference * playbackRate)
        return min(max(0, estimated), songDuration)
    }

    func calculateAverageColor() {
        albumArt.averageColor { [weak self] color in
            DispatchQueue.main.async {
                withAnimation(.smooth) {
                    self?.avgColor = color ?? .white
                }
            }
        }
    }

    private func updateSneakPeek() {
        if isPlaying && Defaults[.enableSneakPeek] {
            if Defaults[.sneakPeekStyles] == .standard {
                coordinator.toggleSneakPeek(status: true, type: .music)
            } else {
                coordinator.toggleExpandingView(status: true, type: .music)
            }
        }
    }

    // MARK: - Public Methods for controlling playback
    func playPause() {
        Task {
            await activeController?.togglePlay()
        }
    }

    func play() {
        Task {
            await activeController?.play()
        }
    }

    func pause() {
        Task {
            await activeController?.pause()
        }
    }

    func toggleShuffle() {
        Task {
            await activeController?.toggleShuffle()
        }
    }

    func toggleRepeat() {
        Task {
            await activeController?.toggleRepeat()
        }
    }
    
    func togglePlay() {
        Task {
            await activeController?.togglePlay()
        }
    }

    func nextTrack() {
        Task {
            await activeController?.nextTrack()
        }
    }

    func previousTrack() {
        Task {
            await activeController?.previousTrack()
        }
    }

    var supportsSeeking: Bool { activeController?.supportsSeeking ?? false }

    func seek(to position: TimeInterval) {
        Task {
            guard let controller = activeController, controller.supportsSeeking else { return }
            await controller.seek(to: position)
        }
    }
    func skip(seconds: TimeInterval) {
        let newPos = min(max(0, elapsedTime + seconds), songDuration)
        seek(to: newPos)
    }
    
    func setVolume(to level: Double) {
        if let controller = activeController {
            Task {
                await controller.setVolume(level)
            }
        }
    }
    func openMusicApp() {
        guard let bundleID = bundleIdentifier else {
            print("Error: appBundleIdentifier is nil")
            return
        }

        let workspace = NSWorkspace.shared
        if let appURL = workspace.urlForApplication(withBundleIdentifier: bundleID) {
            let configuration = NSWorkspace.OpenConfiguration()
            workspace.openApplication(at: appURL, configuration: configuration) { (app, error) in
                if let error = error {
                    print("Failed to launch app with bundle ID: \(bundleID), error: \(error)")
                } else {
                    print("Launched app with bundle ID: \(bundleID)")
                }
            }
        } else {
            print("Failed to find app with bundle ID: \(bundleID)")
        }
    }

    func forceUpdate() {
        // Request immediate update from the active controller
        Task { [weak self] in
            if self?.activeController?.isActive() == true {
                if let youtubeController = self?.activeController as? YouTubeMusicController {
                    await youtubeController.pollPlaybackState()
                } else {
                    await self?.activeController?.updatePlaybackInfo()
                }
            }
        }
    }
    
    
    func syncVolumeFromActiveApp() async {
        // Check if bundle identifier is valid and if the app is actually running
        guard let bundleID = bundleIdentifier, !bundleID.isEmpty,
              NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == bundleID }) else { return }
        
        var script: String?
        if bundleID == "com.apple.Music" {
            script = """
            tell application "Music"
                if it is running then
                    get sound volume
                else
                    return 50
                end if
            end tell
            """
        } else if bundleID == "com.spotify.client" {
            script = """
            tell application "Spotify"
                if it is running then
                    get sound volume
                else
                    return 50
                end if
            end tell
            """
        } else {
            // For unsupported apps, don't sync volume
            return
        }
        
        if let volumeScript = script,
           let result = try? await AppleScriptHelper.execute(volumeScript) {
            let volumeValue = result.int32Value
            let currentVolume = Double(volumeValue) / 100.0
            
            await MainActor.run {
                if abs(currentVolume - self.volume) > 0.01 {
                    self.volume = currentVolume
                }
            }
        }
    }
}
