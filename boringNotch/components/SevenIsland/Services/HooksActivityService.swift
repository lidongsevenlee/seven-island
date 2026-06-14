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
        if !FileManager.default.fileExists(atPath: logPath) {
            FileManager.default.createFile(atPath: logPath, contents: nil)
        }
        let fd = open(logPath, O_EVTONLY)
        guard fd >= 0 else { return }
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
                notableEvents: []
            )
        }

        for event in allEvents {
            let sid = event.sessionId
            guard !sid.isEmpty, !childIds.contains(sid) else { continue }

            switch event.event {
            case "SessionStart":
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
                        notableEvents: []
                    )
                } else {
                    // update model if we now have it
                    if let m = event.model { sessionMap[sid]!.model = m }
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

            case "Stop":
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

        // 4. Per-cwd dedup: pick the single session that best represents this cwd.
        //    Score (higher = better): working=3, blocked=2, idle=1, ended=0.
        //    Tiebreak: has messages > no messages, then most recent lastEventTs.
        func statusScore(_ s: HookSession) -> Int {
            switch s.status {
            case .working: return 3
            case .blocked: return 2
            case .idle:    return 1
            case .ended:   return 0
            }
        }
        func hasMessages(_ s: HookSession) -> Bool {
            s.lastUserPrompt != nil || s.lastAssistantMessage != nil
        }
        // Track most recent event timestamp per session for tiebreak
        var lastEventTs: [String: Double] = [:]
        for e in allEvents where !e.sessionId.isEmpty {
            lastEventTs[e.sessionId] = max(lastEventTs[e.sessionId] ?? 0, e.ts)
        }

        // If no pending permission request in socket server, downgrade stale blocked → idle
        // in sessionMap *before* bestPerCwd so all downstream consumers see the real status.
        let hasRealPending = AgentSocketServer.shared.pendingPermission != nil
        if !hasRealPending {
            for key in sessionMap.keys where sessionMap[key]!.status == .blocked {
                sessionMap[key]!.status = .idle
            }
        }

        var bestPerCwd: [String: HookSession] = [:]
        for session in sessionMap.values {
            let key = session.cwd
            guard let existing = bestPerCwd[key] else {
                bestPerCwd[key] = session; continue
            }
            let sScore = statusScore(session)
            let eScore = statusScore(existing)
            let newWins: Bool = {
                if sScore != eScore { return sScore > eScore }
                if hasMessages(session) != hasMessages(existing) { return hasMessages(session) }
                // both equal — prefer the one with the most recent activity
                let sTs = lastEventTs[session.id] ?? session.startTs
                let eTs = lastEventTs[existing.id] ?? existing.startTs
                return sTs > eTs
            }()
            if newWins { bestPerCwd[key] = session }
        }

        // 5. Message fallback: if winner has no messages, borrow from most active sibling.
        let allByCwd = Dictionary(grouping: sessionMap.values, by: { $0.cwd })
        for cwd in bestPerCwd.keys {
            guard var best = bestPerCwd[cwd], !hasMessages(best) else { continue }
            if let donor = allByCwd[cwd]?
                .filter({ $0.id != best.id && hasMessages($0) })
                .max(by: {
                    let aTs = lastEventTs[$0.id] ?? $0.startTs
                    let bTs = lastEventTs[$1.id] ?? $1.startTs
                    return aTs < bTs
                }) {
                best.lastUserPrompt = donor.lastUserPrompt
                best.lastAssistantMessage = donor.lastAssistantMessage
                bestPerCwd[cwd] = best
            }
        }

        filteredSessions = bestPerCwd.values
            .filter { $0.status.isLive }
            .sorted { $0.startTs > $1.startTs }
            .prefix(20)
            .map { $0 }

        // Detect notifiable status transitions and fire callback
        for session in sessionMap.values where session.status.isLive {
            let prev = previousStatuses[session.id]
            let curr = session.status
            if prev != curr {
                // Notify on: any → blocked, working/blocked → idle (= Stop after work)
                let shouldNotify: Bool = {
                    if curr == .blocked { return true }
                    if curr == .idle, let p = prev, p == .working || p == .blocked { return true }
                    return false
                }()
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
