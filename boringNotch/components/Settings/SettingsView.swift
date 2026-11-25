//
//  SettingsView.swift
//  boringNotch
//
//  Created by Richard Kunkli on 07/08/2024.
//

import ApplicationServices
import AVFoundation
import Defaults
import KeyboardShortcuts
import LaunchAtLogin
import Sparkle
import SwiftUI
import SwiftUIIntrospect

struct SettingsView: View {
    @State private var selectedTab = "General"
    @State private var accentColorUpdateTrigger = UUID()

    let updaterController: SPUStandardUpdaterController?

    init(updaterController: SPUStandardUpdaterController? = nil) {
        self.updaterController = updaterController
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedTab) {
                NavigationLink(value: "General") {
                    Label("通用", systemImage: "gear")
                }
                NavigationLink(value: "Appearance") {
                    Label("外观", systemImage: "eye")
                }
                NavigationLink(value: "Media") {
                    Label("媒体", systemImage: "play.laptopcomputer")
                }
                NavigationLink(value: "HUD") {
                    Label("系统提示", systemImage: "dial.medium.fill")
                }
//                NavigationLink(value: "Downloads") {
//                    Label("Downloads", systemImage: "square.and.arrow.down")
//                }
                NavigationLink(value: "Clipboard") {
                    Label("剪贴板", systemImage: "clipboard")
                }
                NavigationLink(value: "Projects") {
                    Label("项目", systemImage: "folder")
                }
                NavigationLink(value: "App Launcher") {
                    Label("应用启动器", systemImage: "square.grid.2x2")
                }
                // NavigationLink(value: "Extensions") {
                //     Label("Extensions", systemImage: "puzzlepiece.extension")
                // }
                NavigationLink(value: "Advanced") {
                    Label("高级", systemImage: "gearshape.2")
                }
                NavigationLink(value: "About") {
                    Label("关于", systemImage: "info.circle")
                }
            }
            .listStyle(SidebarListStyle())
            .tint(.effectiveAccent)
            .toolbar(removing: .sidebarToggle)
            .navigationSplitViewColumnWidth(200)
        } detail: {
            Group {
                switch selectedTab {
                case "General":
                    GeneralSettings()
                case "Appearance":
                    Appearance()
                case "Media":
                    Media()
                case "HUD":
                    HUD()
                case "Clipboard":
                    ClipboardSettingsView()
                case "Projects", "VS Code":
                    ProjectSettingsView()
                case "App Launcher":
                    AppLauncherSettingsView()
                case "Extensions":
                    GeneralSettings()
                case "Advanced":
                    Advanced()
                case "About":
                    if let controller = updaterController {
                        About(updaterController: controller)
                    } else {
                        // Fallback with a default controller
                        About(
                            updaterController: SPUStandardUpdaterController(
                                startingUpdater: false, updaterDelegate: nil,
                                userDriverDelegate: nil))
                    }
                default:
                    GeneralSettings()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar(removing: .sidebarToggle)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("")
                    .frame(width: 0, height: 0)
                    .accessibilityHidden(true)
            }
        }
        .formStyle(.grouped)
        .frame(width: 700)
        .background(Color(NSColor.windowBackgroundColor))
        .tint(.effectiveAccent)
        .id(accentColorUpdateTrigger)
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("AccentColorChanged"))) { _ in
            accentColorUpdateTrigger = UUID()
        }
    }
}

struct SettingsPicker<Value: Hashable>: View {
    struct Option: Identifiable {
        let value: Value
        let title: String

        var id: Value { value }

        init(_ value: Value, _ title: String) {
            self.value = value
            self.title = title
        }
    }

    @Environment(\.isEnabled) private var isEnabled
    @Binding private var selection: Value
    @State private var isPresented = false
    @State private var highlightedIndex = 0
    @FocusState private var optionsFocused: Bool
    private let title: LocalizedStringKey
    private let options: [Option]
    private let badge: String?

    init(_ title: LocalizedStringKey, selection: Binding<Value>, options: [Option], badge: String? = nil) {
        self.title = title
        self._selection = selection
        self.options = options
        self.badge = badge
    }

    var body: some View {
        let selectedTitle = options.first { $0.value == selection }.map { Text($0.title) }
            ?? Text("请选择")

        Button {
            highlightedIndex = options.firstIndex { $0.value == selection } ?? 0
            isPresented.toggle()
        } label: {
            HStack(spacing: 8) {
                Text(title)
                    .foregroundStyle(.primary)
                if let badge {
                    customBadge(text: badge)
                }

                Spacer(minLength: 12)

                selectedTitle
                    .lineLimit(1)
                    .foregroundStyle(.tint)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tint)
            }
            .padding(.vertical, 3)
            .opacity(isEnabled ? 1 : 0.5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(title))
        .accessibilityValue(selectedTitle)
        .disabled(options.isEmpty)
        .popover(isPresented: $isPresented, attachmentAnchor: .point(.bottomTrailing), arrowEdge: .top) {
            optionList
        }
    }

    private var optionList: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(options.enumerated()), id: \.element.id) { index, option in
                Button {
                    choose(option.value)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .semibold))
                            .opacity(option.value == selection ? 1 : 0)
                            .accessibilityHidden(true)
                        Text(option.title)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(
                        highlightedIndex == index ? Color.accentColor.opacity(0.14) : .clear,
                        in: RoundedRectangle(cornerRadius: 5)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(option.value == selection ? .isSelected : [])
                .onHover { hovering in
                    if hovering {
                        highlightedIndex = index
                    }
                }
            }
        }
        .padding(6)
        .frame(minWidth: 150)
        .fixedSize()
        .focusable()
        .focusEffectDisabled()
        .focused($optionsFocused)
        .defaultFocus($optionsFocused, true)
        .onKeyPress(keys: [.upArrow, .downArrow]) { key in
            let offset = key.key == .upArrow ? -1 : 1
            highlightedIndex = min(max(highlightedIndex + offset, 0), options.count - 1)
            return .handled
        }
        .onKeyPress(keys: [.return, .space]) { _ in
            if options.indices.contains(highlightedIndex) {
                choose(options[highlightedIndex].value)
            }
            return .handled
        }
        .onExitCommand {
            isPresented = false
        }
    }

    private func choose(_ value: Value) {
        isPresented = false
        if selection != value {
            selection = value
        }
    }
}

private struct IslandShortcutRecorder: View {
    let title: String
    let name: KeyboardShortcuts.Name
    @State private var previousShortcut: KeyboardShortcuts.Shortcut?
    @State private var showsConflict = false

    init(_ title: String, name: KeyboardShortcuts.Name) {
        self.title = title
        self.name = name
        _previousShortcut = State(initialValue: name.shortcut)
    }

    var body: some View {
        LabeledContent(title) {
            ShortcutRecorderControl(name: name) { shortcut in
                let panelNames = KeyboardShortcuts.Name.panelActions
                let names = TabModel.all.map(\.shortcut) + panelNames
                if let shortcut, let conflict = names.first(where: { $0 != name && $0.shortcut == shortcut }) {
                    name.shortcut = previousShortcut
                    if panelNames.contains(conflict) || BoringViewCoordinator.shared.tabLayout.visibleTabs.contains(where: { $0.shortcut == conflict }) {
                        KeyboardShortcuts.enable(conflict)
                    } else {
                        KeyboardShortcuts.disable(conflict)
                    }
                    showsConflict = true
                } else {
                    previousShortcut = shortcut
                }
            }
        }
        .alert("该快捷键已被其他操作使用", isPresented: $showsConflict) {
            Button("确定", role: .cancel) {}
        }
    }
}

private struct ShortcutRecorderControl: NSViewRepresentable {
    let name: KeyboardShortcuts.Name
    let onChange: (KeyboardShortcuts.Shortcut?) -> Void

    func makeNSView(context: Context) -> ClickTarget {
        ClickTarget(recorder: KeyboardShortcuts.RecorderCocoa(for: name, onChange: onChange))
    }

    func updateNSView(_ view: ClickTarget, context: Context) {
        view.recorder.shortcutName = name
    }

    final class ClickTarget: NSView {
        let recorder: KeyboardShortcuts.RecorderCocoa

        init(recorder: KeyboardShortcuts.RecorderCocoa) {
            self.recorder = recorder
            super.init(frame: recorder.frame)
            recorder.autoresizingMask = [.width, .height]
            setContentHuggingPriority(.defaultHigh, for: .horizontal)
            setContentHuggingPriority(.defaultHigh, for: .vertical)
            addSubview(recorder)
        }

        required init?(coder: NSCoder) { nil }

        override var intrinsicContentSize: NSSize { recorder.intrinsicContentSize }

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let hit = super.hitTest(point) else { return nil }
            guard hit === recorder || hit.isDescendant(of: recorder) else { return hit }
            if let cell = recorder.cell as? NSSearchFieldCell, cell.cancelButtonCell != nil {
                let localPoint = recorder.convert(point, from: superview)
                if cell.cancelButtonRect(forBounds: recorder.bounds).contains(localPoint) {
                    return hit
                }
            }
            return self
        }

        override func mouseDown(with event: NSEvent) {
            // The recorder installs its key monitor when it becomes the first responder.
            window?.makeFirstResponder(recorder)
        }
    }
}

struct GeneralSettings: View {
    @State private var screens = NSScreen.screens
    @EnvironmentObject var vm: BoringViewModel
    @ObservedObject var coordinator = BoringViewCoordinator.shared

    @Default(.mirrorShape) var mirrorShape
    @Default(.showEmojis) var showEmojis
    @Default(.minimumHoverDuration) var minimumHoverDuration
    @Default(.hoverCloseDelay) var hoverCloseDelay
    @Default(.nonNotchHeight) var nonNotchHeight
    @Default(.nonNotchHeightMode) var nonNotchHeightMode
    @Default(.notchHeight) var notchHeight
    @Default(.notchHeightMode) var notchHeightMode
    @Default(.showOnAllDisplays) var showOnAllDisplays
    @Default(.automaticallySwitchDisplay) var automaticallySwitchDisplay
    @Default(.openNotchOnHover) var openNotchOnHover
    

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(
                    get: { Defaults[.menubarIcon] },
                    set: { Defaults[.menubarIcon] = $0 }
                )) {
                    Text("显示菜单栏图标")
                }
                .tint(.effectiveAccent)
                LaunchAtLogin.Toggle("开机启动")
                Defaults.Toggle(key: .showOnAllDisplays) {
                    Text("在所有显示器上显示")
                }
                .onChange(of: showOnAllDisplays) {
                    NotificationCenter.default.post(
                        name: Notification.Name.showOnAllDisplaysChanged, object: nil)
                }
                SettingsPicker(
                    "首选显示器",
                    selection: $coordinator.preferredScreenUUID,
                    options: screens.compactMap { screen in
                        guard let uuid = screen.displayUUID else { return nil }
                        return .init(uuid, screen.localizedName)
                    }
                )
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
                    screens = NSScreen.screens
                }
                .disabled(showOnAllDisplays)
                
                Defaults.Toggle(key: .automaticallySwitchDisplay) {
                    Text("自动切换显示器")
                }
                    .onChange(of: automaticallySwitchDisplay) {
                        NotificationCenter.default.post(
                            name: Notification.Name.automaticallySwitchDisplayChanged, object: nil)
                    }
                    .disabled(showOnAllDisplays)
            } header: {
                Text("系统功能")
            }

            Section {
                IslandShortcutRecorder("区域截图", name: .captureScreenshot)
                Button("开始截图") {
                    ScreenshotTool.shared.startCapture()
                }
            } header: {
                Text("快捷键")
            } footer: {
                Text("默认使用 Fn + F1。键盘设为标准功能键时，直接按 F1。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                ForEach(coordinator.tabLayout.visibleTabs) { tab in
                    IslandShortcutRecorder(tab.label, name: tab.shortcut)
                }
            } header: {
                Text("标签页快捷键")
            } footer: {
                Text("再按一次当前标签页的快捷键即可收起面板。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                SettingsPicker(
                    "带刘海显示器上的刘海高度",
                    selection: $notchHeightMode,
                    options: [
                        .init(.matchRealNotchSize, "匹配真实刘海高度"),
                        .init(.matchMenuBar, "匹配菜单栏高度"),
                        .init(.custom, "自定义高度"),
                    ]
                )
                .onChange(of: notchHeightMode) {
                    switch notchHeightMode {
                    case .matchRealNotchSize:
                        notchHeight = 38
                    case .matchMenuBar:
                        notchHeight = 44
                    case .custom:
                        notchHeight = 38
                    }
                    NotificationCenter.default.post(
                        name: Notification.Name.notchHeightChanged, object: nil)
                }
                if notchHeightMode == .custom {
                    Slider(value: $notchHeight, in: 15...45, step: 1) {
                        Text("自定义刘海大小 - \(notchHeight, specifier: "%.0f")")
                    }
                    .onChange(of: notchHeight) {
                        NotificationCenter.default.post(
                            name: Notification.Name.notchHeightChanged, object: nil)
                    }
                }
                SettingsPicker(
                    "无刘海显示器上的刘海高度",
                    selection: $nonNotchHeightMode,
                    options: [
                        .init(.matchMenuBar, "匹配菜单栏高度"),
                        .init(.matchRealNotchSize, "匹配真实刘海高度"),
                        .init(.custom, "自定义高度"),
                    ]
                )
                .onChange(of: nonNotchHeightMode) {
                    switch nonNotchHeightMode {
                    case .matchMenuBar:
                        nonNotchHeight = 24
                    case .matchRealNotchSize:
                        nonNotchHeight = 32
                    case .custom:
                        nonNotchHeight = 32
                    }
                    NotificationCenter.default.post(
                        name: Notification.Name.notchHeightChanged, object: nil)
                }
                if nonNotchHeightMode == .custom {
                    Slider(value: $nonNotchHeight, in: 0...40, step: 1) {
                        Text("自定义刘海大小 - \(nonNotchHeight, specifier: "%.0f")")
                    }
                    .onChange(of: nonNotchHeight) {
                        NotificationCenter.default.post(
                            name: Notification.Name.notchHeightChanged, object: nil)
                    }
                }
            } header: {
                Text("刘海尺寸")
            }

            NotchBehaviour()
        }
        .toolbar {
            Button("退出应用") {
                NSApp.terminate(self)
            }
            .controlSize(.extraLarge)
        }
        .accentColor(.effectiveAccent)
        .navigationTitle("通用")
    }

    @ViewBuilder
    func NotchBehaviour() -> some View {
        Section {
            Defaults.Toggle(key: .openNotchOnHover) {
                Text("悬停时打开刘海")
            }
            Defaults.Toggle(key: .enableHaptics) {
                    Text("启用触觉反馈")
            }
            Toggle("记住上次的标签页", isOn: $coordinator.openLastTabByDefault)
            if openNotchOnHover {
                hoverDelaySlider("悬停延迟", value: $minimumHoverDuration)
                    .onChange(of: minimumHoverDuration) {
                        NotificationCenter.default.post(
                            name: Notification.Name.notchHeightChanged, object: nil)
                    }
            }
            hoverDelaySlider("收回延迟", value: $hoverCloseDelay)
        } header: {
            Text("刘海行为")
        }
    }

    private func hoverDelaySlider(_ title: LocalizedStringKey, value: Binding<TimeInterval>) -> some View {
        Slider(value: value, in: 0...1, step: 0.1) {
            HStack {
                Text(title)
                Spacer()
                Text("\(value.wrappedValue, specifier: "%.1f") 秒")
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityLabel(Text(title))
    }
}


//struct Downloads: View {
//    @Default(.selectedDownloadIndicatorStyle) var selectedDownloadIndicatorStyle
//    @Default(.selectedDownloadIconStyle) var selectedDownloadIconStyle
//    var body: some View {
//        Form {
//            warningBadge("We don't support downloads yet", "It will be supported later on.")
//            Section {
//                Defaults.Toggle(key: .enableDownloadListener) {
//                    Text("Show download progress")
//                }
//                    .disabled(true)
//                Defaults.Toggle(key: .enableSafariDownloads) {
//                    Text("Enable Safari Downloads")
//                }
//                    .disabled(!Defaults[.enableDownloadListener])
//                Picker("Download indicator style", selection: $selectedDownloadIndicatorStyle) {
//                    Text("Progress bar")
//                        .tag(DownloadIndicatorStyle.progress)
//                    Text("Percentage")
//                        .tag(DownloadIndicatorStyle.percentage)
//                }
//                Picker("Download icon style", selection: $selectedDownloadIconStyle) {
//                    Text("Only app icon")
//                        .tag(DownloadIconStyle.onlyAppIcon)
//                    Text("Only download icon")
//                        .tag(DownloadIconStyle.onlyIcon)
//                    Text("Both")
//                        .tag(DownloadIconStyle.iconAndAppIcon)
//                }
//
//            } header: {
//                HStack {
//                    Text("Download indicators")
//                    comingSoonTag()
//                }
//            }
//            Section {
//                List {
//                    ForEach([].indices, id: \.self) { index in
//                        Text("\(index)")
//                    }
//                }
//                .frame(minHeight: 96)
//                .overlay {
//                    if true {
//                        Text("No excluded apps")
//                            .foregroundStyle(Color(.secondaryLabelColor))
//                    }
//                }
//                .actionBar(padding: 0) {
//                    Group {
//                        Button {
//                        } label: {
//                            Image(systemName: "plus")
//                                .frame(width: 25, height: 16, alignment: .center)
//                                .contentShape(Rectangle())
//                                .foregroundStyle(.secondary)
//                        }
//
//                        Divider()
//                        Button {
//                        } label: {
//                            Image(systemName: "minus")
//                                .frame(width: 20, height: 16, alignment: .center)
//                                .contentShape(Rectangle())
//                                .foregroundStyle(.secondary)
//                        }
//                    }
//                }
//            } header: {
//                HStack(spacing: 4) {
//                    Text("Exclude apps")
//                    comingSoonTag()
//                }
//            }
//        }
//        .navigationTitle("Downloads")
//    }
//}

struct HUD: View {
    @EnvironmentObject var vm: BoringViewModel
    @Default(.inlineHUD) var inlineHUD
    @Default(.enableGradient) var enableGradient
    @Default(.optionKeyAction) var optionKeyAction
    @Default(.hudReplacement) var hudReplacement
    @ObservedObject var coordinator = BoringViewCoordinator.shared
    @State private var accessibilityAuthorized = AXIsProcessTrusted()
    @State private var accessibilityPollTimer: Timer?
    
    var body: some View {
        Form {
            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("替换系统提示")
                            .font(.headline)
                        Text("通过刘海面板显示音量、屏幕亮度和键盘背光提示。")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 40)
                    Defaults.Toggle("", key: .hudReplacement)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.large)
                    .disabled(!accessibilityAuthorized)
                }
                
                if !accessibilityAuthorized {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("替换系统提示需要辅助功能权限。")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        HStack(spacing: 12) {
                            Button("请求辅助功能权限") {
                                XPCHelperClient.shared.requestAccessibilityAuthorization()
                            }
                            .buttonStyle(.borderedProminent)
                            Link("打开系统设置", destination: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                        }
                    }
                    .padding(.top, 6)
                }
            }
            
            Section {
                SettingsPicker(
                    "按住 ⌥ 键并按媒体键时",
                    selection: $optionKeyAction,
                    options: [
                        .init(.openSettings, "打开系统设置"),
                        .init(.showHUD, "显示系统提示"),
                        .init(.none, "无操作"),
                    ]
                )
                
                SettingsPicker("进度条样式", selection: $enableGradient, options: [
                    .init(false, "分层"),
                    .init(true, "渐变"),
                ])
                Defaults.Toggle(key: .systemEventIndicatorShadow) {
                    Text("启用发光效果")
                }
                Defaults.Toggle(key: .systemEventIndicatorUseAccent) {
                    Text("使用强调色着色进度条")
                }
            } header: {
                Text("常规")
            }
            .disabled(!hudReplacement)
            
            Section {
                Defaults.Toggle(key: .showOpenNotchHUD) {
                    Text("在展开的刘海面板内显示系统提示")
                }
                Defaults.Toggle(key: .showOpenNotchHUDPercentage) {
                    Text("显示百分比")
                }
                .disabled(!Defaults[.showOpenNotchHUD])
            } header: {
                HStack {
                    Text("打开刘海")
                    customBadge(text: "测试版")
                }
            }
            .disabled(!hudReplacement)
            
            Section {
                SettingsPicker("提示样式", selection: $inlineHUD, options: [
                    .init(false, "默认"),
                    .init(true, "内嵌"),
                ])
                .onChange(of: inlineHUD) { _, isInline in
                    if isInline {
                        withAnimation {
                            Defaults[.systemEventIndicatorShadow] = false
                            Defaults[.enableGradient] = false
                        }
                    }
                }
                
                Defaults.Toggle(key: .showClosedNotchHUDPercentage) {
                    Text("显示百分比")
                }
            } header: {
                Text("关闭刘海")
            }
            .disabled(!Defaults[.hudReplacement])
        }
        .accentColor(.effectiveAccent)
        .navigationTitle("系统提示")
        .onAppear {
            accessibilityAuthorized = AXIsProcessTrusted()
            accessibilityPollTimer?.invalidate()
            accessibilityPollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
                let current = AXIsProcessTrusted()
                if current != accessibilityAuthorized {
                    accessibilityAuthorized = current
                }
            }
        }
        .onDisappear {
            accessibilityPollTimer?.invalidate()
            accessibilityPollTimer = nil
        }
    }
}

struct Media: View {
    @Default(.waitInterval) var waitInterval
    @Default(.mediaController) var mediaController
    @ObservedObject var coordinator = BoringViewCoordinator.shared
    @Default(.hideNotchOption) var hideNotchOption
    @Default(.enableSneakPeek) private var enableSneakPeek
    @Default(.sneakPeekStyles) var sneakPeekStyles

    @Default(.enableLyrics) var enableLyrics
    @Default(.appleMusicLyricsCacheBookmark) private var appleMusicLyricsCacheBookmark
    @State private var lyricsCacheError: String?
    @State private var systemPlaybackUnavailable = MusicManager.shared.isSystemPlaybackUnavailable

    var body: some View {
        Form {
            Section {
                SettingsPicker(
                    "音乐源",
                    selection: $mediaController,
                    options: MediaControllerType.allCases.map {
                        .init($0, $0.displayName)
                    }
                )
                .onChange(of: mediaController) { _, _ in
                    NotificationCenter.default.post(
                        name: Notification.Name.mediaControllerChanged,
                        object: nil
                    )
                }
            } header: {
                Text("音乐源")
            } footer: {
                if mediaController == .youtubeMusic {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(mediaController.description)
                            .foregroundStyle(.secondary)
                        Link(
                            "查看 Pear Desktop",
                            destination: URL(string: "https://github.com/pear-devs/pear-desktop")!
                        )
                    }
                    .font(.caption)
                } else if mediaController.usesSystemPlayback && systemPlaybackUnavailable {
                    Text("暂时无法读取系统播放信息。可以切换音乐源后重试。")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                } else {
                    Text(mediaController.description)
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
            }
            .onReceive(MusicManager.shared.$isSystemPlaybackUnavailable.removeDuplicates()) { unavailable in
                systemPlaybackUnavailable = unavailable
            }
            
            Section {
                Toggle(
                    "显示音乐实时活动",
                    isOn: $coordinator.musicLiveActivityEnabled.animation()
                )
                Toggle("播放变化时显示预览", isOn: $enableSneakPeek)
                SettingsPicker(
                    "预览样式",
                    selection: $sneakPeekStyles,
                    options: [
                        .init(.standard, "默认"),
                        .init(.inline, "内嵌"),
                    ]
                )
                HStack {
                    Stepper(value: $waitInterval, in: 0...10, step: 1) {
                        HStack {
                            Text("媒体无操作超时")
                            Spacer()
                            Text("\(Defaults[.waitInterval], specifier: "%.0f") 秒")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                SettingsPicker(
                    "全屏行为",
                    selection: $hideNotchOption,
                    options: [
                        .init(.always, "对所有应用隐藏"),
                        .init(.nowPlayingOnly, "仅对媒体应用隐藏"),
                        .init(.never, "从不隐藏"),
                    ],
                    badge: "测试版"
                )
            } header: {
                Text("音乐播放实时活动")
            }
            
            Section {
                MusicSlotConfigurationView()
                Defaults.Toggle(key: .enableLyrics) {
                    HStack {
                        Text("在音乐中显示歌词")
                        customBadge(text: "测试版")
                    }
                }
                .onChange(of: enableLyrics) { _, _ in
                    MusicManager.shared.refreshLyricsForCurrentTrack()
                }
                if enableLyrics {
                    Button(appleMusicLyricsCacheBookmark == nil ? "授权读取 Apple Music 歌词缓存…" : "重新授权 Apple Music 歌词缓存…") {
                        DispatchQueue.main.async {
                            selectLyricsCache()
                        }
                    }
                    if appleMusicLyricsCacheBookmark != nil {
                        Button("移除歌词缓存授权") {
                            appleMusicLyricsCacheBookmark = nil
                            lyricsCacheError = nil
                        }
                    }
                    if let lyricsCacheError {
                        Text(lyricsCacheError)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("媒体控制")
            }  footer: {
                Text("自定义音乐播放器中显示的控制按钮。歌词在展开的音乐视图中显示。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accentColor(.effectiveAccent)
        .navigationTitle("媒体")
        .onChange(of: appleMusicLyricsCacheBookmark) { _, _ in
            MusicManager.shared.refreshLyricsForCurrentTrack()
        }
    }

    private func selectLyricsCache() {
        guard let window = SettingsWindowController.shared.window,
              window.isVisible, window.attachedSheet == nil else { return }

        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = false
        panel.title = "授权读取 Apple Music 歌词缓存"
        panel.directoryURL = AppleMusicCachedLyrics.directory
        panel.message = "选择 ~/Library/Caches/com.apple.Music 来读取同步歌词。"
        panel.prompt = "授权读取"
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                appleMusicLyricsCacheBookmark = try AppleMusicCachedLyrics.makeBookmark(for: url)
                lyricsCacheError = nil
            } catch {
                lyricsCacheError = "无法保存目录授权。请选择 ~/Library/Caches/com.apple.Music。"
            }
        }
    }

}

struct About: View {
    @State private var showBuildNumber: Bool = false
    let updaterController: SPUStandardUpdaterController
    @Environment(\.openWindow) var openWindow
    var body: some View {
        VStack {
            Form {
                Section {
                    HStack {
                        Text("版本名称")
                        Spacer()
                        let name = Defaults[.releaseName]
                        Text(name == "Flying Rabbit 🐇🪽" ? "飞兔 🐇🪽" : name)
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("版本")
                        Spacer()
                        if showBuildNumber {
                            Text("(\(Bundle.main.buildVersionNumber ?? ""))")
                                .foregroundStyle(.secondary)
                        }
                        Text(Bundle.main.releaseVersionNumber ?? "未知")
                            .foregroundStyle(.secondary)
                    }
                    .onTapGesture {
                        withAnimation {
                            showBuildNumber.toggle()
                        }
                    }
                } header: {
                    Text("版本信息")
                }

                UpdaterSettingsView(updater: updaterController.updater)

                HStack(spacing: 30) {
                    Spacer(minLength: 0)
                    Button {
                        if let url = URL(string: "https://github.com/lidongsevenlee/seven-island") {
                            NSWorkspace.shared.open(url)
                        }
                    } label: {
                        VStack(spacing: 5) {
                            Image("Github")
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 18)
                            Text("GitHub")
                        }
                        .contentShape(Rectangle())
                    }
                    Spacer(minLength: 0)
                }
                .buttonStyle(PlainButtonStyle())
            }
            VStack(spacing: 0) {
                Divider()
                Text("Seven Island 团队用心制作 🫶🏻")
                    .foregroundStyle(.secondary)
                    .padding(.top, 5)
                    .padding(.bottom, 7)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 10)
            }
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .toolbar {
            //            Button("Welcome window") {
            //                openWindow(id: "onboarding")
            //            }
            //            .controlSize(.extraLarge)
            CheckForUpdatesView(updater: updaterController.updater)
        }
        .navigationTitle("关于")
    }
}

//struct Extensions: View {
//    @State private var effectTrigger: Bool = false
//    var body: some View {
//        Form {
//            Section {
//                List {
//                    ForEach(extensionManager.installedExtensions.indices, id: \.self) { index in
//                        let item = extensionManager.installedExtensions[index]
//                        HStack {
//                            AppIcon(for: item.bundleIdentifier)
//                                .resizable()
//                                .frame(width: 24, height: 24)
//                            Text(item.name)
//                            ListItemPopover {
//                                Text("Description")
//                            }
//                            Spacer(minLength: 0)
//                            HStack(spacing: 6) {
//                                Circle()
//                                    .frame(width: 6, height: 6)
//                                    .foregroundColor(
//                                        isExtensionRunning(item.bundleIdentifier)
//                                            ? .green : item.status == .disabled ? .gray : .red
//                                    )
//                                    .conditionalModifier(isExtensionRunning(item.bundleIdentifier))
//                                { view in
//                                    view
//                                        .shadow(color: .green, radius: 3)
//                                }
//                                Text(
//                                    isExtensionRunning(item.bundleIdentifier)
//                                        ? "Running"
//                                        : item.status == .disabled ? "Disabled" : "Stopped"
//                                )
//                                .contentTransition(.numericText())
//                                .foregroundStyle(.secondary)
//                                .font(.footnote)
//                            }
//                            .frame(width: 60, alignment: .leading)
//
//                            Menu(
//                                content: {
//                                    Button("Restart") {
//                                        let ws = NSWorkspace.shared
//
//                                        if let ext = ws.runningApplications.first(where: {
//                                            $0.bundleIdentifier == item.bundleIdentifier
//                                        }) {
//                                            ext.terminate()
//                                        }
//
//                                        if let appURL = ws.urlForApplication(
//                                            withBundleIdentifier: item.bundleIdentifier)
//                                        {
//                                            ws.openApplication(
//                                                at: appURL, configuration: .init(),
//                                                completionHandler: nil)
//                                        }
//                                    }
//                                    .keyboardShortcut("R", modifiers: .command)
//                                    Button("Disable") {
//                                        if let ext = NSWorkspace.shared.runningApplications.first(
//                                            where: { $0.bundleIdentifier == item.bundleIdentifier })
//                                        {
//                                            ext.terminate()
//                                        }
//                                        extensionManager.installedExtensions[index].status =
//                                            .disabled
//                                    }
//                                    .keyboardShortcut("D", modifiers: .command)
//                                    Divider()
//                                    Button("Uninstall", role: .destructive) {
//                                        //
//                                    }
//                                },
//                                label: {
//                                    Image(systemName: "ellipsis.circle")
//                                        .foregroundStyle(.secondary)
//                                }
//                            )
//                            .controlSize(.regular)
//                        }
//                        .buttonStyle(PlainButtonStyle())
//                        .padding(.vertical, 5)
//                    }
//                }
//                .frame(minHeight: 120)
//                .actionBar {
//                    Button {
//                    } label: {
//                        HStack(spacing: 3) {
//                            Image(systemName: "plus")
//                            Text("Add manually")
//                        }
//                        .foregroundStyle(.secondary)
//                    }
//                    .disabled(true)
//                    Spacer()
//                    Button {
//                        withAnimation(.linear(duration: 1)) {
//                            effectTrigger.toggle()
//                        } completion: {
//                            effectTrigger.toggle()
//                        }
//                        extensionManager.checkIfExtensionsAreInstalled()
//                    } label: {
//                        HStack(spacing: 3) {
//                            Image(systemName: "arrow.triangle.2.circlepath")
//                                .rotationEffect(effectTrigger ? .degrees(360) : .zero)
//                        }
//                        .foregroundStyle(.secondary)
//                    }
//                }
//                .controlSize(.small)
//                .buttonStyle(PlainButtonStyle())
//                .overlay {
//                    if extensionManager.installedExtensions.isEmpty {
//                        Text("No extension installed")
//                            .foregroundStyle(Color(.secondaryLabelColor))
//                            .padding(.bottom, 22)
//                    }
//                }
//            } header: {
//                HStack(spacing: 0) {
//                    Text("Installed extensions")
//                    if !extensionManager.installedExtensions.isEmpty {
//                        Text(" – \(extensionManager.installedExtensions.count)")
//                            .foregroundStyle(.secondary)
//                    }
//                }
//            }
//        }
//        .accentColor(.effectiveAccent)
//        .navigationTitle("Extensions")
//        // TipsView()
//        // .padding(.horizontal, 19)
//    }
//}

private struct PanelTabSettings: View {
    @ObservedObject private var coordinator = BoringViewCoordinator.shared
    @State private var reorder = RowReorder<NotchViews>()

    var body: some View {
        let tabs = coordinator.tabLayout.orderedTabs
        let visible = Set(coordinator.tabLayout.visibleTabs.map(\.view))

        Section {
            Toggle("始终显示标签页", isOn: $coordinator.alwaysShowTabs)

            VStack(spacing: 0) {
                ForEach(tabs) { tab in
                    HStack(spacing: 12) {
                        HStack(spacing: 8) {
                            Image(systemName: "line.3.horizontal")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.secondary)
                                .frame(width: 18, height: 22)
                                .accessibilityHidden(true)
                            Text(tab.label)
                            Spacer(minLength: 8)
                        }
                        .padding(.vertical, 5)
                        .contentShape(Rectangle())
                        .reorderHandle(for: tab.view, in: reorder) { target in
                            return {
                                var layout = coordinator.tabLayout
                                layout.move(tab.view, onto: target)
                                coordinator.updateTabLayout(layout)
                            }
                        }
                        .help("拖拽调整顺序")

                        Toggle("显示\(tab.label)", isOn: Binding(
                            get: { coordinator.tabLayout.isVisible(tab.view) },
                            set: { isVisible in
                                var layout = coordinator.tabLayout
                                layout.setVisible(isVisible, for: tab.view)
                                coordinator.updateTabLayout(layout)
                            }
                        ))
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .disabled(visible == [tab.view])
                    }
                    .reorderRow(tab.view, in: reorder, background: Color(nsColor: .controlBackgroundColor))
                    .overlay(alignment: .bottom) {
                        if tab.id != tabs.last?.id { Divider().allowsHitTesting(false) }
                    }
                }
            }
            .onChange(of: tabs.map(\.view), initial: true) { _, ids in reorder.setGroups([ids]) }
            .onDisappear { reorder.reset() }
        } header: {
            Text("标签页")
        } footer: {
            Text("拖拽标签行调整顺序。前五个位置在刘海左侧，后两个在右侧。至少保留一个可见标签页。")
        }
    }
}

struct Appearance: View {
    @ObservedObject var coordinator = BoringViewCoordinator.shared
    @Default(.mirrorShape) var mirrorShape
    @Default(.sliderColor) var sliderColor
    @Default(.useMusicVisualizer) var useMusicVisualizer
    @Default(.customVisualizers) var customVisualizers
    @Default(.selectedVisualizer) var selectedVisualizer

    let icons: [String] = ["logo2"]
    @State private var selectedIcon: String = "logo2"
    @State private var selectedListVisualizer: CustomVisualizer? = nil
    @State private var isPresented: Bool = false
    @State private var name: String = ""
    @State private var url: String = ""
    @State private var speed: CGFloat = 1.0
    var body: some View {
        Form {
            Section {
                Defaults.Toggle(key: .settingsIconInNotch) {
                    Text("在刘海区域显示设置图标")
                }

            } header: {
                Text("常规")
            }

            PanelTabSettings()

            Section {
                Defaults.Toggle(key: .coloredSpectrogram) {
                    Text("彩色频谱图")
                }
                Defaults
                    .Toggle("播放器色调", key: .playerColorTinting)
                Defaults.Toggle(key: .lightingEffect) {
                    Text("启用专辑封面后的模糊效果")
                }
                SettingsPicker(
                    "滑块颜色",
                    selection: $sliderColor,
                    options: [
                        .init(.white, "白色"),
                        .init(.albumArt, "匹配专辑封面"),
                        .init(.accent, "强调色"),
                    ]
                )
            } header: {
                Text("媒体")
            }

            Section {
                Toggle(
                    "使用音乐可视化频谱",
                    isOn: $useMusicVisualizer.animation()
                )
                .disabled(true)
                if !useMusicVisualizer {
                    if customVisualizers.count > 0 {
                        SettingsPicker(
                            "所选动画",
                            selection: $selectedVisualizer,
                            options: customVisualizers.map { .init($0, $0.name) }
                        )
                    } else {
                        HStack {
                            Text("所选动画")
                            Spacer()
                            Text("没有自定义动画")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                HStack {
                    Text("自定义音乐实时活动动画")
                    customBadge(text: "即将上线")
                }
            }

            Section {
                List {
                    ForEach(customVisualizers, id: \.self) { visualizer in
                        HStack {
                            LottieView(
                                url: visualizer.url, speed: visualizer.speed,
                                loopMode: .loop
                            )
                            .frame(width: 30, height: 30, alignment: .center)
                            Text(visualizer.name)
                            Spacer(minLength: 0)
                            if selectedVisualizer == visualizer {
                                Text("已选择")
                                    .font(.caption)
                                    .fontWeight(.medium)
                                    .foregroundStyle(.secondary)
                                    .padding(.trailing, 8)
                            }
                        }
                        .buttonStyle(PlainButtonStyle())
                        .padding(.vertical, 2)
                        .background(
                            selectedListVisualizer != nil
                                ? selectedListVisualizer == visualizer
                                    ? Color.effectiveAccent : Color.clear : Color.clear,
                            in: RoundedRectangle(cornerRadius: 5)
                        )
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if selectedListVisualizer == visualizer {
                                selectedListVisualizer = nil
                                return
                            }
                            selectedListVisualizer = visualizer
                        }
                    }
                }
                .safeAreaPadding(
                    EdgeInsets(top: 5, leading: 0, bottom: 5, trailing: 0)
                )
                .frame(minHeight: 120)
                .actionBar {
                    HStack(spacing: 5) {
                        Button {
                            name = ""
                            url = ""
                            speed = 1.0
                            isPresented.toggle()
                        } label: {
                            Image(systemName: "plus")
                                .foregroundStyle(.secondary)
                                .contentShape(Rectangle())
                        }
                        Divider()
                        Button {
                            if selectedListVisualizer != nil {
                                let visualizer = selectedListVisualizer!
                                selectedListVisualizer = nil
                                customVisualizers.remove(
                                    at: customVisualizers.firstIndex(of: visualizer)!)
                                if visualizer == selectedVisualizer && customVisualizers.count > 0 {
                                    selectedVisualizer = customVisualizers[0]
                                }
                            }
                        } label: {
                            Image(systemName: "minus")
                                .foregroundStyle(.secondary)
                                .contentShape(Rectangle())
                        }
                    }
                }
                .controlSize(.small)
                .buttonStyle(PlainButtonStyle())
                .overlay {
                    if customVisualizers.isEmpty {
                        Text("没有自定义动画")
                            .foregroundStyle(Color(.secondaryLabelColor))
                            .padding(.bottom, 22)
                    }
                }
                .sheet(isPresented: $isPresented) {
                    VStack(alignment: .leading) {
                        Text("添加新动画")
                            .font(.largeTitle.bold())
                            .padding(.vertical)
                        TextField("名称", text: $name)
                        TextField("Lottie JSON 地址", text: $url)
                        HStack {
                            Text("速度")
                            Spacer(minLength: 80)
                            Text("\(speed, specifier: "%.1f") 倍")
                                .multilineTextAlignment(.trailing)
                                .foregroundStyle(.secondary)
                            Slider(value: $speed, in: 0...2, step: 0.1)
                        }
                        .padding(.vertical)
                        HStack {
                            Button {
                                isPresented.toggle()
                            } label: {
                                Text("取消")
                                    .frame(maxWidth: .infinity, alignment: .center)
                            }

                            Button {
                                let visualizer: CustomVisualizer = .init(
                                    UUID: UUID(),
                                    name: name,
                                    url: URL(string: url)!,
                                    speed: speed
                                )

                                if !customVisualizers.contains(visualizer) {
                                    customVisualizers.append(visualizer)
                                }

                                isPresented.toggle()
                            } label: {
                                Text("添加")
                                    .frame(maxWidth: .infinity, alignment: .center)
                            }
                            .buttonStyle(BorderedProminentButtonStyle())
                        }
                    }
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .controlSize(.extraLarge)
                    .padding()
                }
            } header: {
                HStack(spacing: 0) {
                    Text("自定义动画 (Lottie)")
                    if !Defaults[.customVisualizers].isEmpty {
                        Text(" – \(Defaults[.customVisualizers].count)")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                Defaults.Toggle(key: .showMirror) {
                    Text("启用镜像")
                }
                    .disabled(!checkVideoInput())
                SettingsPicker("镜像形状", selection: $mirrorShape, options: [
                    .init(.circle, "圆形"),
                    .init(.rectangle, "方形"),
                ])
                Defaults.Toggle(key: .showNotHumanFace) {
                    Text("空闲时显示趣味面部动画")
                }
            } header: {
                HStack {
                    Text("其他功能")
                }
            }
        }
        .accentColor(.effectiveAccent)
        .navigationTitle("外观")
    }

    func checkVideoInput() -> Bool {
        if AVCaptureDevice.default(for: .video) != nil {
            return true
        }

        return false
    }
}

struct Advanced: View {
    @Default(.useCustomAccentColor) var useCustomAccentColor
    @Default(.customAccentColorData) var customAccentColorData
    @Default(.extendHoverArea) var extendHoverArea
    @Default(.showOnLockScreen) var showOnLockScreen
    @Default(.hideFromScreenRecording) var hideFromScreenRecording
    
    @State private var customAccentColor: Color = .accentColor
    @State private var selectedPresetColor: PresetAccentColor? = nil

    // macOS accent colors
    enum PresetAccentColor: String, CaseIterable, Identifiable {
        case blue = "Blue"
        case purple = "Purple"
        case pink = "Pink"
        case red = "Red"
        case orange = "Orange"
        case yellow = "Yellow"
        case green = "Green"
        case graphite = "Graphite"
        
        var id: String { self.rawValue }
        
        var color: Color {
            switch self {
            case .blue: return Color(red: 0.0, green: 0.478, blue: 1.0)
            case .purple: return Color(red: 0.686, green: 0.322, blue: 0.871)
            case .pink: return Color(red: 1.0, green: 0.176, blue: 0.333)
            case .red: return Color(red: 1.0, green: 0.271, blue: 0.227)
            case .orange: return Color(red: 1.0, green: 0.584, blue: 0.0)
            case .yellow: return Color(red: 1.0, green: 0.8, blue: 0.0)
            case .green: return Color(red: 0.4, green: 0.824, blue: 0.176)
            case .graphite: return Color(red: 0.557, green: 0.557, blue: 0.576)
            }
        }
    }
    
    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 16) {
                    // Toggle between system and custom
                    Picker("强调色", selection: $useCustomAccentColor) {
                        Text("系统").tag(false)
                        Text("自定义").tag(true)
                    }
                    .pickerStyle(.segmented)
                    
                    if !useCustomAccentColor {
                        // System accent info
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 12) {
                                AccentCircleButton(
                                    isSelected: true,
                                    color: .accentColor,
                                    isSystemDefault: true
                                ) {}
                                
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("使用系统强调色")
                                        .font(.body)
                                    Text("您的 macOS 系统强调色")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                        }
                    } else {
                        // Custom color options
                        VStack(alignment: .leading, spacing: 12) {
                            Text("颜色预设")
                                .font(.caption)
                                .fontWeight(.semibold)
                                .foregroundStyle(.secondary)
                            
                            HStack(spacing: 12) {
                                ForEach(PresetAccentColor.allCases) { preset in
                                    AccentCircleButton(
                                        isSelected: selectedPresetColor == preset,
                                        color: preset.color,
                                        isMulticolor: false
                                    ) {
                                        selectedPresetColor = preset
                                        customAccentColor = preset.color
                                        saveCustomColor(preset.color)
                                        forceUiUpdate()
                                    }
                                }
                                Spacer()
                            }
                            
                            Divider()
                                .padding(.vertical, 4)
                            
                            // Custom color picker
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("选择颜色")
                                        .font(.body)
                                    Text("选择任意颜色")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                
                                Spacer()
                                
                                ColorPicker(selection: Binding(
                                    get: { customAccentColor },
                                    set: { newColor in
                                        customAccentColor = newColor
                                        selectedPresetColor = nil
                                        saveCustomColor(newColor)
                                        forceUiUpdate()
                                    }
                                ), supportsOpacity: false) {
                                    ZStack {
                                        Circle()
                                            .fill(customAccentColor)
                                            .frame(width: 32, height: 32)
                                        
                                        if selectedPresetColor == nil {
                                            Circle()
                                                .strokeBorder(.primary.opacity(0.3), lineWidth: 2)
                                                .frame(width: 32, height: 32)
                                        }
                                    }
                                }
                                .labelsHidden()
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
            } header: {
                Text("强调色")
            } footer: {
                Text("选择系统强调色或自定义颜色。")
                    .multilineTextAlignment(.trailing)
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
            .onAppear {
                initializeAccentColorState()
            }
            
            Section {
                Defaults.Toggle(key: .enableShadow) {
                    Text("启用窗口阴影")
                }
                Defaults.Toggle(key: .cornerRadiusScaling) {
                    Text("圆角缩放")
                }
            } header: {
                Text("窗口外观")
            }

            Section {
                Defaults.Toggle(key: .extendHoverArea) {
                    Text("扩展悬停区域")
                }
                Defaults.Toggle(key: .hideTitleBar) {
                    Text("隐藏标题栏")
                }
                Defaults.Toggle(key: .showOnLockScreen) {
                    Text("在锁屏时显示刘海")
                }
                Defaults.Toggle(key: .hideFromScreenRecording) {
                    Text("在录屏时隐藏")
                }
            } header: {
                Text("窗口行为")
            }
        }
        .accentColor(.effectiveAccent)
        .navigationTitle("高级")
        .onAppear {
            loadCustomColor()
        }
    }
    
    private func forceUiUpdate() {
        // Force refresh the UI
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: Notification.Name("AccentColorChanged"), object: nil)
        }
    }
    
    private func saveCustomColor(_ color: Color) {
        let nsColor = NSColor(color)
        if let colorData = try? NSKeyedArchiver.archivedData(withRootObject: nsColor, requiringSecureCoding: false) {
            Defaults[.customAccentColorData] = colorData
            forceUiUpdate()
        }
    }
    
    private func loadCustomColor() {
        if let colorData = Defaults[.customAccentColorData],
           let nsColor = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: colorData) {
            customAccentColor = Color(nsColor: nsColor)
            
            // Check if loaded color matches a preset
            selectedPresetColor = nil
            for preset in PresetAccentColor.allCases {
                if colorsAreEqual(Color(nsColor: nsColor), preset.color) {
                    selectedPresetColor = preset
                    break
                }
            }
        }
    }
    
    private func colorsAreEqual(_ color1: Color, _ color2: Color) -> Bool {
        let nsColor1 = NSColor(color1).usingColorSpace(.sRGB) ?? NSColor(color1)
        let nsColor2 = NSColor(color2).usingColorSpace(.sRGB) ?? NSColor(color2)
        
        return abs(nsColor1.redComponent - nsColor2.redComponent) < 0.01 &&
               abs(nsColor1.greenComponent - nsColor2.greenComponent) < 0.01 &&
               abs(nsColor1.blueComponent - nsColor2.blueComponent) < 0.01
    }
    
    private func initializeAccentColorState() {
        if !useCustomAccentColor {
            selectedPresetColor = nil // Multicolor is selected when useCustomAccentColor is false
        } else {
            loadCustomColor()
        }
    }
}

// MARK: - Accent Circle Button Component
struct AccentCircleButton: View {
    let isSelected: Bool
    let color: Color
    var isSystemDefault: Bool = false
    var isMulticolor: Bool = false
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            ZStack {
                // Color circle
                Circle()
                    .fill(color)
                    .frame(width: 32, height: 32)
                
                // Subtle border
                Circle()
                    .strokeBorder(Color.primary.opacity(0.15), lineWidth: 1)
                    .frame(width: 32, height: 32)
                
                // Apple-style highlight ring around the middle when selected
                if isSelected {
                    Circle()
                        .strokeBorder(
                            Color.white.opacity(0.5),
                            lineWidth: 2
                        )
                        .frame(width: 28, height: 28)
                }
            }
        }
        .buttonStyle(.plain)
        .help(isSystemDefault ? "使用您的 macOS 系统强调色" : "")
    }
}



func proFeatureBadge() -> some View {
    Text("升级至专业版")
        .foregroundStyle(Color(red: 0.545, green: 0.196, blue: 0.98))
        .font(.footnote.bold())
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 4).stroke(
                Color(red: 0.545, green: 0.196, blue: 0.98), lineWidth: 1))
}

func comingSoonTag() -> some View {
    Text("即将上线")
        .foregroundStyle(.secondary)
        .font(.footnote.bold())
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .background(Color(nsColor: .secondarySystemFill))
        .clipShape(.capsule)
}

func customBadge(text: String) -> some View {
    Text(text)
        .foregroundStyle(.secondary)
        .font(.footnote.bold())
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .background(Color(nsColor: .secondarySystemFill))
        .clipShape(.capsule)
}

func warningBadge(_ text: String, _ description: String) -> some View {
    Section {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 22))
                .foregroundStyle(.yellow)
            VStack(alignment: .leading) {
                Text(text)
                    .font(.headline)
                Text(description)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
}

#Preview {
    HUD()
}
