// ClaudeGatewayService.swift
// Seven Island
//
// 本地 HTTP gateway 服务（替代 CC Switch）。监听 127.0.0.1:gatewayPort（默认 15722），
// 接收 Claude Desktop / Claude Code 发来的 Anthropic Messages 请求，按当前激活的
// GatewayProvider 转发到下游。
//
// 阶段 B：骨架 + `/health` 路由 + 端口探测。阶段 C 会追加 `POST /v1/messages` 路由。
//
// 设计要点：
//   - `@MainActor` 类负责 status 状态机；`nonisolated start()` 把 Hummingbird 主循环
//     扔到 `Task.detached` 上后台跑，不阻塞 MainActor。
//   - `start()/stop()` 严格幂等：重复 start 不会起多个 listener，stop 会 cancel 当前 task。
//   - 启动前用 NWConnection 探测端口是否被占用，避免 Hummingbird bind 失败抛错信息不友好。

import Defaults
import Foundation
import Hummingbird
import Logging   // swift-log；本文件里用其全限定名 `Logging.Logger` 避免和 OSLog.Logger 冲突
import Network
import OSLog

// 命名说明：
//   - OSLog.Logger 用于把日志写到统一 subsystem（com.local.seven-island）。文件内
//     主要的 logging 都通过它，访问时直接 `osLogger.info(...)`。
//   - Logging.Logger（swift-log）只在创建 Hummingbird Application 时用一次，构造
//     函数显式写完整命名空间。
private let osLogger = os.Logger(
    subsystem: "com.local.seven-island",
    category: "gateway"
)

// MARK: - Status

enum GatewayStatus: Equatable {
    case stopped
    case starting
    case listening(port: Int)
    case failed(String)

    var isRunning: Bool {
        if case .listening = self { return true }
        return false
    }
}

// MARK: - Service

@MainActor
final class ClaudeGatewayService: ObservableObject {
    static let shared = ClaudeGatewayService()

    @Published private(set) var status: GatewayStatus = .stopped

    /// 在跑的 server task。stop() 时 cancel 它触发 Hummingbird graceful shutdown。
    private var serverTask: Task<Void, Never>?

    private init() {}

    // MARK: - Public API

    /// 启动 gateway。已运行时是 no-op。
    nonisolated func start() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            if case .starting = self.status { return }
            if case .listening = self.status { return }
            await self._start()
        }
    }

    /// 停止 gateway。已停止时是 no-op。
    func stop() {
        guard status != .stopped else { return }
        serverTask?.cancel()
        serverTask = nil
        status = .stopped
        osLogger.info("gateway stopped")
    }

    func restart() {
        stop()
        // 给一个 turn 让 NIO 释放 socket，再 start
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 200_000_000)
            self?.start()
        }
    }

    // MARK: - Internal

    private func _start() async {
        let port = Defaults[.gatewayPort]
        status = .starting

        // 端口被占探测：在 bind 前先试连，能连上 = 已有进程在 LISTEN。
        if await Self.isPortOccupied(port: port) {
            let msg = "端口 \(port) 已被占用（CC Switch / 其他进程在跑？）"
            osLogger.error("\(msg)")
            status = .failed(msg)
            return
        }

        // 路由表
        let router = Router()
        router.get("/health") { _, _ in
            return HealthResponse(status: "ok", port: port)
        }
        // Anthropic Messages 转发（阶段 C）
        router.post("/v1/messages") { request, context in
            try await GatewayMessagesHandler.handle(request, context: context, isOpenAIPath: false)
        }
        // OpenAI chat completions endpoint
        // 当请求直接访问此路径时，说明请求已是 OpenAI 格式，直接透传
        router.post("/v1/chat/completions") { request, context in
            try await GatewayMessagesHandler.handle(request, context: context, isOpenAIPath: true)
        }

        // Hummingbird Application。监听 127.0.0.1 不暴露外网。
        let app = Application(
            router: router,
            configuration: .init(
                address: .hostname("127.0.0.1", port: port),
                serverName: "seven-island-gateway"
            ),
            logger: makeHBLogger()
        )

        status = .listening(port: port)
        osLogger.info("gateway listening on 127.0.0.1:\(port)")

        // 后台 Task 跑 server。Task.detached 让它脱离 MainActor，避免阻塞 UI。
        serverTask = Task.detached(priority: .utility) {
            do {
                try await app.runService()
            } catch is CancellationError {
                // 正常 stop 路径，不打错误
            } catch {
                await MainActor.run {
                    osLogger.error("gateway crashed: \(error.localizedDescription)")
                    ClaudeGatewayService.shared.status = .failed(error.localizedDescription)
                }
            }
        }
    }

    /// 用 NWConnection 探测 127.0.0.1:port 是否有人监听。
    /// 1 秒超时，能 .ready = 占用，.failed/.waiting = 空闲。
    private static func isPortOccupied(port: Int) async -> Bool {
        await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
                cont.resume(returning: false); return
            }
            let conn = NWConnection(host: "127.0.0.1", port: nwPort, using: .tcp)
            let queue = DispatchQueue.global(qos: .utility)
            var resumed = false
            let resumeOnce: (Bool) -> Void = { occupied in
                guard !resumed else { return }
                resumed = true
                conn.cancel()
                cont.resume(returning: occupied)
            }
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready: resumeOnce(true)
                case .failed, .waiting, .cancelled: resumeOnce(false)
                default: break
                }
            }
            conn.start(queue: queue)
            // 兜底：1 秒还没结论就认作空闲
            queue.asyncAfter(deadline: .now() + 1.0) { resumeOnce(false) }
        }
    }

    /// Hummingbird 要求 swift-log 的 Logger（`Logging.Logger`）。
    /// 默认 stdout 后端在调试时够用；正式可装 LoggingOSLog 桥到 os_log。
    private func makeHBLogger() -> Logging.Logger {
        var logger = Logging.Logger(label: "com.local.seven-island.gateway")
        logger.logLevel = .info
        return logger
    }
}

// MARK: - Response types

private struct HealthResponse: ResponseEncodable, Codable {
    let status: String
    let port: Int
}
