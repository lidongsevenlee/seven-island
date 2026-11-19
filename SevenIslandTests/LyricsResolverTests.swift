import Foundation
@testable import Seven_Island

private typealias Entry = DesktopLyricsCache.Entry

@MainActor
@main
enum LyricsResolverTests {
    static func main() async {
        let deadline = Task.detached {
            do {
                try await Task.sleep(for: .seconds(15))
                fail("timed out while waiting for a lyrics result")
            } catch { }
        }
        defer { deadline.cancel() }

        await testDesktopResultsAndCache()
        await testSupersededPlayback()
        await testLateSongID()
        await testNetEasePreview()
        await testQQRecordingAliases()
        await testAppleMusicEnrichment()
        testLXMusicLyrics()
        print("LyricsResolverTests passed")
    }

    private static func testLXMusicLyrics() {
        let log = Updates()
        let resolver = LyricsResolver(readers: readers(request: { _ in
            fail("LX Music lyrics should come from the player snapshot")
        })) { log.record($0) }

        let json = #"{"status":"playing","name":"月光","singer":"歌手","duration":190,"progress":12.2,"playbackRate":1.25,"lyric":"[00:12.00]月光","lxlyric":"[00:12.00]<100,300>月<450,200>光"}"#
        let snapshot = try! JSONDecoder().decode(LXMusicController.Snapshot.self, from: Data(json.utf8))
        var track = snapshot.playback
        resolver.updatePlayback(track, lyricsEnabled: true)
        check(track.currentTime == 12.2 && track.playbackRate == 1.25, "uses LX Music's playback clock")
        let line = log.results.last?.entry
        check(line?.text == "月光" && line?.quality == 3, "uses matching enhanced lyrics")
        check(line?.characterTimings.first?.first == .init(start: 12.1, end: 12.4),
              "converts word offsets to absolute playback time")

        track.title = "潮汐"
        track.lxMusicLyrics = LXMusicLyrics(lrc: "[00:12.00]潮汐", wordTimed: track.lxMusicLyrics?.wordTimed)
        resolver.updatePlayback(track, lyricsEnabled: true)
        check(log.results.last?.entry.text == "潮汐" && log.results.last?.entry.quality == 2,
              "uses new LRC while LX Music replaces the previous track's enhanced lyrics")

        track.lxMusicLyrics = LXMusicLyrics(lrc: "[00:12.00]潮汐", wordTimed: "[00:12.00]<0,200>潮<200,300>汐")
        resolver.updatePlayback(track, lyricsEnabled: true)
        check(log.results.last?.entry.text == "潮汐" && log.results.last?.entry.quality == 3,
              "upgrades the same track when enhanced lyrics arrive")

        track.currentTime += 1
        resolver.updatePlayback(track, lyricsEnabled: true)
        check(log.results.count == 3, "keeps the timeline stable while playback progresses")

        track.title = "纯音乐"
        track.lxMusicLyrics = LXMusicLyrics(lrc: "", wordTimed: track.lxMusicLyrics?.wordTimed)
        resolver.updatePlayback(track, lyricsEnabled: true)
        check(log.clears == 3, "clears lyrics for an instrumental even when the desktop app has stale enhanced lyrics")

        let lrc = "[offset:1500]\n[00:12.00]月光"
        let lineOnly = LXMusicLyrics(lrc: lrc, wordTimed: nil).timeline
        let enhanced = LXMusicLyrics(lrc: lrc, wordTimed: "[00:12.00]<0,300>月<300,200>光").timeline
        check(lineOnly?.lines.first?.time == 10.5 && enhanced?.characterTimings.first?.first?.start == 10.5,
              "applies the LX Music lyric offset to line and word timing")
    }

    private static func testDesktopResultsAndCache() async {
        let track = PlaybackState(bundleIdentifier: "com.netease.163music", title: "夜色", artist: "歌手",
                                  album: "夜色", duration: 236, lyricsSongID: "211225")
        for local in [
            Entry(text: "native plain", lines: [], characterTimings: []),
            Entry(text: "native line", lines: [.init(time: 8, text: "native line")], characterTimings: []),
            wordTimed("native word"),
        ] {
            let log = Updates()
            let native = PolledLyrics(entry: local)
            let cache = temporaryCache()
            defer { try? FileManager.default.removeItem(at: cache.directory) }
            let resolver = LyricsResolver(cache: cache.value, readers: readers(
                desktop: { _, _ in await native.read() },
                request: { request in
                    check(request.url?.host == "music.163.com" && request.url?.query?.contains("id=211225") == true,
                          "looks up a known platform song ID directly")
                    return response(to: request, with: ["lrc": ["lyric": "[00:08.00]web line"]])
                }
            ), timing: .immediate) { result in
                log.record(result)
                if result?.source == .web {
                    Task { await native.webDisplayed.signal() }
                }
            }

            await resolver.updatePlayback(track, lyricsEnabled: true)?.value
            let expected = local.quality == 1 ? ["web line"] : ["web line", local.text]
            check(log.results.map(\.entry.text) == expected, "prefers equal or higher precision from the local client")
            let key = DesktopLyricsCache.Key(bundleIdentifier: track.bundleIdentifier, title: track.title,
                                             artist: track.artist, album: track.album, duration: track.duration,
                                             songID: track.lyricsSongID)!
            let saved = await cache.value.load(for: key)
            check(saved?.text == expected.last, "caches the accepted version")

            log.results.removeAll()
            await resolver.refresh(lyricsEnabled: true)?.value
            check(log.results.map(\.entry.text) == [expected.last!], "reuses saved lyrics before another lookup")
            let readCount = await native.calls
            check(readCount == 2, "a cache hit bypasses native polling")
        }
    }

    private static func testSupersededPlayback() async {
        let pending = ApplePlaybackReads()
        let log = Updates()
        let resolver = LyricsResolver(readers: readers(appleCache: { track in await pending.read(track.title) }),
                                      timing: .immediate) { log.record($0) }
        var track = PlaybackState(bundleIdentifier: "com.apple.Music", isPlaying: true, title: "A", artist: "Singer",
                                  album: "Album", duration: 90)
        let oldTask = resolver.updatePlayback(track, lyricsEnabled: true)
        await pending.firstStarted.wait()
        var progress = track
        progress.currentTime = 4
        check(resolver.updatePlayback(progress, lyricsEnabled: true) == nil, "progress updates share the current request")

        track.title = "B"
        await resolver.updatePlayback(track, lyricsEnabled: true)?.value
        track.title = "A"
        await resolver.updatePlayback(track, lyricsEnabled: true)?.value
        await pending.releaseFirst.signal()
        await oldTask?.value
        check(log.results.map(\.entry.text) == ["B", "current A"], "a delayed response from the first A stays out of the later A")
        resolver.stop()
        check(log.clears == 2, "clears displayed lyrics at track change and shutdown")
    }

    private static func testLateSongID() async {
        let searchStarted = Signal()
        let releaseSearch = Signal()
        let log = Updates()
        let resolver = LyricsResolver(readers: readers(request: { request in
            switch request.url?.path {
            case "/api/search/get/web":
                await searchStarted.signal()
                await releaseSearch.wait()
                return response(to: request, status: 404)
            case "/api/song/lyric/v1":
                check(request.url?.query?.contains("id=211225") == true, "uses the newly reported song ID")
                return response(to: request, with: ["lrc": ["lyric": "[00:08.00]version by ID"]])
            default:
                return response(to: request, status: 404)
            }
        }), timing: .immediate) { log.record($0) }
        var track = PlaybackState(bundleIdentifier: "com.netease.163music", title: "夜色", artist: "歌手", album: "录音室")

        let metadataLookup = resolver.updatePlayback(track, lyricsEnabled: true)
        await searchStarted.wait()
        track.lyricsSongID = "211225"
        await resolver.updatePlayback(track, lyricsEnabled: true)?.value
        await releaseSearch.signal()
        await metadataLookup?.value

        check(log.results.map(\.entry.text) == ["version by ID"], "a known ID replaces the metadata lookup before duration arrives")
    }

    private static func testNetEasePreview() async {
        let track = PlaybackState(bundleIdentifier: "com.netease.163music", title: "夜色", artist: "歌手",
                                  album: "录音室", duration: 35.03)
        let cache = temporaryCache()
        defer { try? FileManager.default.removeItem(at: cache.directory) }
        let log = Updates()
        let resolver = LyricsResolver(cache: cache.value, readers: readers(request: { request in
            switch request.url?.path {
            case "/api/search/get/web":
                return response(to: request, with: ["result": ["songs": [
                    ["id": 1, "name": "夜色", "album": ["name": "现场"], "artists": [["name": "歌手"]], "duration": 235_000],
                    ["id": 2, "name": "夜色", "album": ["name": "录音室"], "artists": [["name": "歌手"]], "duration": 236_000],
                ]]])
            case "/api/song/lyric/v1":
                check(request.url?.query?.contains("id=2") == true, "uses the studio recording for the 35-second preview")
                return response(to: request, with: ["lrc": ["lyric": "[00:42.00]试听原录音"]])
            default:
                return response(to: request, status: 404)
            }
        }), timing: .immediate) { log.record($0) }

        await resolver.updatePlayback(track, lyricsEnabled: true)?.value
        check(log.results.map(\.entry.text) == ["试听原录音"], "resolves the original recording's lyrics")
        check(log.results.last?.entry.quality == 1, "displays a preview with an unknown offset as plain lyrics")
    }

    private static func testQQRecordingAliases() async {
        let cache = temporaryCache()
        defer { try? FileManager.default.removeItem(at: cache.directory) }
        let log = Updates()
        let resolver = LyricsResolver(cache: cache.value, readers: readers(request: { request in
            if request.url?.host == "u.y.qq.com",
               let body = request.httpBody,
               let json = try JSONSerialization.jsonObject(with: body) as? [String: Any], json["req"] != nil {
                return response(to: request, with: ["req": ["data": ["body": ["song": ["list": [
                    ["mid": "solo", "title": "Fight as ONE", "singer": [["name": "歌手甲"]],
                     "album": ["name": "现场"], "interval": 250],
                    ["mid": "duet", "title": "Fight as ONE", "singer": [["name": "歌手甲"], ["name": "歌手乙"]],
                     "album": ["name": "合唱"], "interval": 222],
                    ["mid": "original", "title": "Trouble", "singer": [["name": "Original Artist"]],
                     "album": ["name": "Original"], "interval": 220],
                    ["mid": "cover", "title": "Trouble (Tribute to Original Artist)", "singer": [["name": "Cover Artist"]],
                     "album": ["name": "Tribute"], "interval": 220],
                ]]]]]])
            }
            if request.url?.host == "c.y.qq.com" {
                let id = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?
                    .first { $0.name == "songmid" }?.value
                check(id == "duet" || id == "cover", "selects the correct QQ recording")
                return response(to: request, with: ["lyric": "[00:10.00]\(id!)"])
            }
            return response(to: request, status: 404)
        }), timing: .immediate) { log.record($0) }

        for (track, expected) in [
            (PlaybackState(bundleIdentifier: "com.tencent.QQMusicMac", title: "Fight as ONE",
                           artist: "歌手甲", album: "合唱", duration: 222), "duet"),
            (PlaybackState(bundleIdentifier: "com.tencent.QQMusicMac", title: "Trouble",
                           artist: "Cover Artist", album: "Tribute", duration: 220), "cover"),
        ] {
            await resolver.updatePlayback(track, lyricsEnabled: true)?.value
            check(log.results.last?.entry.text == expected, "publishes the QQ recording matched by album and artist credits")
        }
    }

    private static func testAppleMusicEnrichment() async {
        let official = Entry(text: "星光\n夜色\n微风",
                             lines: [.init(time: 10, text: "星光"), .init(time: 15, text: "夜色"),
                                     .init(time: 20, text: "微风")],
                             characterTimings: [])
        let wrong = ["syncedLyrics": "[00:12.00]<00:12.00>星<00:12.20>光\n[00:17.00]夜色\n[00:22.00]微风"]
        let right = ["syncedLyrics": "[00:10.00]<00:10.00>星<00:10.20>光\n[00:15.00]夜色\n[00:20.00]微风"]
        let log = Updates()
        let resolver = LyricsResolver(readers: readers(appleCache: { _ in official }, request: { request in
            switch request.url?.path {
            case "/api/get": return response(to: request, with: wrong)
            case "/api/search": return response(to: request, with: [wrong, right])
            default: return response(to: request, status: 404)
            }
        }), timing: .immediate) { log.record($0) }
        let track = PlaybackState(bundleIdentifier: "com.apple.Music", title: "夜色", artist: "歌手",
                                  album: "录音室", duration: 90)

        await resolver.updatePlayback(track, lyricsEnabled: true)?.value
        check(log.results.map(\.source) == [.appleMusicOfficial, .web], "publishes official Apple Music lyrics before enrichment")
        check(log.results.last?.entry.lines.map(\.time) == [10, 15, 20], "chooses the network result with the official timeline")
        check(log.results.last?.entry.characterTimings.first?.map(\.start) == [10, 10.2], "keeps matching word timing")

        let accessibilityLog = Updates()
        let accessibilityResolver = LyricsResolver(readers: readers(
            appleAccessibility: { _ in official },
            request: { _ in fail("time-aligned accessibility lyrics should finish the lookup") }
        ), timing: .immediate) { accessibilityLog.record($0) }
        await accessibilityResolver.updatePlayback(track, lyricsEnabled: true)?.value
        check(accessibilityLog.results.map(\.source) == [.appleMusicOfficial], "uses Apple Music accessibility as a fallback")
    }
}

@MainActor
private final class Updates {
    var results: [LyricsResolver.Result] = []
    var clears = 0

    func record(_ result: LyricsResolver.Result?) {
        if let result { results.append(result) } else { clears += 1 }
    }
}

private actor Signal {
    private var ready = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        guard !ready else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func signal() {
        ready = true
        continuation?.resume()
        continuation = nil
    }
}

private actor PolledLyrics {
    let entry: Entry
    let webDisplayed = Signal()
    private(set) var calls = 0

    init(entry: Entry) { self.entry = entry }

    func read() async -> Entry? {
        calls += 1
        guard calls > 1 else { return nil }
        await webDisplayed.wait()
        return entry
    }
}

private actor ApplePlaybackReads {
    let firstStarted = Signal()
    let releaseFirst = Signal()
    private var first = true

    func read(_ title: String) async -> Entry {
        if first {
            first = false
            await firstStarted.signal()
            await releaseFirst.wait()
            return wordTimed("old A")
        }
        return wordTimed(title == "A" ? "current A" : title)
    }
}

private extension LyricsResolver.Timing {
    static let immediate = Self(desktopPollOffsets: [.zero], desktopFallbackDelay: .zero, retryDelay: .zero)
}

private func readers(
    desktop: @escaping @Sendable (PlayerLyricsCatalog.Recording, PlayerLyricsCatalog.Source) async -> Entry? = { _, _ in nil },
    appleCache: @escaping @Sendable (PlayerLyricsCatalog.Recording) async -> Entry? = { _ in nil },
    appleAccessibility: @escaping @Sendable (PlayerLyricsCatalog.Recording) async -> Entry? = { _ in nil },
    request: @escaping LyricsHTTPRequest = { _ in fail("unexpected network request") }
) -> LyricsResolver.Readers {
    .init(desktop: desktop, appleCache: appleCache, appleAccessibility: appleAccessibility, appleTrack: { nil }, request: request)
}

private func temporaryCache() -> (directory: URL, value: DesktopLyricsCache) {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    return (directory, DesktopLyricsCache(directory: directory))
}

private func wordTimed(_ text: String) -> Entry {
    .init(text: text, lines: [.init(time: 8, text: text)], characterTimings: [[.init(start: 8)]])
}

private func response(to request: URLRequest, status: Int = 200, with payload: Any = [:]) -> (Data, URLResponse) {
    (try! JSONSerialization.data(withJSONObject: payload),
     HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!)
}

private func check(_ condition: Bool, _ message: String) {
    if !condition { fail(message) }
}

private func fail(_ message: String) -> Never {
    fputs("FAIL: \(message)\n", stderr)
    exit(1)
}
