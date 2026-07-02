//
//  AgentIntegrationSettingsView.swift
//  boringNotch
//
//  Settings UI for registering/uninstalling Seven Island hooks into
//  Claude Code and Codex.
//

import Defaults
import SwiftUI

struct AgentIntegrationSettingsView: View {
    @Default(.agentHookClaudeEnabled) private var claudeEnabled
    @Default(.agentHookCodexEnabled) private var codexEnabled
    @Default(.agentHookOpenCodeEnabled) private var opencodeEnabled
    @Default(.agentHookPermissionIntercept) private var permissionIntercept
    @Default(.agentHookPermissionTimeout) private var permissionTimeout

    @State private var installError: String?
    @State private var claudeInstalled = false
    @State private var codexInstalled = false
    @State private var opencodeInstalled = false

    var body: some View {
        Form {
            // MARK: - Claude Code
            Section {
                Toggle(isOn: Binding(
                    get: { claudeEnabled },
                    set: { newVal in togglePlatform(.claude, enabled: newVal) }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("启用 Claude Code 集成")
                        Text("在 ~/.claude/settings.json 中注册 hook")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if claudeEnabled {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.caption)
                        Text("已注册到 ~/.claude/settings.json")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    HStack(spacing: 4) {
                        Image(systemName: "link")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(HookRegistrationManager.bundledScriptPath)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            } header: {
                Text("Claude Code")
            }

            // MARK: - Codex
            Section {
                Toggle(isOn: Binding(
                    get: { codexEnabled },
                    set: { newVal in togglePlatform(.codex, enabled: newVal) }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("启用 Codex 集成")
                        Text("在 ~/.codex/hooks.json 中注册 hook")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if codexEnabled {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.caption)
                        Text("已注册到 ~/.codex/hooks.json")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    HStack(spacing: 4) {
                        Image(systemName: "link")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(HookRegistrationManager.bundledScriptPath)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            } header: {
                Text("Codex")
            }

            // MARK: - OpenCode
            Section {
                Toggle(isOn: Binding(
                    get: { opencodeEnabled },
                    set: { newVal in togglePlatform(.opencode, enabled: newVal) }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("启用 OpenCode 集成")
                        Text("安装 JS 插件到 ~/.config/opencode/plugins/")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if opencodeEnabled {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.caption)
                        Text("已安装到 ~/.config/opencode/plugins/seven-island-opencode.js")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    HStack(spacing: 4) {
                        Image(systemName: "link")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(HookRegistrationManager.bundledOpenCodePluginPath)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            } header: {
                Text("OpenCode")
            } footer: {
                Text("OpenCode 使用 JS 插件机制（注册在 config.json 的 plugin 数组）。Codex 与 OpenCode 暂不支持授权拦截。")
            }

            // MARK: - Permission interception (Claude only)
            Section {
                Toggle("拦截工具调用授权", isOn: $permissionIntercept)
                    .onChange(of: permissionIntercept) { newVal in
                        guard claudeEnabled else { return }
                        reinstallClaude()
                    }

                if permissionIntercept && claudeEnabled {
                    Stepper(
                        "超时自动拒绝: \(permissionTimeout) 秒",
                        value: $permissionTimeout,
                        in: 30...120, step: 10
                    )
                    .onChange(of: permissionTimeout) { _ in
                        reinstallClaude()
                    }
                    Text("超时后 hook 自动允许请求，避免 Claude Code 永久阻塞。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("授权弹窗（仅 Claude）")
            }

            // MARK: - Error
            if let err = installError {
                Section {
                    Text("错误: \(err)")
                        .foregroundStyle(.red)
                        .font(.caption)
                }
            }
        }
        .formStyle(.grouped)
        .accentColor(.effectiveAccent)
        .navigationTitle("Agent 集成")
        .onAppear { refreshStates() }
    }

    // MARK: - Actions

    private func togglePlatform(_ platform: AgentPlatform, enabled: Bool) {
        do {
            if enabled {
                try HookRegistrationManager.install(
                    platform,
                    permissionIntercept: permissionIntercept,
                    timeoutSeconds: permissionTimeout
                )
            } else {
                try HookRegistrationManager.uninstall(platform)
            }
            switch platform {
            case .claude:   claudeEnabled   = enabled
            case .codex:    codexEnabled    = enabled
            case .opencode: opencodeEnabled = enabled
            }
            installError = nil
            refreshStates()
        } catch {
            installError = error.localizedDescription
        }
    }

    private func reinstallClaude() {
        do {
            try HookRegistrationManager.install(
                .claude,
                permissionIntercept: permissionIntercept,
                timeoutSeconds: permissionTimeout
            )
            installError = nil
            refreshStates()
        } catch {
            installError = error.localizedDescription
        }
    }

    private func refreshStates() {
        claudeInstalled = HookRegistrationManager.isRegistered(.claude)
        codexInstalled  = HookRegistrationManager.isRegistered(.codex)
        opencodeInstalled = HookRegistrationManager.isRegistered(.opencode)
    }
}