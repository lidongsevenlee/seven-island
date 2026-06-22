// GatewaySettingsView.swift
// Seven Island
//
// Seven Island 本地 HTTP gateway 配置界面（替代 CC Switch）。
// 位置：Settings → Claude 网关
//
// 阶段 A 的版本：UI 框架已就位，但顶部「服务状态」section 暂未接真正的
// ClaudeGatewayService（阶段 B 才落地），所以 toggle 行为是无效的占位。
// 阶段 D 会把 status / start / stop 真正接上。

import Defaults
import SwiftUI

// MARK: - Main Settings View

struct GatewaySettingsView: View {
    @ObservedObject private var service = GatewayProviderService.shared
    @ObservedObject private var gateway = ClaudeGatewayService.shared
    @Default(.gatewayEnabled) private var gatewayEnabled
    @Default(.gatewayPort) private var gatewayPort
    @State private var editingProvider: GatewayProvider? = nil
    @State private var isAdding = false
    @State private var confirmDeleteId: String? = nil
    @State private var exportAlert: ExportAlert? = nil

    enum ExportAlert: Identifiable {
        case success(URL)
        case failure(String)
        var id: String {
            switch self {
            case .success(let u): return "ok-\(u.path)"
            case .failure(let m): return "err-\(m)"
            }
        }
    }

    var body: some View {
        Form {
            // —— 服务状态 ——
            //
            // toggle 联动 ClaudeGatewayService.start/stop（在 AppDelegate 里订阅
            // Defaults.observe）。状态从真实 service 读，不再是占位。
            Section {
                Toggle("启用 HTTP 网关", isOn: $gatewayEnabled)
                    .tint(.effectiveAccent)

                HStack {
                    statusDot
                    Text(statusLabel)
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }

                // 端口仅在 stopped 时可改，正在跑时 disable
                Stepper("端口：\(gatewayPort)", value: $gatewayPort, in: 1024...65535)
                    .disabled(gateway.status.isRunning)
            } header: {
                Text("服务状态")
            } footer: {
                Text("Seven Island 自带本地 HTTP 网关，接收 Claude Desktop / Claude Code 的请求转发到下方 Provider。监听 127.0.0.1 不暴露外网，无需鉴权。CC Switch 占用 15721，避开它默认用 15722。")
            }

            // —— Claude Desktop 集成 ——
            Section {
                Button {
                    exportToClaudeDesktop()
                } label: {
                    Label("应用到 Claude Desktop", systemImage: "arrowshape.right.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.effectiveAccent)
                .disabled(!gateway.status.isRunning)
            } header: {
                Text("Claude Desktop 集成")
            } footer: {
                Text("在 Claude Desktop 的 configLibrary 写入一个指向本网关的 profile，并切到这个 profile。Claude Desktop 会自动感知新配置，无需重启。该操作仅新增 Seven Island 自己的 profile，不会删改 CC Switch 或其他 profile。")
            }

            // —— Provider 列表 ——
            Section {
                if service.providers.isEmpty {
                    emptyState
                } else {
                    ForEach(service.providers) { provider in
                        providerRow(provider)
                    }
                }

                Button {
                    let p = GatewayProvider()
                    editingProvider = p
                    isAdding = true
                } label: {
                    Label("添加 Provider", systemImage: "plus.circle")
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.effectiveAccent)
            } header: {
                Text("上游 Provider")
            } footer: {
                Text("点「设为 Active」选择网关转发的目标。Claude Desktop 发来的请求会被改写 model 字段（按映射）并转到此 provider 的 baseUrl + /v1/messages。")
            }
        }
        .accentColor(.effectiveAccent)
        .navigationTitle("Claude 网关")
        .sheet(item: $editingProvider) { provider in
            ProviderEditSheet(
                provider: provider,
                isNew: isAdding
            ) { saved, activate in
                if isAdding {
                    service.addProvider(saved)
                } else {
                    service.updateProvider(saved)
                }
                if activate {
                    service.setActive(id: saved.id)
                }
                editingProvider = nil
                isAdding = false
            } onCancel: {
                editingProvider = nil
                isAdding = false
            }
        }
        .alert(item: $exportAlert) { alert in
            switch alert {
            case .success(let url):
                return Alert(
                    title: Text("已写入 Claude Desktop"),
                    message: Text("Profile 已写到：\n\(url.path)\n\nClaude Desktop 已自动切到此 profile，无需重启。"),
                    dismissButton: .default(Text("好"))
                )
            case .failure(let msg):
                return Alert(
                    title: Text("导出失败"),
                    message: Text(msg),
                    dismissButton: .default(Text("好"))
                )
            }
        }
        .confirmationDialog(
            "确认删除",
            isPresented: Binding(
                get: { confirmDeleteId != nil },
                set: { if !$0 { confirmDeleteId = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let id = confirmDeleteId {
                Button("删除", role: .destructive) {
                    service.deleteProvider(id: id)
                    confirmDeleteId = nil
                }
                Button("取消", role: .cancel) { confirmDeleteId = nil }
            }
        } message: {
            Text("此操作仅删除 Seven Island 内的 provider 记录，无法撤销。")
        }
    }

    // MARK: Export

    private func exportToClaudeDesktop() {
        let result = ClaudeDesktopExporter.shared.exportToClaudeDesktop(
            activeProvider: service.activeProvider,
            port: gatewayPort
        )
        switch result {
        case .success(let url):
            exportAlert = .success(url)
        case .failure(let error):
            exportAlert = .failure(error.localizedDescription)
        }
    }

    // MARK: Status dot / label

    @ViewBuilder
    private var statusDot: some View {
        switch gateway.status {
        case .listening:
            Circle().fill(Color.green).frame(width: 8, height: 8)
        case .starting:
            Circle().fill(Color.orange).frame(width: 8, height: 8)
        case .failed:
            Circle().fill(Color.red).frame(width: 8, height: 8)
        case .stopped:
            Circle().fill(Color.secondary.opacity(0.3)).frame(width: 8, height: 8)
        }
    }

    private var statusLabel: String {
        switch gateway.status {
        case .listening(let p): return "监听中：http://127.0.0.1:\(p)"
        case .starting:         return "正在启动…"
        case .failed(let msg):  return "失败：\(msg)"
        case .stopped:          return "未启动"
        }
    }

    // MARK: Empty State

    private var emptyState: some View {
        HStack {
            Spacer()
            VStack(spacing: 6) {
                Image(systemName: "externaldrive.badge.plus")
                    .font(.system(size: 28))
                    .foregroundStyle(.tertiary)
                Text("暂无上游 Provider")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 16)
            Spacer()
        }
    }

    // MARK: Provider Row

    @ViewBuilder
    private func providerRow(_ provider: GatewayProvider) -> some View {
        HStack(spacing: 10) {
            let isActive = service.currentActiveId == provider.id
            Circle()
                .fill(isActive ? Color.green : Color.secondary.opacity(0.3))
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(provider.name.isEmpty ? "未命名" : provider.name)
                        .fontWeight(isActive ? .semibold : .regular)
                    if isActive {
                        Text("Active")
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.green.opacity(0.15), in: Capsule())
                            .foregroundStyle(.green)
                    }
                }
                Text(provider.baseUrl.isEmpty ? "未设置 URL" : provider.baseUrl)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            // 设为 Active 按钮（已激活的隐藏）
            if !(service.currentActiveId == provider.id) {
                Button {
                    service.setActive(id: provider.id)
                } label: {
                    Text("设为 Active")
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.effectiveAccent.opacity(0.12), in: Capsule())
                        .foregroundStyle(Color.effectiveAccent)
                }
                .buttonStyle(.plain)
                .disabled(provider.baseUrl.isEmpty || provider.apiKey.isEmpty)
            }

            // 编辑
            Button {
                isAdding = false
                editingProvider = provider
            } label: {
                Image(systemName: "pencil")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)

            // 删除
            Button {
                confirmDeleteId = provider.id
            } label: {
                Image(systemName: "trash")
                    .font(.caption)
                    .foregroundStyle(.red.opacity(0.7))
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Provider Edit Sheet

private struct ProviderEditSheet: View {
    @State private var draft: GatewayProvider
    let isNew: Bool
    let onSave: (_ saved: GatewayProvider, _ activateNow: Bool) -> Void
    let onCancel: () -> Void

    @State private var showApiKey = false

    init(
        provider: GatewayProvider,
        isNew: Bool,
        onSave: @escaping (GatewayProvider, Bool) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self._draft = State(initialValue: provider)
        self.isNew = isNew
        self.onSave = onSave
        self.onCancel = onCancel
    }

    private var apiKeyLooksLikeUrl: Bool {
        let k = draft.apiKey.trimmingCharacters(in: .whitespaces).lowercased()
        return k.hasPrefix("http://") || k.hasPrefix("https://")
    }

    private var baseAndKeyIdentical: Bool {
        let b = draft.baseUrl.trimmingCharacters(in: .whitespaces)
        let k = draft.apiKey.trimmingCharacters(in: .whitespaces)
        return !b.isEmpty && b == k
    }

    private var validationError: String? {
        if baseAndKeyIdentical { return "Base URL 和 API Key 不能完全一样（看起来是把 URL 错粘到 Key 上了）" }
        if apiKeyLooksLikeUrl  { return "API Key 不应以 http(s):// 开头，请检查是否粘错了" }
        return nil
    }

    private var isValid: Bool {
        !draft.baseUrl.trimmingCharacters(in: .whitespaces).isEmpty
        && !draft.apiKey.trimmingCharacters(in: .whitespaces).isEmpty
        && validationError == nil
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text(isNew ? "添加 Provider" : "编辑 Provider")
                    .font(.headline)
                Spacer()
                Button("取消", action: onCancel)
                    .keyboardShortcut(.cancelAction)
            }
            .padding()

            Divider()

            Form {
                // 基础配置
                Section {
                    TextField("名称（例如 llm-proxy）", text: $draft.name)

                    HStack(spacing: 6) {
                        TextField("Base URL（例如 https://llm-proxy.intra.xiaojukeji.com）", text: $draft.baseUrl)
                            .autocorrectionDisabled()
                            .textContentType(.URL)
                        if !draft.baseUrl.isEmpty {
                            Button {
                                draft.baseUrl = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    HStack(spacing: 6) {
                        Group {
                            if showApiKey {
                                TextField("API Key / Bearer Token", text: $draft.apiKey)
                                    .autocorrectionDisabled()
                            } else {
                                SecureField("API Key / Bearer Token", text: $draft.apiKey)
                            }
                        }
                        Button {
                            showApiKey.toggle()
                        } label: {
                            Image(systemName: showApiKey ? "eye.slash" : "eye")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }

                    Picker("Auth Scheme", selection: $draft.authScheme) {
                        Text("Bearer (推荐)").tag("bearer")
                        Text("x-api-key (Anthropic 官方)").tag("x-api-key")
                        Text("Static").tag("static")
                    }
                } header: {
                    Text("基础配置")
                } footer: {
                    Text("Base URL 不带 /v1/messages 后缀，网关转发时自动拼接。Authorization 头按 Auth Scheme 写：bearer → `Authorization: Bearer <key>`；x-api-key → `x-api-key: <key>`。")
                }

                // 模型映射
                Section {
                    Toggle("透传模型名（不查映射）", isOn: $draft.useModelDiscovery)
                        .tint(.effectiveAccent)
                } header: {
                    Text("模型配置")
                } footer: {
                    Text("开启后网关把 Claude Desktop 的 model 字段原样转发给下游（仅剥离 [1m] 后缀）。关闭则用下方映射改写。")
                }

                if !draft.useModelDiscovery {
                    Section {
                        ForEach($draft.modelMappings) { $mapping in
                            ModelMappingRow(mapping: $mapping)
                        }
                    } header: {
                        Text("模型映射 (claudeModel → upstreamModel)")
                    } footer: {
                        Text("「下游模型名」留空 = 原样透传 claudeModel；「菜单显示名」只在阶段 E 导出 Claude Desktop profile 时用，对网关本身无影响。")
                    }
                }
            }
            .formStyle(.grouped)

            Divider()

            // Footer buttons
            HStack(spacing: 8) {
                if let err = validationError {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(err)
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                Spacer()
                Button("存储") {
                    onSave(draft, false)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid)

                Button("存储并设为 Active") {
                    onSave(draft, true)
                }
                .buttonStyle(.borderedProminent)
                .tint(.effectiveAccent)
                .disabled(!isValid)
            }
            .padding()
        }
        .frame(width: 680, height: draft.useModelDiscovery ? 480 : 640)
    }
}

// MARK: - Model Mapping Row

/// 一行模型映射。三列：
///   [claudeModel]  →  [upstreamModel]  | [displayName]   [1M ◯]
///
/// - claudeModel：客户端发来的 model 名，网关用它查表（必填）
/// - upstreamModel：实际转发到下游的 model 名，留空 = 原样透传
/// - displayName：只给 Claude Desktop UI 看（labelOverride），对网关无影响
/// - supports1m：菜单角标
private struct ModelMappingRow: View {
    @Binding var mapping: ClaudeModelMapping

    var body: some View {
        HStack(spacing: 8) {
            TextField("Claude 模型名 (claude-*)", text: $mapping.claudeModel)
                .font(.system(.body, design: .monospaced))
                .autocorrectionDisabled()
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 180)

            Image(systemName: "arrow.right")
                .font(.caption)
                .foregroundStyle(.tertiary)

            TextField("下游模型名（留空=透传）",
                      text: $mapping.upstreamModel)
                .font(.system(.body, design: .monospaced))
                .autocorrectionDisabled()
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 180)

            Divider().frame(height: 18)

            TextField("Claude Desktop 菜单显示名", text: $mapping.displayName)
                .autocorrectionDisabled()
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 130)

            Toggle("", isOn: $mapping.supports1m)
                .toggleStyle(.switch)
                .labelsHidden()
                .help("Claude Desktop 菜单上显示 1M context 角标")
            Text("1M")
                .font(.caption2)
                .foregroundStyle(mapping.supports1m ? .primary : .secondary)
        }
    }
}
