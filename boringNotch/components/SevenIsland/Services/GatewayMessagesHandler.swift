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
    // MARK: - Upstream URLSession
    //
    // 转发不能用 URLSession.shared —— 它的默认 timeoutIntervalForRequest 是 60s，
    // 语义是"两段数据之间最多等多久"。Claude 复杂请求（长 thinking + 长输出）
    // 首字节经常 >60s 才到，shared session 会主动抛 NSURLErrorTimedOut，被下面的
    // catch 转成 502「下游请求失败」—— 这就是 cc-switch（reqwest 默认无请求超时）
    // 不超时、本网关超时的根因。
    //
    // 这里建一个专用 session 把超时放宽到对齐 reqwest 的"基本不限"：
    //   - timeoutIntervalForRequest  = 600s：容忍下游长时间 thinking 不吐数据
    //   - timeoutIntervalForResource = 3600s：单个请求的硬上限兜底（防永久挂起）
    //   - waitsForConnectivity = true：临时断网时等待而非立刻失败
    private static let upstreamSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 600
        config.timeoutIntervalForResource = 3600
        config.waitsForConnectivity = true
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    // MARK: - Protocol helpers

    /// 根据 provider 协议类型决定下游 endpoint 路径。
    private static func downstreamPath(for provider: GatewayProvider) -> String {
        switch provider.protocolType.lowercased() {
        case "openai":
            return "/v1/chat/completions"
        default:
            return "/v1/messages"
        }
    }

    /// 将 Anthropic Messages 请求体转为 OpenAI Chat Completions 请求体
    private static func anthropicToOpenAIRequest(_ anthropic: [String: Any]) -> [String: Any] {
        var openai: [String: Any] = [:]
        openai["model"] = anthropic["model"] ?? ""
        var messages: [[String: Any]] = []
        if let system = anthropic["system"] as? String, !system.isEmpty {
            messages.append(["role": "system", "content": system])
        }
        if let anthropicMessages = anthropic["messages"] as? [[String: Any]] {
            for msg in anthropicMessages {
                guard let role = msg["role"] as? String else { continue }
                var content = ""
                if let text = msg["content"] as? String {
                    content = text
                } else if let array = msg["content"] as? [[String: Any]] {
                    content = array.compactMap { $0["text"] as? String }.joined()
                }
                messages.append(["role": role, "content": content])
            }
        }
        openai["messages"] = messages
        if let maxTokens = anthropic["max_tokens"] { openai["max_tokens"] = maxTokens }
        if let temperature = anthropic["temperature"] { openai["temperature"] = temperature }
        if let stream = anthropic["stream"] as? Bool { openai["stream"] = stream }
        return openai
    }

    /// 将 OpenAI chat.completions 非流式响应转为 Anthropic message 格式
    private static func openAIToAnthropicResponse(_ openaiJSON: Any) -> [String: Any] {
        guard let openai = openaiJSON as? [String: Any] else {
            return ["type": "error", "error": ["type": "invalid_response", "message": "下游返回了非 JSON 内容"]]
        }
        var anthropic: [String: Any] = [:]
        anthropic["type"] = "message"
        anthropic["role"] = "assistant"
        anthropic["id"] = openai["id"] ?? "msg_\(UUID().uuidString)"
        var contentText = ""
        if let choices = openai["choices"] as? [[String: Any]], let first = choices.first {
            if let message = first["message"] as? [String: Any] {
                contentText = message["content"] as? String ?? ""
            } else if let text = first["text"] as? String { contentText = text }
        }
        anthropic["content"] = [["type": "text", "text": contentText]]
        if let usage = openai["usage"] as? [String: Any] {
            anthropic["usage"] = ["input_tokens": usage["prompt_tokens"] ?? 0, "output_tokens": usage["completion_tokens"] ?? 0]
        }
        if let model = openai["model"] as? String { anthropic["model"] = model }
        return anthropic
    }

    /// 将 OpenAI 流式 SSE chunk 转为 Anthropic SSE chunk
    private static func convertOpenAIStreamChunk(_ openaiChunk: [String: Any]) -> [String: Any]? {
        guard let choices = openaiChunk["choices"] as? [[String: Any]], let first = choices.first else { return nil }
        var anthropic: [String: Any] = [:]
        if let finishReason = first["finish_reason"] as? String, !finishReason.isEmpty {
            anthropic["type"] = "message_stop"
            return anthropic
        }
        if let delta = first["delta"] as? [String: Any], let content = delta["content"] as? String, !content.isEmpty {
            anthropic["type"] = "content_block_delta"
            anthropic["index"] = 0
            anthropic["delta"] = ["type": "text_delta", "text": content]
            return anthropic
        }
        return nil
    }
    // MARK: - Protocol helpers

    /// 根据 provider 协议类型构造请求体。
    /// 对于 openai provider，将 Anthropic 格式转成 OpenAI 格式。
    private static func buildRequestBody(
        anthropicBody: [String: Any],
        provider: GatewayProvider
    ) -> Data? {
        switch provider.protocolType.lowercased() {
        case "openai":
            let openaiBody = self.anthropicToOpenAIRequest(anthropicBody)
            return try? JSONSerialization.data(withJSONObject: openaiBody)
        default:
            return try? JSONSerialization.data(withJSONObject: anthropicBody)
        }
    }

    /// 根据 provider 协议类型转换下游响应数据。
    ///
    /// 转换仅在「客户端是 Anthropic（/v1/messages）且下游是 OpenAI」时发生：
    /// 下游 OpenAI 响应 → Anthropic message。其余组合原样透传：
    ///   - isOpenAIPath=true（客户端 OpenAI）：下游响应已是 OpenAI 格式，透传
    ///   - isOpenAIPath=false + anthropic provider：双方都是 Anthropic，透传
    ///
    /// 非 2xx 或非合法 chat.completion 响应（缺 choices）视为下游错误，
    /// 构造 Anthropic 风格错误体，避免把错误体伪装成空 content 的假成功。
    private static func convertResponseBody(
        data: Data,
        provider: GatewayProvider,
        status: HTTPResponse.Status,
        isOpenAIPath: Bool
    ) -> Data {
        // OpenAI 客户端走 /v1/chat/completions：下游响应已是 OpenAI 格式，原样透传（含错误）
        if isOpenAIPath { return data }
        // Anthropic 客户端：非 2xx 包装成 Anthropic 错误
        guard (200...299).contains(status.code) else {
            return makeDownstreamErrorResponse(data: data, status: status)
        }
        switch provider.protocolType.lowercased() {
        case "openai":
            guard let openaiJSON = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return data
            }
            // 下游错误体（如 {"error": {...}}）没有 choices 字段，
            // 不应当作成功 chat.completion 转换，否则会产出空 content 的假 message。
            guard openaiJSON["choices"] != nil else {
                return makeDownstreamErrorResponse(data: data, status: status)
            }
            let anthropicJSON = self.openAIToAnthropicResponse(openaiJSON)
            return (try? JSONSerialization.data(withJSONObject: anthropicJSON)) ?? data
        default:
            return data
        }
    }

    /// 把下游错误响应体包装成 Anthropic 风格错误 JSON：
    ///   {"type":"error","error":{"type":"api_error","message":"..."}}
    /// 兼容多种下游错误格式：
    ///   - OpenAI:    {"error":{"message":"..."}}
    ///   - 裸字符串:   {"error":"..."} / {"message":"..."}
    ///   - RFC 7807:  {"detail":"...","title":"..."}（NVIDIA/部分网关用这个）
    private static func makeDownstreamErrorResponse(data: Data, status: HTTPResponse.Status) -> Data {
        var message = "下游返回 HTTP \(status.code)"
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let err = json["error"] as? [String: Any], let msg = err["message"] as? String {
                message = msg
            } else if let err = json["error"] as? String {
                message = err
            } else if let msg = json["message"] as? String {
                message = msg
            } else if let detail = json["detail"] as? String, !detail.isEmpty {
                // RFC 7807 Problem Details（NVIDIA 等）
                message = detail
            } else if let title = json["title"] as? String, !title.isEmpty {
                message = title
            }
        } else if let text = String(data: data, encoding: .utf8), !text.isEmpty {
            message = text
        }
        let payload: [String: Any] = [
            "type": "error",
            "error": ["type": "api_error", "message": message]
        ]
        return (try? JSONSerialization.data(withJSONObject: payload)) ?? data
    }

    /// 根据 provider 协议类型转换流式 SSE 行。
    /// 对于 openai provider，将 OpenAI SSE 格式转成 Anthropic SSE 格式。
    private static func convertStreamLine(
        line: String,
        provider: GatewayProvider
    ) -> String? {
        switch provider.protocolType.lowercased() {
        case "openai":
            // OpenAI SSE format: data: {...}
            // Anthropic SSE format: event: ...\ndata: ...
            guard line.hasPrefix("data: ") else { return line }
            let jsonStr = String(line.dropFirst(6))
            guard let jsonData = jsonStr.data(using: .utf8),
                  let openaiChunk = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
                return line
            }
            guard let anthropicChunk = self.convertOpenAIStreamChunk(openaiChunk) else {
                return nil  // 跳过无法映射的行（如 [DONE]）
            }
            guard let anthropicData = try? JSONSerialization.data(withJSONObject: anthropicChunk) else {
                return nil
            }
            let eventName: String
            if let type = anthropicChunk["type"] as? String {
                eventName = type
            } else {
                eventName = "content_block_delta"
            }
            return "event: \(eventName)\ndata: \(String(data: anthropicData, encoding: .utf8) ?? "")"
        default:
            return line
        }
    }

    /// 入口：注册到 router.post("/v1/messages")
    static func handle(_ request: Request, context: some RequestContext, isOpenAIPath: Bool = false) async throws -> Response {
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
        }
        let isStreaming = (jsonObject["stream"] as? Bool) == true

        // 根据 provider 协议类型构造请求体
        // isOpenAIPath=true 时请求已经是 OpenAI 格式，直接透传
        let rewrittenBody: Data
        if isOpenAIPath {
            // 请求已是 OpenAI 格式，直接透传，不转换
            do {
                rewrittenBody = try JSONSerialization.data(withJSONObject: jsonObject)
            } catch {
                return errorResponse(
                    status: .internalServerError,
                    type: "gateway_internal_error",
                    message: "Failed to serialize request body: \(error.localizedDescription)"
                )
            }
        } else {
            // 请求是 Anthropic 格式，需要转换
            guard let body = buildRequestBody(anthropicBody: jsonObject, provider: provider) else {
                return errorResponse(
                    status: .internalServerError,
                    type: "gateway_internal_error",
                    message: "Failed to build request body for protocol \(provider.protocolType)"
                )
            }
            rewrittenBody = body
        }

        // 4. 构造下游请求
        let downstreamPath = self.downstreamPath(for: provider)
        guard let upstreamURL = URL(string: provider.baseUrl.trimmingCharacters(in: .whitespaces) + downstreamPath) else {
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

        // 透传 anthropic 头（仅 anthropic 协议）
        if provider.protocolType.lowercased() == "anthropic" {
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

        osLogger.info("→ \(provider.name, privacy: .public) (\(upstreamURL.absoluteString, privacy: .public)) stream=\(isStreaming) protocol=\(provider.protocolType)")

        // 5. 转发
        if isStreaming {
            return try await streamResponse(upstream: upstream, provider: provider, isOpenAIPath: isOpenAIPath)
        } else {
            return try await bufferResponse(upstream: upstream, provider: provider, isOpenAIPath: isOpenAIPath)
        }
    }

    // MARK: - Model mapping

    /// 把客户端发来的 model 名映射成下游能识别的名字。
    /// 规则：
    ///   1. 剥离 Claude Code 特有的 `[1m]` 后缀（指示 1M context），并去首尾空白
    ///   2. provider 开了 useModelDiscovery 时跳过查表，直接透传
    ///   3. 先精确匹配（忽略大小写/空白）；命中且 upstreamModel 非空则用之
    ///   4. 再做前缀匹配 —— 处理带日期/版本后缀的名字
    ///      （如 claude-haiku-4-5-20251001 命中 claude-haiku-4-5）
    ///   5. 都没命中则原样透传，并记录可用映射表便于排查
    static func mapModel(_ original: String, provider: GatewayProvider) -> String {
        let stripped = original.replacingOccurrences(
            of: #"\[1m\]$"#,
            with: "",
            options: .regularExpression
        ).trimmingCharacters(in: .whitespaces)

        if provider.useModelDiscovery {
            osLogger.info("model passthrough (useModelDiscovery=true): \(stripped, privacy: .public)")
            return stripped
        }

        let normalized = stripped.lowercased()

        // 3. 精确匹配（忽略大小写/首尾空白）
        if let exact = provider.modelMappings.first(where: {
            $0.claudeModel.trimmingCharacters(in: .whitespaces).lowercased() == normalized
        }), !exact.upstreamModel.trimmingCharacters(in: .whitespaces).isEmpty {
            let mapped = exact.upstreamModel.trimmingCharacters(in: .whitespaces)
            osLogger.info("model rewrite: \(stripped, privacy: .public) → \(mapped, privacy: .public) (exact)")
            return mapped
        }

        // 4. 前缀匹配：claude-haiku-4-5-20251001 → claude-haiku-4-5
        if let prefixed = provider.modelMappings.first(where: { mapping -> Bool in
            let key = mapping.claudeModel.trimmingCharacters(in: .whitespaces).lowercased()
            guard !key.isEmpty,
                  !mapping.upstreamModel.trimmingCharacters(in: .whitespaces).isEmpty else {
                return false
            }
            return normalized == key || normalized.hasPrefix(key + "-")
        }) {
            let mapped = prefixed.upstreamModel.trimmingCharacters(in: .whitespaces)
            osLogger.info("model rewrite: \(stripped, privacy: .public) → \(mapped, privacy: .public) (prefix)")
            return mapped
        }

        // 5. 未命中：记录可用映射表，便于排查配置错配
        let keys = provider.modelMappings
            .map { $0.claudeModel.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
        osLogger.info("model rewrite miss: \(stripped, privacy: .public) → passthrough; known claudeModels=[\(keys, privacy: .public)] useModelDiscovery=\(provider.useModelDiscovery, privacy: .public)")
        return stripped
    }

    // MARK: - Non-streaming forwarding

    private static func bufferResponse(upstream: URLRequest, provider: GatewayProvider, isOpenAIPath: Bool) async throws -> Response {
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await upstreamSession.data(for: upstream)
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

        // 根据 provider 协议类型转换响应体（传入 status 和 isOpenAIPath 以区分成功/错误/客户端协议）
        let finalData = convertResponseBody(data: data, provider: provider, status: status, isOpenAIPath: isOpenAIPath)

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
            body: ResponseBody(byteBuffer: ByteBuffer(data: finalData))
        )
    }

    // MARK: - Streaming forwarding (SSE 透传)

    /// 用 URLSession.bytes 异步拉下游字节流，逐个 ByteBuffer 写到 client。
    /// Hummingbird 的 ResponseBody closure 形态保证不缓冲：写一块 flush 一块。
    private static func streamResponse(upstream: URLRequest, provider: GatewayProvider, isOpenAIPath: Bool) async throws -> Response {
        let (asyncBytes, response): (URLSession.AsyncBytes, URLResponse)
        do {
            (asyncBytes, response) = try await upstreamSession.bytes(for: upstream)
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

        // 非 2xx：下游返回错误，缓冲错误体后按客户端协议返回（不当 SSE 流处理）
        guard (200...299).contains(status.code) else {
            osLogger.error("upstream stream non-2xx status: \(status.code)")
            var errorBytes = [UInt8]()
            for try await byte in asyncBytes {
                errorBytes.append(byte)
                if errorBytes.count > 64 * 1024 { break }  // 64KB 上限，防极端情况
            }
            let errorData = Data(errorBytes)
            var errHeaders = HTTPFields()
            if isOpenAIPath {
                // OpenAI 客户端：原样透传下游错误体（已是 OpenAI 错误格式）
                errHeaders[.contentType] = httpResponse?.value(forHTTPHeaderField: "content-type") ?? "application/json"
                return Response(
                    status: status,
                    headers: errHeaders,
                    body: ResponseBody(byteBuffer: ByteBuffer(data: errorData))
                )
            } else {
                // Anthropic 客户端：包装成 Anthropic 风格错误
                errHeaders[.contentType] = "application/json"
                let wrapped = makeDownstreamErrorResponse(data: errorData, status: status)
                return Response(
                    status: status,
                    headers: errHeaders,
                    body: ResponseBody(byteBuffer: ByteBuffer(data: wrapped))
                )
            }
        }

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
                // 仅当客户端是 Anthropic（/v1/messages）且下游是 OpenAI 时需要逐行转换；
                // 其余组合（OpenAI 客户端 / Anthropic 下游）原样透传字节流。
                if !isOpenAIPath && provider.protocolType.lowercased() == "openai" {
                    var lineBuffer = ""
                    for try await byte in asyncBytes {
                        if let char = String(bytes: [byte], encoding: .utf8) {
                            lineBuffer.append(char)
                            // 处理完整行
                            if char == "\n" {
                                let lines = lineBuffer.components(separatedBy: "\n")
                                for line in lines.dropLast() {
                                    if let converted = convertStreamLine(line: line, provider: provider) {
                                        let lineData = (converted + "\n\n").utf8
                                        batch.append(contentsOf: lineData)
                                    }
                                }
                                lineBuffer = lines.last ?? ""
                                if batch.count >= 4096 {
                                    try await writer.write(ByteBuffer(bytes: batch))
                                    batch.removeAll(keepingCapacity: true)
                                }
                            }
                        }
                    }
                    // 处理剩余缓冲
                    if !lineBuffer.isEmpty {
                        let lines = lineBuffer.components(separatedBy: "\n")
                        for line in lines {
                            if let converted = convertStreamLine(line: line, provider: provider) {
                                let lineData = (converted + "\n\n").utf8
                                batch.append(contentsOf: lineData)
                            }
                        }
                    }
                } else {
                    // Anthropic 协议：直接透传
                    for try await byte in asyncBytes {
                        batch.append(byte)
                        // SSE 事件之间用 \n\n 分隔，遇到 \n 时就 flush 当前批次
                        // —— 这样一行内不会卡缓冲，每个事件能及时到客户端
                        if byte == 0x0A /* '\n' */ || batch.count >= 4096 {
                            try await writer.write(ByteBuffer(bytes: batch))
                            batch.removeAll(keepingCapacity: true)
                        }
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
