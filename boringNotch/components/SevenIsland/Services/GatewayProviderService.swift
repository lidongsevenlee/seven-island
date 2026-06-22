// GatewayProviderService.swift
// Seven Island
//
// 管理 Seven Island gateway 的上游 provider 列表 + 当前激活 provider，持久化
// 到 Defaults。本服务**只管 provider 配置 CRUD**，不直接启动/停止 HTTP server
// （那是 ClaudeGatewayService 的职责）。
//
// 主要职责：
//   1. CRUD provider 列表，存到 Defaults[.gatewayProviders]
//   2. 暴露 `activeProvider` 给转发逻辑用
//   3. 写盘前的 provider 校验（防呆，避免错配把网关搞死）
//   4. 从老 key `claudeDesktopProviders` 一次性迁移到 `gatewayProviders`

import Combine
import Defaults
import Foundation
import SwiftUI

// MARK: - Defaults Keys

extension Defaults.Keys {
    // MARK: Claude Gateway

    /// 是否启用本地 HTTP gateway（监听 127.0.0.1:gatewayPort）。
    static let gatewayEnabled = Key<Bool>(
        "gatewayEnabled", default: false)

    /// gateway 监听端口。默认 15722 避开 CC Switch 的 15721。
    static let gatewayPort = Key<Int>(
        "gatewayPort", default: 15722)

    /// 已配置的上游 provider 列表。
    static let gatewayProviders = Key<[GatewayProvider]>(
        "gatewayProviders", default: [])

    /// 当前激活的 provider id。转发时按这个查 provider。
    static let gatewayActiveProviderId = Key<String?>(
        "gatewayActiveProviderId", default: nil)

    // MARK: Legacy
    //
    // 老 key（v0：直接给 Claude Desktop 写 profile 用）。仅用于一次性迁移读取，
    // 不再写入。迁移逻辑在 GatewayProviderService.init() 里。
    fileprivate static let legacyClaudeDesktopProviders = Key<[GatewayProvider]>(
        "claudeDesktopProviders", default: [])
}

// MARK: - Service

@MainActor
final class GatewayProviderService: ObservableObject {
    static let shared = GatewayProviderService()

    @Published private(set) var providers: [GatewayProvider] = []

    private init() {
        // 一次性迁移：v1 老 key `claudeDesktopProviders` → 新 key `gatewayProviders`
        let migrated = Defaults[.gatewayProviders]
        if migrated.isEmpty {
            let legacy = Defaults[.legacyClaudeDesktopProviders]
            if !legacy.isEmpty {
                Defaults[.gatewayProviders] = legacy
                Defaults[.legacyClaudeDesktopProviders] = []
            }
        }
        providers = Defaults[.gatewayProviders]
    }

    // MARK: - CRUD

    func addProvider(_ provider: GatewayProvider) {
        providers.append(provider)
        save()
    }

    func updateProvider(_ provider: GatewayProvider) {
        if let idx = providers.firstIndex(where: { $0.id == provider.id }) {
            providers[idx] = provider
            save()
        }
    }

    func deleteProvider(id: String) {
        providers.removeAll { $0.id == id }
        save()
        // 如果删的是当前激活的，清掉激活 id
        if Defaults[.gatewayActiveProviderId] == id {
            Defaults[.gatewayActiveProviderId] = nil
        }
    }

    // MARK: - Active

    /// 当前激活的 provider —— gateway 转发时用这个。
    var activeProvider: GatewayProvider? {
        guard let id = Defaults[.gatewayActiveProviderId] else { return nil }
        return providers.first { $0.id == id }
    }

    /// 把 provider 设为激活态。
    func setActive(id: String) {
        guard providers.contains(where: { $0.id == id }) else { return }
        Defaults[.gatewayActiveProviderId] = id
        objectWillChange.send()
    }

    var currentActiveId: String? {
        Defaults[.gatewayActiveProviderId]
    }

    // MARK: - Validation

    /// Provider 写盘前的兜底校验。曾踩过坑：用户把 baseUrl 错粘到 apiKey，
    /// gateway 转发时会用 URL 当 Bearer token，下游直接拒签。这里挡住。
    enum ProviderValidationError: LocalizedError {
        case emptyBaseUrl
        case emptyApiKey
        case apiKeyLooksLikeUrl
        case baseAndKeyIdentical
        case baseUrlNotHttp

        var errorDescription: String? {
            switch self {
            case .emptyBaseUrl:        return "Base URL 不能为空"
            case .emptyApiKey:         return "API Key 不能为空"
            case .apiKeyLooksLikeUrl:  return "API Key 不应以 http(s):// 开头，请检查是否粘错"
            case .baseAndKeyIdentical: return "Base URL 与 API Key 完全相同，疑似粘贴错误"
            case .baseUrlNotHttp:      return "Base URL 必须以 http:// 或 https:// 开头"
            }
        }
    }

    func validate(_ provider: GatewayProvider) throws {
        let base = provider.baseUrl.trimmingCharacters(in: .whitespaces)
        let key  = provider.apiKey.trimmingCharacters(in: .whitespaces)
        if base.isEmpty { throw ProviderValidationError.emptyBaseUrl }
        if key.isEmpty  { throw ProviderValidationError.emptyApiKey }
        let baseLower = base.lowercased()
        if !baseLower.hasPrefix("http://") && !baseLower.hasPrefix("https://") {
            throw ProviderValidationError.baseUrlNotHttp
        }
        let kLower = key.lowercased()
        if kLower.hasPrefix("http://") || kLower.hasPrefix("https://") {
            throw ProviderValidationError.apiKeyLooksLikeUrl
        }
        if base == key {
            throw ProviderValidationError.baseAndKeyIdentical
        }
    }

    // MARK: - Defaults persistence

    private func save() {
        Defaults[.gatewayProviders] = providers
    }
}
