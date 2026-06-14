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
            // socket path is just a real-time nudge — nothing extra needed here.

        case "permission":
            // Blocking: store request, wait for user to reply, then send response
            let payload = json["payload"] as? [String: Any] ?? [:]
            let req = PermissionRequest(
                sessionId:   payload["session_id"] as? String ?? "",
                cwd:         payload["cwd"] as? String ?? "",
                toolName:    payload["tool_name"] as? String ?? "",
                description: payload["description"] as? String ?? "",
                responseFD:  fd
            )
            Task { @MainActor in
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
            // fd stays open — will be closed by respond()

        default:
            close(fd)
        }
    }

    // MARK: - User responses

    /// User tapped "Allow"
    func allow() {
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
        let sessionId = req.sessionId
        pendingPermission = nil
        os_log(.info, "[AgentSocket] Sending response to fd=%d session=%@ message=%@", fd, sessionId, message.trimmingCharacters(in: .newlines))
        // Use a dedicated thread — the server queue is occupied by accept() loop
        DispatchQueue.global(qos: .userInitiated).async {
            // SO_NOSIGPIPE already set at accept() time; set again defensively
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
}

// MARK: - PermissionRequest model

struct PermissionRequest: Identifiable {
    let id = UUID()
    let sessionId: String
    let cwd: String
    let toolName: String
    let description: String
    let responseFD: Int32  // kept open until user responds or timeout

    var cwdBasename: String {
        URL(fileURLWithPath: cwd).lastPathComponent
    }
}
