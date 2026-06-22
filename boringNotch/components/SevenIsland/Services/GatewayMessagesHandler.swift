// GatewayMessagesHandler.swift
// Seven Island
//
// 阶段 C：处理 POST /v1/messages 请求，把 Anthropic Messages 协议转发到下游
// provider。支持流式（SSE）和非流式两种 body。
//
// 转发管线：
//   1. 取当前激活 GatewayProvider（来自 GatewayProviderService）
//   2. 读 client body，解析 JSON，把 `model` 字段改写为映射后的 upstream 名
//      （剥离 Claude Code 特有的 `[1m]` 后缀；查 provider.modelMappings）
//   3. 构造下游 URLRequest：POST baseUrl + /v1/messages，body 用改写后的 JSON
//   4. Header 透传 anthropic-version / anthropic-beta；Authorization 按 provider 的
//      authScheme 重写
//   5. stream=true 用 URLSession.bytes 字节流透传 SSE；否则用 URLSession.data 缓冲
//   6. 下游错误转 Anthropic 错误格式 {"type":"error","error":{...}}

import Foundation
import Hummingbird
import HTTPTypes
import NIOCore
import OSLog

private let osLogger = os.Logger(
    subsystem: "com.local.seven-island",
    category: "gateway.handler"
)

enum GatewayMessagesHandler {
    /// 入口：注册到 router.post("/v1/messages")
    static func handle(_ request: Request, context: some RequestContext) async throws -> Response {
        // 1. 取激活 provider（跨 actor 调用 —— MainActor）
        let activeProvider = await GatewayProviderService.shared.activeProvider
        guard let provider = activeProvider else {
            osLogger.error("no active provider")
            return errorResponse(
                status: .serviceUnavailable,
                type: "gateway_no_provider",
                message: "Seven Island gateway 未配置 active provider。请在 Settings → Claude 网关里添加并设为 Active。"
            )
        }

        // 2. 读 client body（10 MB 上限）
        let bodyBuffer: ByteBuffer
        do {
            bodyBuffer = try await request.body.collect(upTo: 10 * 1024 * 1024)
        } catch {
            return errorResponse(
                status: .badRequest,
                type: "invalid_request_error",
                message: "读取请求体失败：\(error.localizedDescription)"
            )
        }
        let bodyData = Data(buffer: bodyBuffer)

        // 3. 解析 JSON，改写 model 字段
        var jsonObject: [String: Any]
        do {
            jsonObject = try JSONSerialization.jsonObject(with: bodyData) as? [String: Any] ?? [:]
        } catch {
            return errorResponse(
                status: .badRequest,
                type: "invalid_request_error",
                message: "请求体不是合法 JSON：\(error.localizedDescription)"
            )
        }

        if let originalModel = jsonObject["model"] as? String {
            let mapped = mapModel(originalModel, provider: provider)
            jsonObject["model"] = mapped
            osLogger.info("model rewrite: \(originalModel, privacy: .public) → \(mapped, privacy: .public)")
        }
        let isStreaming = (jsonObject["stream"] as? Bool) == true

        let rewrittenBody: Data
        do {
            rewrittenBody = try JSONSerialization.data(withJSONObject: jsonObject)
        } catch {
            return errorResponse(
                status: .internalServerError,
                type: "gateway_internal_error",
                message: "改写请求体失败：\(error.localizedDescription)"
            )
        }

        // 4. 构造下游请求
        guard let upstreamURL = URL(string: provider.baseUrl.trimmingCharacters(in: .whitespaces) + "/v1/messages") else {
            return errorResponse(
                status: .internalServerError,
                type: "gateway_internal_error",
                message: "Provider baseUrl 无法构造 URL：\(provider.baseUrl)"
            )
        }
        var upstream = URLRequest(url: upstreamURL)
        upstream.httpMethod = "POST"
        upstream.setValue("application/json", forHTTPHeaderField: "content-type")
        upstream.setValue("application/json", forHTTPHeaderField: "accept")
        upstream.httpBody = rewrittenBody

        // 透传 anthropic 头
        for headerName in ["anthropic-version", "anthropic-beta"] {
            if let fieldName = HTTPField.Name(headerName),
               let value = request.headers[fieldName] {
                upstream.setValue(value, forHTTPHeaderField: headerName)
            }
        }
        // 默认 anthropic-version 兜底
        if upstream.value(forHTTPHeaderField: "anthropic-version") == nil {
            upstream.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        }

        // Authorization 按 authScheme 重写
        switch provider.authScheme.lowercased() {
        case "x-api-key":
            upstream.setValue(provider.apiKey, forHTTPHeaderField: "x-api-key")
        case "bearer", "":
            upstream.setValue("Bearer \(provider.apiKey)", forHTTPHeaderField: "authorization")
        case "static":
            // 这是历史 Claude Desktop profile 的字段值，不是 HTTP 标准。
            // 多数情况下网关会用 Bearer，先按 Bearer 写兜底。
            upstream.setValue("Bearer \(provider.apiKey)", forHTTPHeaderField: "authorization")
        default:
            // 用户自定义 scheme —— 直接当 Authorization 头值
            upstream.setValue("\(provider.authScheme) \(provider.apiKey)",
                              forHTTPHeaderField: "authorization")
        }

        osLogger.info("→ \(provider.name, privacy: .public) (\(upstreamURL.absoluteString, privacy: .public)) stream=\(isStreaming)")

        // 5. 转发
        if isStreaming {
            return try await streamResponse(upstream: upstream)
        } else {
            return try await bufferResponse(upstream: upstream)
        }
    }

    // MARK: - Model mapping

    /// 把客户端发来的 model 名映射成下游能识别的名字。
    /// 规则：
    ///   1. 剥离 Claude Code 特有的 `[1m]` 后缀（指示 1M context）
    ///   2. provider 开了 useModelDiscovery 时跳过查表，直接透传
    ///   3. 在 modelMappings 里找 claudeModel == 入参，若 upstreamModel 非空则用之
    ///   4. 否则原样透传
    static func mapModel(_ original: String, provider: GatewayProvider) -> String {
        let stripped = original.replacingOccurrences(
            of: #"\[1m\]$"#,
            with: "",
            options: .regularExpression
        )
        if provider.useModelDiscovery { return stripped }
        if let mapping = provider.modelMappings.first(where: { $0.claudeModel == stripped }),
           !mapping.upstreamModel.trimmingCharacters(in: .whitespaces).isEmpty {
            return mapping.upstreamModel
        }
        return stripped
    }

    // MARK: - Non-streaming forwarding

    private static func bufferResponse(upstream: URLRequest) async throws -> Response {
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: upstream)
        } catch {
            osLogger.error("upstream network error: \(error.localizedDescription, privacy: .public)")
            return errorResponse(
                status: .badGateway,
                type: "gateway_upstream_error",
                message: "下游请求失败：\(error.localizedDescription)"
            )
        }
        let httpResponse = response as? HTTPURLResponse
        let status = HTTPResponse.Status(code: httpResponse?.statusCode ?? 502)

        var headers = HTTPFields()
        // 透传 content-type / x-request-id 之类
        if let contentType = httpResponse?.value(forHTTPHeaderField: "content-type") {
            headers[.contentType] = contentType
        } else {
            headers[.contentType] = "application/json"
        }

        return Response(
            status: status,
            headers: headers,
            body: ResponseBody(byteBuffer: ByteBuffer(data: data))
        )
    }

    // MARK: - Streaming forwarding (SSE 透传)

    /// 用 URLSession.bytes 异步拉下游字节流，逐个 ByteBuffer 写到 client。
    /// Hummingbird 的 ResponseBody closure 形态保证不缓冲：写一块 flush 一块。
    private static func streamResponse(upstream: URLRequest) async throws -> Response {
        let (asyncBytes, response): (URLSession.AsyncBytes, URLResponse)
        do {
            (asyncBytes, response) = try await URLSession.shared.bytes(for: upstream)
        } catch {
            osLogger.error("upstream stream error: \(error.localizedDescription, privacy: .public)")
            return errorResponse(
                status: .badGateway,
                type: "gateway_upstream_error",
                message: "下游连接失败：\(error.localizedDescription)"
            )
        }
        let httpResponse = response as? HTTPURLResponse
        let status = HTTPResponse.Status(code: httpResponse?.statusCode ?? 502)

        var headers = HTTPFields()
        headers[.contentType] = httpResponse?.value(forHTTPHeaderField: "content-type") ?? "text/event-stream"
        headers[.cacheControl] = "no-cache"

        // 用 closure 形式的 ResponseBody —— Hummingbird 拿到每个 ByteBuffer 立刻 flush，
        // 实现真正的 SSE streaming。
        let body = ResponseBody { writer in
            // URLSession.AsyncBytes 是 UInt8 流。我们按 4 KB 攒批后 flush，
            // 既避免 per-byte overhead，也保证 SSE 每个事件能尽快传到 client。
            var batch: [UInt8] = []
            batch.reserveCapacity(4096)
            do {
                for try await byte in asyncBytes {
                    batch.append(byte)
                    // SSE 事件之间用 \n\n 分隔，遇到 \n 时就 flush 当前批次
                    // —— 这样一行内不会卡缓冲，每个事件能及时到客户端
                    if byte == 0x0A /* '\n' */ || batch.count >= 4096 {
                        try await writer.write(ByteBuffer(bytes: batch))
                        batch.removeAll(keepingCapacity: true)
                    }
                }
                // 收尾：flush 剩余字节
                if !batch.isEmpty {
                    try await writer.write(ByteBuffer(bytes: batch))
                }
                try await writer.finish(nil)
            } catch {
                osLogger.error("stream write error: \(error.localizedDescription, privacy: .public)")
                // 在已经发了 status 后只能 abort 连接；finish(nil) 让 client 看到提前结束
                try? await writer.finish(nil)
            }
        }

        return Response(status: status, headers: headers, body: body)
    }

    // MARK: - Error helpers

    /// 返回 Anthropic 风格的错误 JSON：
    ///   { "type": "error", "error": { "type": "<type>", "message": "<msg>" } }
    private static func errorResponse(
        status: HTTPResponse.Status,
        type: String,
        message: String
    ) -> Response {
        let payload: [String: Any] = [
            "type": "error",
            "error": ["type": type, "message": message]
        ]
        let data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
        var headers = HTTPFields()
        headers[.contentType] = "application/json"
        return Response(
            status: status,
            headers: headers,
            body: ResponseBody(byteBuffer: ByteBuffer(data: data))
        )
    }
}
