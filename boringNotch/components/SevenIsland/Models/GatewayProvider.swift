// GatewayProvider.swift
// Seven Island
//
// 数据模型：Seven Island 本地 HTTP 网关的上游 provider 配置。
//
// 网关本身（ClaudeGatewayService）监听 127.0.0.1:15722，接收 Claude Desktop /
// Claude Code 发来的 Anthropic Messages 请求，按当前激活的 GatewayProvider
// 转发到对应的下游 Anthropic 兼容 endpoint。一条 GatewayProvider 描述：
//
//   - 一个下游 base URL（例如 https://llm-proxy.intra.xiaojukeji.com）
//   - 一个 API key 和它的 auth scheme（Authorization 头怎么写）
//   - 一组模型名映射（Claude Desktop 发来的 "claude-sonnet-4-6" 映射成下游
//     真正认识的模型名，例如 "anthropic/claude-sonnet-4-5"）
//
// 历史上这个文件叫 ClaudeDesktopProvider，方向是"给 CC Switch 写 profile"。
// 已重构为"Seven Island 自己当 gateway 用的 provider 配置"。原来用于写
// configLibrary 的 ClaudeDesktopProfile / ClaudeDesktopConfigMeta 仍保留在
// 本文件，仅供阶段 E 的"导出到 Claude Desktop"功能使用。

import Defaults
import Foundation

// MARK: - Defaults.Serializable conformances

extension GatewayProvider: Defaults.Serializable {}
extension ClaudeModelMapping: Defaults.Serializable {}
extension InferenceModelEntry: Defaults.Serializable {}

// MARK: - Provider Record

/// Seven Island gateway 内部存储的上游 provider 记录（存在 Defaults 里）。
struct GatewayProvider: Codable, Identifiable, Equatable {
    /// 内部 ID（UUID 字符串）
    var id: String
    /// 用户可见的名称（仅 Settings UI 显示，不参与转发逻辑）
    var name: String
    /// 下游 API base URL（例如 "https://llm-proxy.intra.xiaojukeji.com"）
    /// gateway 转发时拼接 baseUrl + "/v1/messages"。
    var baseUrl: String
    /// API key / bearer token
    var apiKey: String
    /// Authorization 头方案：
    /// - "bearer"：写 `Authorization: Bearer <apiKey>`（默认；CC Switch、OpenAI 兼容网关用这个）
    /// - "x-api-key"：写 `x-api-key: <apiKey>`（Anthropic 官方 API 用这个）
    /// - 其他字符串：直接当 Authorization 头值写（高级用户）
    var authScheme: String
    /// 下游 provider 的协议类型。
    /// - anthropic: 下游是 Anthropic Messages API (/v1/messages)
    /// - openai: 下游是 OpenAI Chat Completions API (/v1/chat/completions)
    var protocolType: String
    /// 是否让 gateway 自动透传 model 字段（不查映射）
    var useModelDiscovery: Bool
    /// 模型映射列表（useModelDiscovery=false 时生效）
    var modelMappings: [ClaudeModelMapping]

    init(
        id: String = UUID().uuidString,
        name: String = "",
        baseUrl: String = "",
        apiKey: String = "",
        authScheme: String = "bearer",
        protocolType: String = "anthropic",
        useModelDiscovery: Bool = false,
        modelMappings: [ClaudeModelMapping] = ClaudeModelMapping.defaultMappings
    ) {
        self.id = id
        self.name = name
        self.baseUrl = baseUrl
        self.apiKey = apiKey
        self.authScheme = authScheme
        self.protocolType = protocolType
        self.useModelDiscovery = useModelDiscovery
        self.modelMappings = modelMappings
    }

    // MARK: Codable
    //
    // 兼容老数据 —— 之前这个结构叫 ClaudeDesktopProvider，有 disableProviderChooser
    // 字段。新版本忽略它；旧字段缺失时填默认值。

    enum CodingKeys: String, CodingKey {
        case id, name, baseUrl, apiKey, authScheme, protocolType
        case useModelDiscovery, modelMappings
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id              = try c.decode(String.self, forKey: .id)
        self.name            = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        self.baseUrl         = try c.decodeIfPresent(String.self, forKey: .baseUrl) ?? ""
        self.apiKey          = try c.decodeIfPresent(String.self, forKey: .apiKey) ?? ""
        self.authScheme      = try c.decodeIfPresent(String.self, forKey: .authScheme) ?? "bearer"
        self.protocolType    = try c.decodeIfPresent(String.self, forKey: .protocolType) ?? "anthropic"
        self.useModelDiscovery = try c.decodeIfPresent(Bool.self, forKey: .useModelDiscovery) ?? false
        self.modelMappings   = try c.decodeIfPresent([ClaudeModelMapping].self, forKey: .modelMappings)
                                ?? ClaudeModelMapping.defaultMappings
    }
}

// MARK: - Model Mapping

/// 单条模型映射规则。三字段语义：
///
/// - `claudeModel` ── Claude Desktop / Code 发来的模型名（剥离 `[1m]` 后缀后用作
///   查表 key）。也是写入 Claude Desktop profile 的 `inferenceModels[].name`。
///   例："claude-sonnet-4-6"。
///
/// - `upstreamModel` ── 转发到下游 provider 时实际写入请求体 `model` 字段的名字。
///   留空 → 原样透传 `claudeModel`。
///   例：下游若只识别 "anthropic/claude-sonnet-4-5"，就在这里填。
///
/// - `displayName` ── 写入 Claude Desktop profile 的 `labelOverride` 字段，
///   决定 Claude Desktop 模型菜单显示的名字。例："auto-max" / "auto-mini"。
///   只影响 Claude Desktop UI，对网关转发逻辑没有影响。
///
/// - `supports1m` ── 写入 Claude Desktop profile 的 `supports1m`，菜单角标。
struct ClaudeModelMapping: Codable, Identifiable, Equatable {
    var claudeModel: String
    var upstreamModel: String
    var displayName: String
    var supports1m: Bool

    var id: String { claudeModel }

    init(claudeModel: String,
         upstreamModel: String = "",
         displayName: String = "",
         supports1m: Bool = false) {
        self.claudeModel = claudeModel
        self.upstreamModel = upstreamModel
        self.displayName = displayName
        self.supports1m = supports1m
    }

    // MARK: Codable —— 兼容历史字段名
    //
    // 历史变迁：
    //   v0: { claudeModel, upstreamModel } （上游模型名）
    //   v1: { claudeModel, displayName, supports1m } （误把 displayName 当作上游名）
    //   v2: 当前 —— { claudeModel, upstreamModel, displayName, supports1m }
    //
    // v1 数据里的 displayName 语义是"菜单显示名"，迁移到 v2 时保留。
    // v0 数据里的 upstreamModel 语义就是上游模型名，迁移到 v2 时也保留。
    // 全部容错：任何字段缺失都填空串/false。
    enum CodingKeys: String, CodingKey {
        case claudeModel, upstreamModel, displayName, supports1m
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.claudeModel   = try c.decodeIfPresent(String.self, forKey: .claudeModel) ?? ""
        self.upstreamModel = try c.decodeIfPresent(String.self, forKey: .upstreamModel) ?? ""
        self.displayName   = try c.decodeIfPresent(String.self, forKey: .displayName) ?? ""
        self.supports1m    = try c.decodeIfPresent(Bool.self, forKey: .supports1m) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(claudeModel, forKey: .claudeModel)
        try c.encode(upstreamModel, forKey: .upstreamModel)
        try c.encode(displayName, forKey: .displayName)
        try c.encode(supports1m, forKey: .supports1m)
    }
}

/// 内置默认映射模板。语义按 CC Switch 的 profile 来：
///   sonnet → 菜单显示 "auto"
///   opus   → "auto-std"  (1M context)
///   haiku  → "auto-mini"
///   fable  → "auto-max"  (1M context)
///
/// 默认 `upstreamModel` 留空 = 原样透传 `claudeModel` 给下游。下游识别
/// "claude-sonnet-4-6" 这种名字的话不用改；不识别的话用户在 Settings 里填。
extension ClaudeModelMapping {
    static let defaultMappings: [ClaudeModelMapping] = [
        ClaudeModelMapping(claudeModel: "claude-sonnet-4-6", upstreamModel: "", displayName: "auto",      supports1m: false),
        ClaudeModelMapping(claudeModel: "claude-opus-4-8",   upstreamModel: "", displayName: "auto-std",  supports1m: true),
        ClaudeModelMapping(claudeModel: "claude-haiku-4-5",  upstreamModel: "", displayName: "auto-mini", supports1m: false),
        ClaudeModelMapping(claudeModel: "claude-fable-5",    upstreamModel: "", displayName: "auto-max",  supports1m: true),
    ]
}

// MARK: - Claude Desktop Profile JSON
//
// 以下两个结构仅给阶段 E 的"导出到 Claude Desktop"功能用 —— 把当前 Seven Island
// gateway 信息写成 Claude Desktop 能读的 profile JSON。普通转发流程不会触碰这些。

/// 写入 `~/Library/Application Support/Claude-3p/configLibrary/<id>.json` 的完整结构。
struct ClaudeDesktopProfile: Codable {
    var inferenceProvider: String = "gateway"
    var inferenceCredentialKind: String?
    var inferenceGatewayAuthScheme: String?
    var inferenceGatewayBaseUrl: String
    var inferenceGatewayApiKey: String
    var modelDiscoveryEnabled: Bool?
    var disableDeploymentModeChooser: Bool?
    var inferenceModels: [InferenceModelEntry]?
    var coworkTabEnabled: Bool?
    var coworkEgressAllowedHosts: [String]?

    enum CodingKeys: String, CodingKey {
        case inferenceProvider
        case inferenceCredentialKind
        case inferenceGatewayAuthScheme
        case inferenceGatewayBaseUrl
        case inferenceGatewayApiKey
        case modelDiscoveryEnabled
        case disableDeploymentModeChooser
        case inferenceModels
        case coworkTabEnabled
        case coworkEgressAllowedHosts
    }
}

/// profile 里 inferenceModels 数组的单项。
struct InferenceModelEntry: Codable, Identifiable, Equatable {
    var name: String
    var labelOverride: String?
    var supports1m: Bool?

    var id: String { name }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        if let lo = labelOverride, !lo.isEmpty {
            try container.encode(lo, forKey: .labelOverride)
        }
        if let s1m = supports1m, s1m {
            try container.encode(s1m, forKey: .supports1m)
        }
    }

    enum CodingKeys: String, CodingKey {
        case name, labelOverride, supports1m
    }
}

/// `~/Library/Application Support/Claude-3p/configLibrary/_meta.json` 的结构。
struct ClaudeDesktopConfigMeta: Codable {
    var appliedId: String
    var entries: [MetaEntry]

    struct MetaEntry: Codable, Equatable {
        var id: String
        var name: String
    }
}
