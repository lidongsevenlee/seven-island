// ClaudeDesktopExporter.swift
// Seven Island
//
// 阶段 E：一键导出 —— 把 Seven Island gateway 当前的配置（baseUrl=127.0.0.1:port、
// 模型列表）写成 Claude Desktop 可识别的 profile JSON，放到：
//
//   ~/Library/Application Support/Claude-3p/configLibrary/<sevenIslandProfileId>.json
//
// 并把 `_meta.json` 的 appliedId 设成这个固定 UUID，让 Claude Desktop 下次启动
// 直接用 Seven Island gateway。
//
// 安全约束：
//   - profile 文件用 0600 权限，对齐 Claude Desktop 自己写的文件
//   - 用一个固定 UUID（包含 15722 端口号方便识别），覆盖式更新而非每次新建
//   - 不删除其他 profile 文件，只新增/更新自己这条
//   - apiKey 写一个占位串 "seven-island-local" —— gateway 监听 127.0.0.1 不验权，
//     这个字段只是为了通过 Claude Desktop 的"必填"检查

import Foundation
import OSLog

private let osLogger = os.Logger(
    subsystem: "com.local.seven-island",
    category: "exporter"
)

@MainActor
final class ClaudeDesktopExporter {
    static let shared = ClaudeDesktopExporter()
    private init() {}

    /// Seven Island gateway profile 的固定 UUID。
    /// 末尾 `015722` 是端口号的语义提示，方便用户在 Claude-3p 目录里识别。
    static let sevenIslandProfileId = "11111111-0000-4001-8000-000000015722"

    /// 显示给 Claude Desktop UI 的 profile 名字。
    static let sevenIslandProfileName = "Seven Island 本地网关"

    private let configLibraryURL: URL = {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport.appendingPathComponent("Claude-3p/configLibrary")
    }()

    private var metaURL: URL { configLibraryURL.appendingPathComponent("_meta.json") }

    private func profileURL(for id: String) -> URL {
        configLibraryURL.appendingPathComponent("\(id).json")
    }

    // MARK: - Public API

    enum ExportError: LocalizedError {
        case gatewayNotRunning
        case io(String)

        var errorDescription: String? {
            switch self {
            case .gatewayNotRunning: return "Gateway 未运行；请先在「服务状态」里开启"
            case .io(let m):          return "写文件失败：\(m)"
            }
        }
    }

    /// 把当前 gateway 状态导出为 Claude Desktop profile，并设为 Claude Desktop 当前
    /// 激活的 profile。返回写入的 profile 文件 URL（成功时）。
    @discardableResult
    func exportToClaudeDesktop(activeProvider: GatewayProvider?, port: Int) -> Result<URL, Error> {
        do {
            // 1. 构造 profile JSON。baseUrl 永远指向自己。
            let profile = makeProfile(provider: activeProvider, port: port)

            try FileManager.default.createDirectory(
                at: configLibraryURL, withIntermediateDirectories: true)

            // 2. 写 profile 文件
            let url = profileURL(for: Self.sevenIslandProfileId)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(profile)
            try data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o600)],
                ofItemAtPath: url.path
            )
            osLogger.info("wrote profile: \(url.path, privacy: .public)")

            // 3. 更新 _meta.json：upsert entry + 切换 appliedId
            try upsertMetaAndActivate(id: Self.sevenIslandProfileId, name: Self.sevenIslandProfileName)

            return .success(url)
        } catch {
            osLogger.error("export failed: \(error.localizedDescription, privacy: .public)")
            return .failure(ExportError.io(error.localizedDescription))
        }
    }

    // MARK: - Profile construction

    private func makeProfile(provider: GatewayProvider?, port: Int) -> ClaudeDesktopProfile {
        var profile = ClaudeDesktopProfile(
            inferenceGatewayBaseUrl: "http://127.0.0.1:\(port)",
            inferenceGatewayApiKey: "seven-island-local"
        )
        profile.inferenceGatewayAuthScheme = "bearer"
        profile.disableDeploymentModeChooser = true

        // inferenceModels 来自激活 provider 的 modelMappings；没有 active 时用默认 4 条。
        let mappings = provider?.modelMappings ?? ClaudeModelMapping.defaultMappings
        let entries: [InferenceModelEntry] = mappings.compactMap { m in
            let claudeName = m.claudeModel.trimmingCharacters(in: .whitespaces)
            guard !claudeName.isEmpty else { return nil }
            return InferenceModelEntry(
                name: claudeName,
                labelOverride: m.displayName.isEmpty ? nil : m.displayName,
                supports1m: m.supports1m ? true : nil
            )
        }
        if !entries.isEmpty {
            profile.inferenceModels = entries
        } else {
            profile.modelDiscoveryEnabled = true
        }
        return profile
    }

    // MARK: - _meta.json helpers

    private func readMeta() -> ClaudeDesktopConfigMeta? {
        guard let data = try? Data(contentsOf: metaURL) else { return nil }
        return try? JSONDecoder().decode(ClaudeDesktopConfigMeta.self, from: data)
    }

    private func writeMeta(_ meta: ClaudeDesktopConfigMeta) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(meta)
        try data.write(to: metaURL, options: .atomic)
        try? FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: metaURL.path
        )
    }

    private func upsertMetaAndActivate(id: String, name: String) throws {
        var meta = readMeta() ?? ClaudeDesktopConfigMeta(appliedId: id, entries: [])
        if let idx = meta.entries.firstIndex(where: { $0.id == id }) {
            meta.entries[idx].name = name
        } else {
            meta.entries.append(.init(id: id, name: name))
        }
        meta.appliedId = id
        try writeMeta(meta)
    }
}
