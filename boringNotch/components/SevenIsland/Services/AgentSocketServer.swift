//
//  AgentSocketServer.swift
//  boringNotch
//
//  Unix domain socket server at ~/.seven-island/agent.sock.
//  Receives hook notifications from seven-island.sh and routes them:
//  - action "hook"       → fire-and-forget update to HooksActivityService
//  - action "permission" → present approval UI, block until user decides
//

import Foundation
import os.log

@MainActor
final class AgentSocketServer: ObservableObject {
    static let shared = AgentSocketServer()

    // Pending permission request waiting for a user decision
    @Published private(set) var pendingPermission: PermissionRequest? = nil

    nonisolated let socketPath = NSHomeDirectory() + "/.seven-island/agent.sock"
    private let queue = DispatchQueue(label: "com.local.seven-island.socket-server", qos: .utility)

    /// Permission requests "approved for this session" — keyed by
    /// `PermissionTarget.sessionAllowKey`. Process-only memory: cleared when
    /// the app restarts, matching the user's mental model of "this session".
    private var sessionAllowCache: Set<String> = []

    private init() {}

    // MARK: - Lifecycle

    nonisolated func start() {
        let path = socketPath
        let q = queue
        q.async { self.runServer(socketPath: path) }
    }

    private nonisolated func runServer(socketPath: String) {
        // Remove stale socket file
        unlink(socketPath)

        // Create socket
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }

        // Bind
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: 108) { cptr in
                _ = strlcpy(cptr, socketPath, 108)
            }
        }
        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { saddr in
                bind(fd, saddr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else { close(fd); return }

        // Listen
        guard listen(fd, 16) == 0 else { close(fd); unlink(socketPath); return }

        // Accept loop
        while true {
            var clientAddr = sockaddr_un()
            var addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
            let clientFD = withUnsafeMutablePointer(to: &clientAddr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { saddr in
                    accept(fd, saddr, &addrLen)
                }
            }
            guard clientFD >= 0 else {
                // Server was closed
                break
            }
            // Suppress SIGPIPE immediately — if the client disconnects before we respond,
            // send() returns EPIPE instead of killing the process.
            var on: Int32 = 1
            setsockopt(clientFD, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            // Handle each connection on a separate thread so accept() loop keeps running
            DispatchQueue.global(qos: .userInitiated).async {
                self.handleConnection(clientFD)
            }
        }
    }

    // MARK: - Connection handler

    private nonisolated func handleConnection(_ fd: Int32) {
        // Read all data until EOF
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = recv(fd, &buf, buf.count, 0)
            if n <= 0 { break }
            data.append(contentsOf: buf[..<n])
            if data.contains(0x0A) { break } // newline = end of message
        }

        guard let text = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              let msgData = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: msgData) as? [String: Any],
              let action = json["action"] as? String else {
            close(fd)
            return
        }

        switch action {
        case "hook":
            // Fire-and-forget: update JSONL-based service
            close(fd)
            // DispatchSource in HooksActivityService already handles file changes;
            // socket path is just a real-time nudge — except we hijack PostToolUse
            // to dismiss any pending banner whose corresponding hook fd is dangling
            // because the user approved/denied via Claude Code's terminal UI.
            // PostToolUse fires immediately after the tool runs, so this is the
            // first reliable signal that the permission for that session is resolved.
            let payload = json["payload"] as? [String: Any] ?? [:]
            let event = payload["event"] as? String ?? ""
            let sessionId = payload["session_id"] as? String ?? ""
            if event == "PostToolUse", !sessionId.isEmpty {
                Task { @MainActor in
                    if let pending = self.pendingPermission, pending.sessionId == sessionId {
                        self.dismissForExternalDecision()
                        ClaudeHookNotificationState.shared.isBlocked = false
                        BoringViewCoordinator.shared.toggleExpandingView(
                            status: false,
                            type: .claudeHook,
                            value: 0
                        )
                        // The next rebuild will see pendingPermission == nil and snap this
                        // session's stale blocked → idle, which would normally fire a
                        // misleading "<cwd> 已完成" banner. Tell the service to ignore
                        // that one specific transition.
                        HooksActivityService.shared.suppressNextIdleNotification(forSessionId: sessionId)
                    }
                }
            }

        case "permission":
            // Blocking: store request, wait for user to reply, then send response
            let payload = json["payload"] as? [String: Any] ?? [:]
            let target = PermissionTarget(
                toolName:  payload["tool_name"] as? String ?? "",
                toolInput: payload["tool_input"] as? [String: Any] ?? [:]
            )
            let req = PermissionRequest(
                sessionId:   payload["session_id"] as? String ?? "",
                cwd:         payload["cwd"] as? String ?? "",
                toolName:    target.toolName,
                description: payload["description"] as? String ?? "",
                target:      target,
                responseFD:  fd
            )
            // Session-allow fast path: if the user previously chose "allow for
            // this session" for this exact target, silently allow without
            // surfacing a banner.
            let sessionKey = target.sessionAllowKey(sessionId: req.sessionId)
            Task { @MainActor in
                if !req.sessionId.isEmpty, self.sessionAllowCache.contains(sessionKey) {
                    os_log(.info, "[AgentSocket] Session-cached allow fd=%d session=%@ pattern=%@",
                           fd, req.sessionId, target.persistentAllowPattern())
                    self.sendRaw("allow\n", fd: fd)
                    return
                }
                // If a previous request is still pending, close its fd and deny it
                // so the old agent doesn't hang forever.
                if let old = self.pendingPermission {
                    os_log(.error, "[AgentSocket] Overwriting pending permission fd=%d session=%@ — old agent will be denied", old.responseFD, old.sessionId)
                    let oldFD = old.responseFD
                    DispatchQueue.global(qos: .userInitiated).async {
                        var on: Int32 = 1
                        setsockopt(oldFD, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
                        _ = send(oldFD, "deny\n", 5, 0)
                        close(oldFD)
                    }
                }
                self.pendingPermission = req
                // Show the notch banner — socket-only requests don't have a
                // corresponding JSONL entry, so onNotifiableStatusChange won't fire.
                ClaudeHookNotificationState.shared.label = "\(req.cwdBasename) 需要授权"
                ClaudeHookNotificationState.shared.isBlocked = true
                BoringViewCoordinator.shared.toggleExpandingView(
                    status: true,
                    type: .claudeHook,
                    value: 1
                )
            }
            // fd stays open — will be closed by respond() or sendRaw()

        default:
            close(fd)
        }
    }

    // MARK: - User responses

    /// User tapped "Allow once"
    func allow() {
        respond("allow\n")
    }

    /// User tapped "Allow for this session" — caches the (session, pattern)
    /// key so future identical PermissionRequests are auto-approved on the
    /// fast path inside `handleConnection`.
    func allowForSession() {
        if let req = pendingPermission, !req.sessionId.isEmpty {
            sessionAllowCache.insert(req.target.sessionAllowKey(sessionId: req.sessionId))
        }
        respond("allow\n")
    }

    /// User tapped "Allow permanently". Append the pattern to the project's
    /// `.claude/settings.local.json`. If the write fails (no permission, IO
    /// error), fall back to session-scoped allow so the user is never stuck.
    func allowPersistently() {
        guard let req = pendingPermission else {
            os_log(.error, "[AgentSocket] allowPersistently called but pendingPermission is nil")
            return
        }
        let pattern = req.target.persistentAllowPattern()
        let ok = PermissionPolicyStore.shared.appendPersistentAllow(pattern: pattern, cwd: req.cwd)
        if !ok {
            os_log(.error, "[AgentSocket] Persistent allow write failed — falling back to session allow pattern=%@", pattern)
            sessionAllowCache.insert(req.target.sessionAllowKey(sessionId: req.sessionId))
        }
        respond("allow\n")
    }

    /// User tapped "Deny" (no reason)
    func deny() {
        respond("deny\n")
    }

    /// User tapped "Deny" with a custom reason
    func deny(reason: String) {
        let cleaned = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        respond(cleaned.isEmpty ? "deny\n" : "deny:\(cleaned)\n")
    }

    private func respond(_ message: String) {
        guard let req = pendingPermission else {
            os_log(.error, "[AgentSocket] respond called but pendingPermission is nil — agent may hang")
            return
        }
        let fd = req.responseFD
        pendingPermission = nil
        sendRaw(message, fd: fd)
    }

    /// Write a response message to a specific fd and close it. Used by both
    /// `respond()` (with the pending request's fd) and the session-allow fast
    /// path (with the just-accepted fd, before any banner is shown).
    fileprivate func sendRaw(_ message: String, fd: Int32) {
        os_log(.info, "[AgentSocket] Sending response to fd=%d message=%@", fd, message.trimmingCharacters(in: .newlines))
        DispatchQueue.global(qos: .userInitiated).async {
            var on: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            let bytes = Array(message.utf8)
            let sent = send(fd, bytes, bytes.count, 0)
            if sent < 0 {
                os_log(.error, "[AgentSocket] send() failed fd=%d errno=%d — agent may hang", fd, errno)
            } else {
                os_log(.info, "[AgentSocket] Sent %d bytes to fd=%d", sent, fd)
            }
            close(fd)
        }
    }

    /// Drop the pending request without sending allow/deny — used when the user
    /// approved/denied via an external surface (e.g. Claude Code's terminal UI)
    /// and Claude has already acted on it. Closing the fd lets the hook helper
    /// recv() return 0 and exit; its stdout decision JSON is irrelevant because
    /// Claude has stopped reading it.
    func dismissForExternalDecision() {
        guard let req = pendingPermission else { return }
        let fd = req.responseFD
        let sessionId = req.sessionId
        pendingPermission = nil
        os_log(.info, "[AgentSocket] External decision detected — closing fd=%d session=%@ without response", fd, sessionId)
        DispatchQueue.global(qos: .userInitiated).async {
            close(fd)
        }
    }
}

// MARK: - PermissionRequest model

struct PermissionRequest: Identifiable {
    let id = UUID()
    let sessionId: String
    let cwd: String
    let toolName: String
    let description: String
    let target: PermissionTarget
    let responseFD: Int32  // kept open until user responds or timeout

    var cwdBasename: String {
        URL(fileURLWithPath: cwd).lastPathComponent
    }
}
