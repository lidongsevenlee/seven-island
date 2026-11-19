//
//  NowPlayingController.swift
//  boringNotch
//
//  Created by Alexander on 2025-03-29.
//

import AppKit
import Combine
import Foundation

final class NowPlayingController: ObservableObject, MediaControllerProtocol {
    func updatePlaybackInfo() async {
        await fetchFavoriteStateIfSupported()
    }

    // MARK: - Properties
    @Published private(set) var playbackState: PlaybackState
    private let sourceBundleIdentifier: String?
    private var systemPlaybackState = PlaybackState.idle(bundleIdentifier: "")

    var playbackStatePublisher: AnyPublisher<PlaybackState, Never> {
        $playbackState.eraseToAnyPublisher()
    }

    var supportsVolumeControl: Bool {
        let bundleID = playbackState.bundleIdentifier
        return bundleID == "com.apple.Music" || bundleID == "com.spotify.client"
    }

    var supportsFavorite: Bool {
        let bundleID = playbackState.bundleIdentifier
        return bundleID == "com.apple.Music"
    }

    var supportsSeeking: Bool {
        !playbackState.usesAdapterTransport
    }

    func setFavorite(_ favorite: Bool) async {
        let bundleID = playbackState.bundleIdentifier
        
        if bundleID == "com.apple.Music" {
            let runningApps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music")
            if !runningApps.isEmpty {
                let script = """
                tell application "Music"
                    try
                        set favorited of current track to \(favorite ? "true" : "false")
                    end try
                end tell
                """
                try? await AppleScriptHelper.executeVoid(script)
            }
        }
        
        // Update the favorite state locally and fetch updated info
        try? await Task.sleep(for: .milliseconds(150))
        await updatePlaybackInfo()
    }

    // MARK: - Media Remote Functions
    private let mediaRemoteBundle: CFBundle
    private let MRMediaRemoteSendCommandFunction: @convention(c) (Int, AnyObject?) -> Void
    private let MRMediaRemoteSetElapsedTimeFunction: @convention(c) (Double) -> Void
    private let MRMediaRemoteSetShuffleModeFunction: @convention(c) (Int) -> Void
    private let MRMediaRemoteSetRepeatModeFunction: @convention(c) (Int) -> Void

    private var process: Process?
    private var pipeHandler: JSONLinesPipeHandler?
    private var streamTask: Task<Void, Never>?

    // MARK: - Initialization
    init?(sourceBundleIdentifier: String? = nil) {
        guard
            let bundle = CFBundleCreate(
                kCFAllocatorDefault,
                NSURL(fileURLWithPath: "/System/Library/PrivateFrameworks/MediaRemote.framework")),
            let MRMediaRemoteSendCommandPointer = CFBundleGetFunctionPointerForName(
                bundle, "MRMediaRemoteSendCommand" as CFString),
            let MRMediaRemoteSetElapsedTimePointer = CFBundleGetFunctionPointerForName(
                bundle, "MRMediaRemoteSetElapsedTime" as CFString),
            let MRMediaRemoteSetShuffleModePointer = CFBundleGetFunctionPointerForName(
                bundle, "MRMediaRemoteSetShuffleMode" as CFString),
            let MRMediaRemoteSetRepeatModePointer = CFBundleGetFunctionPointerForName(
                bundle, "MRMediaRemoteSetRepeatMode" as CFString)
            
        else { return nil }

        self.sourceBundleIdentifier = sourceBundleIdentifier
        playbackState = sourceBundleIdentifier.map { .idle(bundleIdentifier: $0) }
            ?? PlaybackState(bundleIdentifier: "com.apple.Music")
        mediaRemoteBundle = bundle
        MRMediaRemoteSendCommandFunction = unsafeBitCast(
            MRMediaRemoteSendCommandPointer, to: (@convention(c) (Int, AnyObject?) -> Void).self)
        MRMediaRemoteSetElapsedTimeFunction = unsafeBitCast(
            MRMediaRemoteSetElapsedTimePointer, to: (@convention(c) (Double) -> Void).self)
        MRMediaRemoteSetShuffleModeFunction = unsafeBitCast(
            MRMediaRemoteSetShuffleModePointer, to: (@convention(c) (Int) -> Void).self)
        MRMediaRemoteSetRepeatModeFunction = unsafeBitCast(
            MRMediaRemoteSetRepeatModePointer, to: (@convention(c) (Int) -> Void).self)

        Task { await setupNowPlayingObserver() }
    }

    deinit {
        streamTask?.cancel()
        if let process, process.isRunning { process.terminate() }
        if let pipeHandler { Task { await pipeHandler.close() } }
    }

    // MARK: - Protocol Implementation
    func play() async {
        await sendTransportCommand(0)
    }

    func pause() async {
        await sendTransportCommand(1)
    }

    @MainActor
    func togglePlay() async {
        if usesAdapterCommands {
            sendTransportCommand(systemPlaybackState.isPlaying ? 1 : 0)
        } else {
            sendTransportCommand(2)
        }
    }

    func nextTrack() async {
        await sendTransportCommand(4)
    }

    func previousTrack() async {
        await sendTransportCommand(5)
    }

    @MainActor
    func seek(to time: Double) async {
        guard canControlCurrentPlayer, supportsSeeking, time.isFinite, time >= 0 else { return }
        MRMediaRemoteSetElapsedTimeFunction(time)
    }

    func isActive() -> Bool {
        return true
    }
    
    @MainActor
    func toggleShuffle() async {
        guard canControlCurrentPlayer else { return }
        let mode = playbackState.isShuffled ? 1 : 3
        if usesAdapterCommands {
            runAdapterCommand(["shuffle", String(mode)])
        } else {
            MRMediaRemoteSetShuffleModeFunction(mode)
            playbackState.isShuffled.toggle()
        }
    }
    
    @MainActor
    func toggleRepeat() async {
        guard canControlCurrentPlayer else { return }
        let newRepeatMode = (playbackState.repeatMode == .off) ? 3 : (playbackState.repeatMode.rawValue - 1)
        if usesAdapterCommands {
            runAdapterCommand(["repeat", String(newRepeatMode)])
        } else {
            MRMediaRemoteSetRepeatModeFunction(newRepeatMode)
            playbackState.repeatMode = RepeatMode(rawValue: newRepeatMode) ?? .off
        }
    }
    
    func setVolume(_ level: Double) async {
        // MediaRemote framework doesn't provide direct volume control for the active audio session
        // As a workaround, try to control the currently active music app directly
        let clampedLevel = max(0.0, min(1.0, level))
        let volumePercentage = Int(clampedLevel * 100)
        
        let bundleID = playbackState.bundleIdentifier
        if !bundleID.isEmpty {
            if bundleID == "com.apple.Music" {
                let runningApps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music")
                if !runningApps.isEmpty {
                    let script = "tell application \"Music\" to set sound volume to \(volumePercentage)"
                    try? await AppleScriptHelper.executeVoid(script)
                }
            } else if bundleID == "com.spotify.client" {
                let runningApps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.spotify.client")
                if !runningApps.isEmpty {
                    let script = "tell application \"Spotify\" to set sound volume to \(volumePercentage)"
                    try? await AppleScriptHelper.executeVoid(script)
                }
            }
        }
        
        playbackState.volume = clampedLevel
    }

    @MainActor
    private var canControlCurrentPlayer: Bool {
        systemPlaybackState.isFrom(sourceBundleIdentifier)
    }

    @MainActor
    private var usesAdapterCommands: Bool {
        systemPlaybackState.usesAdapterTransport
    }

    @MainActor
    private func sendTransportCommand(_ command: Int) {
        guard canControlCurrentPlayer else { return }
        if usesAdapterCommands {
            runAdapterCommand(["send", String(command)])
        } else {
            MRMediaRemoteSendCommandFunction(command, nil)
        }
    }
    
    // MARK: - Setup Methods
    private func makeAdapterProcess(arguments: [String]) -> Process? {
        guard
            let scriptURL = Bundle.main.url(forResource: "mediaremote-adapter", withExtension: "pl"),
            let frameworkPath = Bundle.main.privateFrameworksPath?.appending("/MediaRemoteAdapter.framework")
        else { return nil }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [scriptURL.path, frameworkPath] + arguments
        return process
    }

    private func runAdapterCommand(_ arguments: [String]) {
        guard let command = makeAdapterProcess(arguments: arguments) else { return }
        do {
            try command.run()
        } catch {
            NSLog("Could not run media adapter command: %@", String(describing: error))
        }
    }

    private func setupNowPlayingObserver() async {
        guard let process = makeAdapterProcess(arguments: ["stream"]) else { return }
        
        let pipeHandler = JSONLinesPipeHandler()
        process.standardOutput = await pipeHandler.getPipe()
        
        self.process = process
        self.pipeHandler = pipeHandler

        do {
            try process.run()
            streamTask = Task { [weak self] in
                await pipeHandler.readJSONLines(as: NowPlayingUpdate.self) { [weak self] update in
                    await self?.handleAdapterUpdate(update)
                }
            }
        } catch {
            NSLog("Could not start media adapter stream: %@", String(describing: error))
        }
    }

    // MARK: - Update Methods
    @MainActor
    private func handleAdapterUpdate(_ update: NowPlayingUpdate) {
        systemPlaybackState = update.applying(to: systemPlaybackState)
        if let sourceBundleIdentifier, !canControlCurrentPlayer {
            let idle = PlaybackState.idle(bundleIdentifier: sourceBundleIdentifier)
            if playbackState != idle { playbackState = idle }
            return
        }
        playbackState = systemPlaybackState
    }
    
     private func fetchFavoriteStateIfSupported() async {
         let bundleID = playbackState.bundleIdentifier
        
         if bundleID == "com.apple.Music" {
             let runningApps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music")
             guard !runningApps.isEmpty else { return }
             
             let script = """
             tell application "Music"
                 try
                     return favorited of current track
                 on error
                     return false
                 end try
             end tell
             """
             if let result = try? await AppleScriptHelper.execute(script) {
                 var updated = self.playbackState
                 updated.isFavorite = result.booleanValue
                 self.playbackState = updated
             }
         }
     }
    
}

struct NowPlayingUpdate: Codable {
    let payload: NowPlayingPayload
    let diff: Bool?

    func applying(to previous: PlaybackState, now: Date = .now) -> PlaybackState {
        let identifier = payload.parentApplicationBundleIdentifier ?? payload.bundleIdentifier
            ?? (diff == true ? previous.bundleIdentifier : "")
        let inheritsPrevious = diff == true && identifier == previous.bundleIdentifier
        var state = inheritsPrevious ? previous : .idle(bundleIdentifier: identifier)

        state.title = payload.title ?? state.title
        state.artist = payload.artist ?? state.artist
        state.album = payload.album ?? state.album
        state.duration = payload.duration ?? state.duration
        if PlayerLyricsCatalog.Source(bundleIdentifier: identifier) != nil {
            if let contentID = payload.contentItemIdentifier {
                state.lyricsSongID = PlayerLyricsCatalog.Source.numericSongID(contentID)
            } else if state.title != previous.title || state.artist != previous.artist || state.album != previous.album {
                state.lyricsSongID = nil
            }
        }
        if let time = payload.elapsedTime {
            state.currentTime = time
        } else if inheritsPrevious, previous.isPlaying, payload.playing == false {
            let elapsed = max(0, now.timeIntervalSince(previous.lastUpdated))
            let position = previous.currentTime + previous.playbackRate * elapsed
            state.currentTime = state.duration > 0 ? min(position, state.duration) : position
        }
        if let mode = payload.shuffleMode { state.isShuffled = mode != 1 }
        if let mode = payload.repeatMode { state.repeatMode = RepeatMode(rawValue: mode) ?? .off }
        if let artwork = payload.artworkData {
            state.artwork = Data(base64Encoded: artwork.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if let timestamp = payload.timestamp.flatMap({ ISO8601DateFormatter().date(from: $0) }) {
            state.lastUpdated = timestamp
        } else if !inheritsPrevious || payload.elapsedTime != nil || payload.playing.map({ $0 != previous.isPlaying }) == true {
            state.lastUpdated = now
        }
        state.playbackRate = payload.playbackRate ?? state.playbackRate
        state.isPlaying = payload.playing ?? state.isPlaying
        state.volume = payload.volume ?? state.volume
        return state
    }
}

extension PlaybackState {
    static func idle(bundleIdentifier: String) -> Self {
        Self(bundleIdentifier: bundleIdentifier, title: "", artist: "", album: "")
    }

    func isFrom(_ sourceBundleIdentifier: String?) -> Bool {
        guard let sourceBundleIdentifier else { return true }
        return bundleIdentifier == sourceBundleIdentifier || bundleIdentifier.hasPrefix(sourceBundleIdentifier + ".")
    }

    var usesAdapterTransport: Bool {
        MediaControllerType.allCases.compactMap(\.systemPlayerBundleIdentifier).contains { isFrom($0) }
    }
}

struct NowPlayingPayload: Codable {
    let title: String?
    let artist: String?
    let album: String?
    let duration: Double?
    let elapsedTime: Double?
    let shuffleMode: Int?
    let repeatMode: Int?
    let artworkData: String?
    let timestamp: String?
    let playbackRate: Double?
    let playing: Bool?
    let parentApplicationBundleIdentifier: String?
    let bundleIdentifier: String?
    let contentItemIdentifier: String?
    let volume: Double?
}

actor JSONLinesPipeHandler {
    private let pipe = Pipe()

    func getPipe() -> Pipe {
        pipe
    }

    func readJSONLines<T: Decodable>(as type: T.Type, onLine: (T) async -> Void) async {
        let handle = pipe.fileHandleForReading
        let chunks = AsyncStream<Data> { continuation in
            continuation.onTermination = { _ in handle.readabilityHandler = nil }
            handle.readabilityHandler = { source in
                let data = source.availableData
                if data.isEmpty {
                    source.readabilityHandler = nil
                    continuation.finish()
                } else {
                    continuation.yield(data)
                }
            }
        }
        let decoder = JSONDecoder()
        var buffer = Data()
        for await chunk in chunks {
            guard !Task.isCancelled else { break }
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 0x0a) {
                let line = buffer.prefix(upTo: newline)
                buffer.removeSubrange(...newline)
                if let decoded = try? decoder.decode(type, from: line) {
                    await onLine(decoded)
                }
            }
        }
    }

    func close() {
        pipe.fileHandleForReading.readabilityHandler = nil
        try? pipe.fileHandleForReading.close()
        try? pipe.fileHandleForWriting.close()
    }
}
