import AppKit
import Combine
import Foundation

final class LXMusicController: MediaControllerProtocol {
    static let bundleIdentifier = "cn.toside.music.desktop"

    @Published private var playbackState = LXMusicController.emptyPlayback
    var playbackStatePublisher: AnyPublisher<PlaybackState, Never> {
        $playbackState.eraseToAnyPublisher()
    }

    let supportsVolumeControl = true
    let supportsFavorite = true

    private let baseURL = URL(string: "http://127.0.0.1:23330")!
    private let session: URLSession
    private var streamTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var requestRevision = 0

    private static let fields = "status,name,singer,albumName,duration,progress,playbackRate,lyric,lxlyric,volume,mute,collect"
    private static var emptyPlayback: PlaybackState {
        PlaybackState(bundleIdentifier: bundleIdentifier, title: "", artist: "", album: "")
    }

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.connectionProxyDictionary = [:]
        let session = URLSession(configuration: configuration)
        self.session = session
        let eventsRequest = request("subscribe-player-status", query: [.init(name: "filter", value: Self.fields)],
                                    timeout: 3600)
        streamTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                if self?.isActive() == true {
                    do {
                        let (bytes, response) = try await session.bytes(for: eventsRequest)
                        try Self.validate(response)
                        self?.scheduleRefresh()
                        for try await line in bytes.lines where line.hasPrefix("event: ") {
                            try Task.checkCancellation()
                            self?.scheduleRefresh()
                        }
                    } catch { }
                }
                guard !Task.isCancelled, self != nil else { return }
                self?.disconnect()
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
    }

    deinit {
        streamTask?.cancel()
        refreshTask?.cancel()
        session.invalidateAndCancel()
    }

    func isActive() -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleIdentifier).isEmpty
    }

    @MainActor
    func updatePlaybackInfo() async {
        requestRevision += 1
        let revision = requestRevision
        let snapshotRequest = request("status", query: [.init(name: "filter", value: Self.fields)])
        do {
            let (data, response) = try await session.data(for: snapshotRequest)
            try Self.validate(response)
            let snapshot = try JSONDecoder().decode(Snapshot.self, from: data)
            guard revision == requestRevision, !Task.isCancelled else { return }
            publish(snapshot.playback)
        } catch {
            guard revision == requestRevision, !Task.isCancelled else { return }
            publish(Self.emptyPlayback)
        }
    }

    func play() async { await send("play") }
    func pause() async { await send("pause") }
    func nextTrack() async { await send("skip-next") }
    func previousTrack() async { await send("skip-prev") }
    func toggleShuffle() async {}
    func toggleRepeat() async {}
    func setFavorite(_ favorite: Bool) async { await send(favorite ? "collect" : "uncollect") }

    @MainActor
    func togglePlay() async {
        if playbackState.isPlaying {
            await pause()
        } else {
            await play()
        }
    }

    @MainActor
    func seek(to time: Double) async {
        guard time.isFinite, playbackState.duration > 0 else { return }
        let position = min(max(0, time), playbackState.duration)
        await send("seek", query: [.init(name: "offset", value: String(position))])
    }

    func setVolume(_ level: Double) async {
        guard level.isFinite else { return }
        let percent = Int((min(max(0, level), 1) * 100).rounded())
        await send("volume", query: [.init(name: "volume", value: String(percent))])
    }

    private func send(_ endpoint: String, query: [URLQueryItem] = []) async {
        _ = try? await session.data(for: request(endpoint, query: query))
    }

    private func request(_ endpoint: String, query: [URLQueryItem], timeout: TimeInterval = 2) -> URLRequest {
        var components = URLComponents(url: baseURL.appendingPathComponent(endpoint), resolvingAgainstBaseURL: false)!
        components.queryItems = query.isEmpty ? nil : query
        return URLRequest(url: components.url!, timeoutInterval: timeout)
    }

    private static func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
    }

    @MainActor
    private func scheduleRefresh() {
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(80))
            guard let self, !Task.isCancelled else { return }
            refreshTask = nil
            await updatePlaybackInfo()
        }
    }

    @MainActor
    private func disconnect() {
        requestRevision += 1
        refreshTask?.cancel()
        refreshTask = nil
        publish(Self.emptyPlayback)
    }

    @MainActor
    private func publish(_ state: PlaybackState) {
        if state != playbackState || state.playbackRate != playbackState.playbackRate || state.volume != playbackState.volume {
            playbackState = state
        }
    }

    struct Snapshot: Decodable {
        let status: String
        let name: String?
        let singer: String?
        let albumName: String?
        let duration: Double?
        let progress: Double?
        let playbackRate: Double?
        let lyric: String?
        let lxlyric: String?
        let volume: Double?
        let mute: Bool?
        let collect: Bool?

        var playback: PlaybackState {
            guard status == "playing" || status == "paused", let name, !name.isEmpty else {
                return LXMusicController.emptyPlayback
            }
            let duration = max(0, duration ?? 0)
            return PlaybackState(
                bundleIdentifier: LXMusicController.bundleIdentifier, isPlaying: status == "playing",
                title: name, artist: singer ?? "", album: albumName ?? "",
                currentTime: min(max(0, progress ?? 0), duration), duration: duration,
                playbackRate: max(0, playbackRate ?? 1), lastUpdated: .now,
                volume: mute == true ? 0 : min(max(0, (volume ?? 50) / 100), 1), isFavorite: collect ?? false,
                lxMusicLyrics: LXMusicLyrics(lrc: lyric, wordTimed: lxlyric)
            )
        }
    }
}

struct LXMusicLyrics: Equatable, Sendable {
    let lrc: String?
    let wordTimed: String?

    var timeline: DesktopLyricsCache.Entry? {
        guard let lrc else { return nil }
        let lineOffset = LyricsDisplayText.lxMusicOffset(lrc) ?? 0
        guard let lineTimeline = DesktopPlayerLyrics.lrcTimeline(lrc, offset: lineOffset) else { return nil }
        // LX Music publishes track metadata before replacing its enhanced lyrics.
        guard let wordTimed,
              let timeline = LyricsDisplayText.lxMusicTimeline(wordTimed, offset: LyricsDisplayText.lxMusicOffset(wordTimed) ?? lineOffset),
              LyricsDisplayText.matchesPlaybackTimeline(timeline.syncedLines, reference: lineTimeline.syncedLines) else {
            return lineTimeline
        }
        return timeline
    }
}
