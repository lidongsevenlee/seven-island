//
//  HooksActivityService.swift
//  boringNotch
//
//  Reads ~/.seven-island/hooks-log.jsonl using DispatchSource filesystem notifications
//  for < 100ms latency. Reconstructs Claude Code sessions from the event stream.
//

import Foundation

@MainActor
final class HooksActivityService: ObservableObject {
    static let shared = HooksActivityService()

    /// Sessions filtered to the current project cwd, live sessions first
    @Published private(set) var filteredSessions: [HookSession] = []

    /// The cwd of the most recent non-subagent SessionStart
    @Published private(set) var currentProjectCwd: String? = nil

    /// Fired when a session transitions to .blocked or .idle (after working).
    /// Payload: (sessionId, cwd, newStatus, cwdBasename)
    var onNotifiableStatusChange: ((String, String, SessionStatus, String) -> Void)?

    /// Track previous statuses to detect transitions
    private var previousStatuses: [String: SessionStatus] = [:]

    /// Sessions whose next blocked → idle transition must NOT fire a "completion"
    /// notification. Set by the socket server after PostToolUse dismisses an
    /// external-decision banner — without this, the subsequent rebuild snaps
    /// blocked → idle and misleads the user with a "<cwd> 已完成" pop after
    /// every approved permission.
    private var suppressNextIdleNotice: Set<String> = []

    /// Cached session names (title) keyed by sessionId, loaded from platform session JSON files.
    private var sessionNameCache: [String: String] = [:]

    /// Called from AgentSocketServer when an external decision (terminal UI)
    /// dismisses the banner. The next blocked → idle transition for `sessionId`
    /// is treated as a continuation, not a completion.
    func suppressNextIdleNotification(forSessionId sessionId: String) {
        guard !sessionId.isEmpty else { return }
        suppressNextIdleNotice.insert(sessionId)
    }

    // MARK: - Private state

    private let logPath: String = NSHomeDirectory() + "/.seven-island/hooks-log.jsonl"

    private var fileSource: DispatchSourceFileSystemObject?
    private var fileDescriptor: Int32 = -1
    private var lastReadOffset: Int = 0
    private let queue = DispatchQueue(label: "com.local.seven-island.hooks-watcher", qos: .utility)

    /// All parsed events (newest appended, max 2000)
    private var allEvents: [HookEvent] = []

    // MARK: - Init

    private init() {
        loadAll()
        startWatching()
    }

    // MARK: - Public

    func clearLog() {
        stopWatching()
        let path = logPath
        queue.async {
            try? "".write(toFile: path, atomically: true, encoding: .utf8)
            Task { @MainActor [weak self] in
                self?.allEvents = []
                self?.filteredSessions = []
                self?.currentProjectCwd = nil
                self?.lastReadOffset = 0
                self?.startWatching()
            }
        }
    }

    // MARK: - Full load

    private func loadAll() {
        let path = logPath
        queue.async {
            guard let data = FileManager.default.contents(atPath: path),
                  let text = String(data: data, encoding: .utf8) else {
                Task { @MainActor [weak self] in self?.lastReadOffset = 0 }
                return
            }
            let byteCount = data.count
            let events = Self.parseLines(nonisolated: text)
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.lastReadOffset = byteCount
                self.allEvents = events
                self.loadSessionNames()
                self.rebuild()
            }
        }
    }

    // MARK: - Incremental read

    /// Called from background queue — all MainActor values are passed in as parameters.
    private func readIncremental(offset: Int, logPath: String) {
        let startOffset = offset
        let path = logPath
        queue.async {
            guard let fh = FileHandle(forReadingAtPath: path) else { return }
            defer { try? fh.close() }
            do {
                if #available(macOS 10.15.4, *) {
                    try fh.seek(toOffset: UInt64(startOffset))
                    let newData = fh.readDataToEndOfFile()
                    guard !newData.isEmpty,
                          let text = String(data: newData, encoding: .utf8) else { return }
                    let newEvents = Self.parseLines(nonisolated: text)
                    guard !newEvents.isEmpty else { return }
                    let newOffset = startOffset + newData.count
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        self.lastReadOffset = newOffset
                        self.allEvents.append(contentsOf: newEvents)
                        if self.allEvents.count > 2000 {
                            self.allEvents = Array(self.allEvents.suffix(2000))
                        }
                        self.loadSessionNames()
                        self.rebuild()
                    }
                }
            } catch {
                Task { @MainActor [weak self] in self?.restartWatching() }
            }
        }
    }

    // MARK: - DispatchSource

    private func startWatching() {
        let parentDir = (logPath as NSString).deletingLastPathComponent
        do {
            try FileManager.default.createDirectory(
                atPath: parentDir,
                withIntermediateDirectories: true
            )
        } catch {
            NSLog("[HooksActivity] Failed to create parent directory \(parentDir): \(error.localizedDescription)")
            return
        }
        if !FileManager.default.fileExists(atPath: logPath) {
            if !FileManager.default.createFile(atPath: logPath, contents: nil) {
                NSLog("[HooksActivity] Failed to create log file at \(logPath)")
                return
            }
        }
        let fd = open(logPath, O_EVTONLY)
        guard fd >= 0 else {
            NSLog("[HooksActivity] open() failed for \(logPath) errno=\(errno)")
            return
        }
        fileDescriptor = fd

        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename],
            queue: queue
        )
        src.setEventHandler { [weak self] in
            guard let self else { return }
            let flags = src.data
            if flags.contains(.write) {
                // Capture MainActor values before dispatching background IO
                let offset = self.lastReadOffset
                let logPath = self.logPath
                self.queue.async { self.readIncremental(offset: offset, logPath: logPath) }
            } else {
                DispatchQueue.main.async { self.restartWatching() }
            }
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        fileSource = src
    }

    private func stopWatching() {
        fileSource?.cancel()
        fileSource = nil
        fileDescriptor = -1
    }

    private func restartWatching() {
        stopWatching()
        lastReadOffset = 0
        loadAll()
        startWatching()
    }

    // MARK: - Session name cache

    /// Scans platform session JSON files (~/.claude/sessions/*.json,
    /// ~/.codex/sessions/**/*.json) and populates sessionNameCache keyed by sessionId.
    private func loadSessionNames() {
        let dirs = [
            (NSHomeDirectory() + "/.claude/sessions"),
            (NSHomeDirectory() + "/.codex/sessions"),
        ]
        for dir in dirs {
            let dirURL = URL(fileURLWithPath: dir)
            guard let enumerator = FileManager.default.enumerator(
                at: dirURL, includingPropertiesForKeys: nil
            ) else { continue }
            for case let url as URL in enumerator where url.pathExtension == "json" {
                guard let data = try? Data(contentsOf: url),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let sid = json["sessionId"] as? String,
                      let name = json["name"] as? String, !name.isEmpty else { continue }
                sessionNameCache[sid] = name
            }
        }
    }

    // MARK: - Session rebuild

    private func rebuild() {
        // 1. Collect sub-agent session IDs (have a parentSessionId)
        var childIds = Set<String>()
        for e in allEvents {
            if let pid = e.parentSessionId, !pid.isEmpty {
                childIds.insert(e.sessionId)
            }
        }

        // 2. Group events by session_id, skipping children and empty ids.
        //    Sessions without a SessionStart are auto-created as stubs on first event.
        var sessionMap: [String: HookSession] = [:]

        func ensureSession(_ sid: String, firstEvent event: HookEvent) {
            guard sessionMap[sid] == nil else { return }
            sessionMap[sid] = HookSession(
                id: sid,
                cwd: event.cwd,
                model: event.model,
                startTs: event.ts,
                endTs: nil,
                status: .idle,
                lastUserPrompt: nil,
                lastAssistantMessage: nil,
                notableEvents: [],
                platform: event.agentPlatform,
                name: sessionNameCache[sid]
            )
        }

        for event in allEvents {
            let sid = event.sessionId
            guard !sid.isEmpty, !childIds.contains(sid) else { continue }

            switch event.event {
            case "SessionStart", "session":
                if sessionMap[sid] == nil {
                    sessionMap[sid] = HookSession(
                        id: sid,
                        cwd: event.cwd,
                        model: event.model,
                        startTs: event.ts,
                        endTs: nil,
                        status: .idle,
                        lastUserPrompt: nil,
                        lastAssistantMessage: nil,
                        notableEvents: [],
                        platform: event.agentPlatform,
                        name: sessionNameCache[sid]
                    )
                } else {
                    // update model if we now have it
                    if let m = event.model { sessionMap[sid]!.model = m }
                    // update name if cache has it
                    if let n = sessionNameCache[sid] { sessionMap[sid]!.name = n }
                }

            case "UserPromptSubmit":
                ensureSession(sid, firstEvent: event)
                sessionMap[sid]!.lastUserPrompt = event.summary?.isEmpty == false ? event.summary : nil
                if sessionMap[sid]!.status != .ended { sessionMap[sid]!.status = .working }

            case "PermissionRequest":
                ensureSession(sid, firstEvent: event)
                if sessionMap[sid]!.status != .ended { sessionMap[sid]!.status = .blocked }
                sessionMap[sid]!.notableEvents.append(event)

            case "PreToolUse":
                // Permission was granted — tool is now executing, unblock
                ensureSession(sid, firstEvent: event)
                if sessionMap[sid]!.status == .blocked { sessionMap[sid]!.status = .working }

            case "Stop", "stop":
                ensureSession(sid, firstEvent: event)
                if sessionMap[sid]!.status != .ended { sessionMap[sid]!.status = .idle }
                if let s = event.summary, !s.isEmpty { sessionMap[sid]!.lastAssistantMessage = s }

            case "StopFailure":
                ensureSession(sid, firstEvent: event)
                sessionMap[sid]!.notableEvents.append(event)

            case "Notification":
                ensureSession(sid, firstEvent: event)
                sessionMap[sid]!.notableEvents.append(event)

            case "SessionEnd":
                ensureSession(sid, firstEvent: event)
                sessionMap[sid]!.status = .ended
                sessionMap[sid]!.endTs = event.ts

            default:
                break
            }
        }

        // 3. Find currentProjectCwd: most recent session's cwd (with or without SessionStart)
        let latestEvent = allEvents
            .filter { !childIds.contains($0.sessionId) && !$0.sessionId.isEmpty && !$0.cwd.isEmpty }
            .max(by: { $0.ts < $1.ts })
        currentProjectCwd = latestEvent?.cwd

        // 4. Show every live session independently (no cwd dedup).
        //    If no pending permission request in socket server, downgrade stale blocked → idle
        //    so all downstream consumers see the real status.
        let hasRealPending = AgentSocketServer.shared.pendingPermission != nil
        if !hasRealPending {
            for key in sessionMap.keys where sessionMap[key]!.status == .blocked {
                sessionMap[key]!.status = .idle
            }
        }

        filteredSessions = sessionMap.values
            .filter { $0.status.isLive }
            .sorted { $0.startTs > $1.startTs }
            .prefix(20)
            .map { $0 }

        // Detect notifiable status transitions and fire callback
        for session in sessionMap.values where session.status.isLive {
            let prev = previousStatuses[session.id]
            let curr = session.status
            if prev != curr {
                // Notify on: any → blocked, working/blocked → idle (= Stop after work).
                // External-decision dismiss is handled by the socket server's PostToolUse
                // hijack instead — relying on this status transition is unreliable when
                // a session fires another PermissionRequest immediately after the first
                // (rebuild snaps prev=blocked, curr=blocked and skips the working pulse).
                var shouldNotify: Bool = {
                    if curr == .blocked { return true }
                    if curr == .idle, let p = prev, p == .working || p == .blocked { return true }
                    return false
                }()
                // Suppress the spurious "completion" pop that fires when a PostToolUse
                // hijack drops pendingPermission to nil — the subsequent stale-blocked
                // downgrade snaps the session to idle, which would otherwise look like
                // the session finished.
                if shouldNotify, curr == .idle, suppressNextIdleNotice.remove(session.id) != nil {
                    shouldNotify = false
                }
                if shouldNotify {
                    onNotifiableStatusChange?(session.id, session.cwd, curr, session.cwdBasename)
                }
            }
        }
        // Update tracked statuses
        previousStatuses = Dictionary(
            uniqueKeysWithValues: sessionMap.values.map { ($0.id, $0.status) }
        )
    }

    // MARK: - Parsing

    /// Called from background queue — nonisolated so no @MainActor warning.
    private nonisolated static func parseLines(nonisolated text: String) -> [HookEvent] {
        let decoder = JSONDecoder()
        return text
            .components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .compactMap { line -> HookEvent? in
                guard let data = line.data(using: .utf8) else { return nil }
                return try? decoder.decode(HookEvent.self, from: data)
            }
    }
}
