//
//  ContentView.swift
//  boringNotchApp
//
//  Created by Harsh Vardhan Goswami  on 02/08/24
//  Modified by Richard Kunkli on 24/08/2024.
//

import AVFoundation
import Combine
import Defaults
import KeyboardShortcuts
import SwiftUI
import SwiftUIIntrospect

@MainActor
struct ContentView: View {
    @EnvironmentObject var vm: BoringViewModel
    @ObservedObject var webcamManager = WebcamManager.shared

    @ObservedObject var coordinator = BoringViewCoordinator.shared
    @ObservedObject var musicManager = MusicManager.shared
    @ObservedObject var batteryModel = BatteryStatusViewModel.shared
    @ObservedObject var brightnessManager = BrightnessManager.shared
    @ObservedObject var volumeManager = VolumeManager.shared
    @ObservedObject var codexStatusService = CodexStatusService.shared
    @ObservedObject var claudeStatusService = ClaudeStatusService.shared
    @State private var showClaudeInAlternation = false
    @State private var hoverTask: Task<Void, Never>?
    @State private var isHovering: Bool = false
    @State private var anyDropDebounceTask: Task<Void, Never>?

    @State private var gestureProgress: CGFloat = .zero

    @State private var haptics: Bool = false

    @Namespace var albumArtNamespace

    @Default(.useMusicVisualizer) var useMusicVisualizer

    @Default(.showNotHumanFace) var showNotHumanFace

    // Shared interactive spring for movement/resizing to avoid conflicting animations
    private let animationSpring = Animation.interactiveSpring(response: 0.38, dampingFraction: 0.8, blendDuration: 0)

    private let extendedHoverPadding: CGFloat = 30
    private let zeroHeightHoverPadding: CGFloat = 10

    private var topCornerRadius: CGFloat {
       ((vm.notchState == .open) && Defaults[.cornerRadiusScaling])
                ? cornerRadiusInsets.opened.top
                : cornerRadiusInsets.closed.top
    }

    private var currentNotchShape: NotchShape {
        NotchShape(
            topCornerRadius: topCornerRadius,
            bottomCornerRadius: ((vm.notchState == .open) && Defaults[.cornerRadiusScaling])
                ? cornerRadiusInsets.opened.bottom
                : cornerRadiusInsets.closed.bottom
        )
    }

    private var computedChinWidth: CGFloat {
        var chinWidth: CGFloat = vm.closedNotchSize.width

        if coordinator.expandingView.type == .battery && coordinator.expandingView.show
            && vm.notchState == .closed && Defaults[.showPowerStatusNotifications]
        {
            chinWidth = 640
        } else if shouldShowCodexLiveActivity || shouldShowClaudeLiveActivity {
            chinWidth += (max(0, vm.effectiveClosedNotchHeight - 12) + codexClosedSessionCountWidth + 20)
        } else if shouldShowMusicLiveActivity {
            chinWidth += (2 * max(0, vm.effectiveClosedNotchHeight - 12) + 20)
        } else if !coordinator.expandingView.show && vm.notchState == .closed
            && (!musicManager.isPlaying && musicManager.isPlayerIdle) && Defaults[.showNotHumanFace]
            && !vm.hideOnClosed
        {
            chinWidth += (2 * max(0, vm.effectiveClosedNotchHeight - 12) + 20)
        }

        return chinWidth
    }

    private var codexClosedSessionCountWidth: CGFloat {
        max(0, vm.effectiveClosedNotchHeight - 12)
    }

    private var shouldShowMusicLiveActivity: Bool {
        (!coordinator.expandingView.show || coordinator.expandingView.type == .music)
            && vm.notchState == .closed
            && (musicManager.isPlaying || !musicManager.isPlayerIdle)
            && coordinator.musicLiveActivityEnabled
            && !vm.hideOnClosed
    }

    private var shouldShowClosedLyrics: Bool {
        Defaults[.enableLyrics]
            && shouldShowMusicLiveActivity
            && (musicManager.isFetchingLyrics
                || !musicManager.syncedLyrics.isEmpty
                || !musicManager.currentLyrics.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    private var shouldShowCodexLiveActivity: Bool {
        !coordinator.expandingView.show
            && vm.notchState == .closed
            && !vm.hideOnClosed
            && codexStatusService.snapshot.shouldShowClosedLiveActivity
            && (coordinator.currentView == .codexStatus || !shouldShowMusicLiveActivity)
    }

    private var shouldShowClaudeLiveActivity: Bool {
        !coordinator.expandingView.show
            && vm.notchState == .closed
            && !vm.hideOnClosed
            && claudeStatusService.snapshot.shouldShowClosedLiveActivity
            && (coordinator.currentView == .claudeStatus || !shouldShowMusicLiveActivity)
    }

    private var bothActive: Bool {
        shouldShowCodexLiveActivity && shouldShowClaudeLiveActivity
    }

    var body: some View {
        // Calculate scale based on gesture progress only
        let gestureScale: CGFloat = {
            guard gestureProgress != 0 else { return 1.0 }
            let scaleFactor = 1.0 + gestureProgress * 0.01
            return max(0.6, scaleFactor)
        }()
        
        ZStack(alignment: .top) {
            VStack(spacing: 0) {
                let mainLayout = NotchLayout()
                    .frame(alignment: .top)
                    .padding(
                        .horizontal,
                        vm.notchState == .open
                        ? Defaults[.cornerRadiusScaling]
                        ? (cornerRadiusInsets.opened.top) : (cornerRadiusInsets.opened.bottom)
                        : cornerRadiusInsets.closed.bottom
                    )
                    .padding([.horizontal, .bottom], vm.notchState == .open ? 12 : 0)
                    .background(.black)
                    .clipShape(currentNotchShape)
                    .overlay(alignment: .top) {
                        Rectangle()
                            .fill(.black)
                            .frame(height: 1)
                            .padding(.horizontal, topCornerRadius)
                    }
                    .shadow(
                        color: ((vm.notchState == .open || isHovering) && Defaults[.enableShadow])
                            ? .black.opacity(0.7) : .clear, radius: Defaults[.cornerRadiusScaling] ? 6 : 4
                    )
                    .padding(
                        .bottom,
                        vm.effectiveClosedNotchHeight == 0 ? 10 : 0
                    )
                
                mainLayout
                    .frame(height: vm.notchState == .open ? vm.notchSize.height : nil, alignment: .top)
                    .conditionalModifier(true) { view in
                        let openAnimation = Animation.spring(response: 0.42, dampingFraction: 0.8, blendDuration: 0)
                        let closeAnimation = Animation.spring(response: 0.45, dampingFraction: 1.0, blendDuration: 0)

                        return view
                            .animation(vm.notchState == .open ? openAnimation : closeAnimation, value: vm.notchState)
                            .animation(.smooth, value: gestureProgress)
                    }
                    .contentShape(Rectangle())
                    .onHover { hovering in
                        handleHover(hovering)
                    }
                    .gesture(
                        TapGesture()
                            .onEnded { _ in
                                if vm.notchState == .closed {
                                    doOpen()
                                }
                            }
                    )
                    .conditionalModifier(Defaults[.enableGestures]) { view in
                        view
                            .panGesture(direction: .down) { translation, phase in
                                handleDownGesture(translation: translation, phase: phase)
                            }
                    }
                    .conditionalModifier(Defaults[.closeGestureEnabled] && Defaults[.enableGestures]) { view in
                        view
                            .panGesture(direction: .up) { translation, phase in
                                handleUpGesture(translation: translation, phase: phase)
                            }
                    }
                    .onReceive(NotificationCenter.default.publisher(for: .sharingDidFinish)) { _ in
                        if vm.notchState == .open && !isHovering && !vm.isBatteryPopoverActive {
                            hoverTask?.cancel()
                            hoverTask = Task {
                                try? await Task.sleep(for: .milliseconds(100))
                                guard !Task.isCancelled else { return }
                                await MainActor.run {
                                    if self.vm.notchState == .open && !self.isHovering && !self.vm.isBatteryPopoverActive && !SharingStateManager.shared.preventNotchClose {
                                        self.vm.close()
                                    }
                                }
                            }
                        }
                    }
                    .onChange(of: vm.notchState) { _, newState in
                        if newState == .closed && isHovering {
                            withAnimation {
                                isHovering = false
                            }
                        }
                        if newState == .open {
                            let targetHeight: CGFloat = {
                                switch coordinator.currentView {
                                case .home, .shelf:
                                    return openNotchSize.height
                                case .clipboard, .vscodeProjects:
                                    return sevenIslandFeatureNotchHeight
                                case .codexStatus, .claudeStatus:
                                    return sevenIslandFeatureNotchHeight
                                default:
                                    return openNotchSize.height
                                }
                            }()
                            withAnimation(.smooth(duration: 0.35)) {
                                vm.setOpenNotchHeight(targetHeight)
                            }
                        }
                    }
                    .onChange(of: coordinator.currentView) { _, newView in
                        let targetHeight: CGFloat = {
                            switch newView {
                            case .home, .shelf:
                                return openNotchSize.height
                            case .clipboard, .vscodeProjects:
                                return sevenIslandFeatureNotchHeight
                            case .codexStatus, .claudeStatus:
                                return sevenIslandFeatureNotchHeight
                            default:
                                return openNotchSize.height
                            }
                        }()
                        withAnimation(.smooth(duration: 0.35)) {
                            vm.setOpenNotchHeight(targetHeight)
                        }
                    }
                    .onChange(of: vm.isBatteryPopoverActive) {
                        if !vm.isBatteryPopoverActive && !isHovering && vm.notchState == .open && !SharingStateManager.shared.preventNotchClose {
                            hoverTask?.cancel()
                            hoverTask = Task {
                                try? await Task.sleep(for: .milliseconds(100))
                                guard !Task.isCancelled else { return }
                                await MainActor.run {
                                    if !self.vm.isBatteryPopoverActive && !self.isHovering && self.vm.notchState == .open && !SharingStateManager.shared.preventNotchClose {
                                        self.vm.close()
                                    }
                                }
                            }
                        }
                    }
                    .sensoryFeedback(.alignment, trigger: haptics)
                    .contextMenu {
                        Button("Settings") {
                            DispatchQueue.main.async {
                                SettingsWindowController.shared.showWindow()
                            }
                        }
                        .keyboardShortcut(KeyEquivalent(","), modifiers: .command)
                        //                    Button("Edit") { // Doesnt work....
                        //                        let dn = DynamicNotch(content: EditPanelView())
                        //                        dn.toggle()
                        //                    }
                        //                    .keyboardShortcut("E", modifiers: .command)
                    }
                if vm.chinHeight > 0 {
                    Rectangle()
                        .fill(Color.black.opacity(0.01))
                        .frame(width: computedChinWidth, height: vm.chinHeight)
                }
            }
        }
        .padding(.bottom, 8)
        .frame(maxWidth: windowSize.width, maxHeight: windowSize.height, alignment: .top)
        .compositingGroup()
        .scaleEffect(
            x: gestureScale,
            y: gestureScale,
            anchor: .top
        )
        .animation(.smooth, value: gestureProgress)
        .background(dragDetector)
        .preferredColorScheme(.dark)
        .environmentObject(vm)
        .onAppear {
            codexStatusService.refresh()
            claudeStatusService.refresh()
        }
        .onReceive(Timer.publish(every: 10, on: .main, in: .common).autoconnect()) { _ in
            codexStatusService.refresh()
            claudeStatusService.refresh()
        }
        .onReceive(Timer.publish(every: 3, on: .main, in: .common).autoconnect()) { _ in
            if bothActive {
                showClaudeInAlternation.toggle()
            }
        }
        .onChange(of: bothActive) { _, isBothActive in
            if !isBothActive {
                showClaudeInAlternation = false
            }
        }
        .onChange(of: vm.anyDropZoneTargeting) { _, isTargeted in
            anyDropDebounceTask?.cancel()

            if isTargeted {
                if vm.notchState == .closed {
                    coordinator.currentView = .shelf
                    doOpen()
                }
                return
            }

            anyDropDebounceTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }

                if vm.dropEvent {
                    vm.dropEvent = false
                    return
                }

                vm.dropEvent = false
                if !SharingStateManager.shared.preventNotchClose {
                    vm.close()
                }
            }
        }
    }

    @ViewBuilder
    func NotchLayout() -> some View {
        VStack(alignment: .leading) {
            VStack(alignment: .leading) {
                if coordinator.helloAnimationRunning {
                    Spacer()
                    HelloAnimation(onFinish: {
                        vm.closeHello()
                    }).frame(
                        width: getClosedNotchSize().width,
                        height: 80
                    )
                    .padding(.top, 40)
                    Spacer()
                } else {
                    if coordinator.expandingView.type == .battery && coordinator.expandingView.show
                        && vm.notchState == .closed && Defaults[.showPowerStatusNotifications]
                    {
                        HStack(spacing: 0) {
                            HStack {
                                Text(batteryModel.statusText)
                                    .font(.subheadline)
                                    .foregroundStyle(.white)
                            }

                            Rectangle()
                                .fill(.black)
                                .frame(width: vm.closedNotchSize.width + 10)

                            HStack {
                                BoringBatteryView(
                                    batteryWidth: 30,
                                    isCharging: batteryModel.isCharging,
                                    isInLowPowerMode: batteryModel.isInLowPowerMode,
                                    isPluggedIn: batteryModel.isPluggedIn,
                                    levelBattery: batteryModel.levelBattery,
                                    isForNotification: true
                                )
                            }
                            .frame(width: 76, alignment: .trailing)
                        }
                        .frame(height: vm.effectiveClosedNotchHeight, alignment: .center)
                      } else if coordinator.sneakPeek.show && Defaults[.inlineHUD] && (coordinator.sneakPeek.type != .music) && (coordinator.sneakPeek.type != .battery) && vm.notchState == .closed {
                          InlineHUD(type: $coordinator.sneakPeek.type, value: $coordinator.sneakPeek.value, icon: $coordinator.sneakPeek.icon, hoverAnimation: $isHovering, gestureProgress: $gestureProgress)
                              .transition(.opacity)
                      } else if bothActive {
                          Group {
                              if showClaudeInAlternation {
                                  ClaudeLiveActivity()
                              } else {
                                  CodexLiveActivity()
                              }
                          }
                          .frame(alignment: .center)
                      } else if shouldShowClaudeLiveActivity {
                          ClaudeLiveActivity()
                              .frame(alignment: .center)
                      } else if shouldShowCodexLiveActivity {
                          CodexLiveActivity()
                              .frame(alignment: .center)
                      } else if shouldShowMusicLiveActivity {
                          MusicLiveActivity()
                              .frame(alignment: .center)
                          if shouldShowClosedLyrics {
                              ClosedMusicLyricsLineView(width: computedChinWidth)
                                  .allowsHitTesting(false)
                                  .transition(.opacity.combined(with: .move(edge: .top)))
                          }
                      } else if !coordinator.expandingView.show && vm.notchState == .closed && (!musicManager.isPlaying && musicManager.isPlayerIdle) && Defaults[.showNotHumanFace] && !vm.hideOnClosed  {
                          BoringFaceAnimation()
                       } else if vm.notchState == .open {
                           BoringHeader()
                               .frame(height: max(24, vm.effectiveClosedNotchHeight))
                               .opacity(gestureProgress != 0 ? 1.0 - min(abs(gestureProgress) * 0.1, 0.3) : 1.0)
                       } else {
                           Rectangle().fill(.clear).frame(width: vm.closedNotchSize.width - 20, height: vm.effectiveClosedNotchHeight)
                       }

                      if coordinator.sneakPeek.show {
                          if (coordinator.sneakPeek.type != .music) && (coordinator.sneakPeek.type != .battery) && !Defaults[.inlineHUD] && vm.notchState == .closed {
                              SystemEventIndicatorModifier(
                                  eventType: $coordinator.sneakPeek.type,
                                  value: $coordinator.sneakPeek.value,
                                  icon: $coordinator.sneakPeek.icon,
                                  sendEventBack: { newVal in
                                      switch coordinator.sneakPeek.type {
                                      case .volume:
                                          VolumeManager.shared.setAbsolute(Float32(newVal))
                                      case .brightness:
                                          BrightnessManager.shared.setAbsolute(value: Float32(newVal))
                                      default:
                                          break
                                      }
                                  }
                              )
                              .padding(.bottom, 10)
                              .padding(.leading, 4)
                              .padding(.trailing, 8)
                          }
                          // Old sneak peek music
                          else if coordinator.sneakPeek.type == .music {
                              if vm.notchState == .closed && !vm.hideOnClosed && Defaults[.sneakPeekStyles] == .standard {
                                  HStack(alignment: .center) {
                                      Image(systemName: "music.note")
                                      GeometryReader { geo in
                                          MarqueeText(.constant(musicManager.songTitle + " - " + musicManager.artistName),  textColor: Defaults[.playerColorTinting] ? Color(nsColor: musicManager.avgColor).ensureMinimumBrightness(factor: 0.6) : .gray, minDuration: 1, frameWidth: geo.size.width)
                                      }
                                  }
                                  .foregroundStyle(.gray)
                                  .padding(.bottom, 10)
                              }
                          }
                      }
                  }
              }
              .conditionalModifier((coordinator.sneakPeek.show && (coordinator.sneakPeek.type == .music) && vm.notchState == .closed && !vm.hideOnClosed && Defaults[.sneakPeekStyles] == .standard) || (coordinator.sneakPeek.show && (coordinator.sneakPeek.type != .music) && (vm.notchState == .closed))) { view in
                  view
                      .fixedSize()
              }
              .zIndex(2)
            if vm.notchState == .open {
                VStack {
                    switch coordinator.currentView {
                    case .home:
                        NotchHomeView(albumArtNamespace: albumArtNamespace)
                    case .shelf:
                        ShelfView()
                    case .clipboard:
                        ClipboardHistoryView()
                    case .vscodeProjects:
                        VSCodeProjectsView()
                    case .codexStatus:
                        CodexStatusView()
                    case .claudeStatus:
                        ClaudeStatusView()
                    }
                }
                .transition(
                    .scale(scale: 0.8, anchor: .top)
                    .combined(with: .opacity)
                    .animation(.smooth(duration: 0.35))
                )
                .zIndex(1)
                .allowsHitTesting(vm.notchState == .open)
                .opacity(gestureProgress != 0 ? 1.0 - min(abs(gestureProgress) * 0.1, 0.3) : 1.0)
            }
        }
        .onDrop(of: [.fileURL, .url, .utf8PlainText, .plainText, .data], delegate: GeneralDropTargetDelegate(isTargeted: $vm.generalDropTargeting))
    }

    @ViewBuilder
    func BoringFaceAnimation() -> some View {
        HStack {
            HStack {
                Rectangle()
                    .fill(.clear)
                    .frame(
                        width: max(0, vm.effectiveClosedNotchHeight - 12),
                        height: max(0, vm.effectiveClosedNotchHeight - 12)
                    )
                Rectangle()
                    .fill(.black)
                    .frame(width: vm.closedNotchSize.width - 20)
                MinimalFaceFeatures()
            }
        }.frame(
            height: vm.effectiveClosedNotchHeight,
            alignment: .center
        )
    }

    @ViewBuilder
    func CodexLiveActivity() -> some View {
        let activity = codexStatusService.snapshot.currentActivity
        let statusSize = max(0, vm.effectiveClosedNotchHeight - 12)

        HStack {
            CodexAppIcon(size: statusSize, isWorking: activity?.state == .working)
            .help(activity?.headline ?? "Codex is working")

            Rectangle()
                .fill(.black)
                .overlay(
                    HStack(alignment: .center, spacing: 8) {
                        if coordinator.expandingView.show && Defaults[.sneakPeekStyles] == .inline {
                            MarqueeText(
                                .constant(activity?.headline ?? "Codex is working"),
                                textColor: .green,
                                minDuration: 0.4,
                                frameWidth: 120
                            )
                            Spacer(minLength: vm.closedNotchSize.width)
                            Text(activity?.lastToolName ?? "Codex")
                                .lineLimit(1)
                                .foregroundStyle(Color.green)
                        }
                    }
                )
                .frame(width: vm.closedNotchSize.width + -cornerRadiusInsets.closed.top)

            CodexClosedSessionCountBadge(count: codexStatusService.snapshot.recentSessions.count, width: codexClosedSessionCountWidth)
            .help("\(codexStatusService.snapshot.recentSessions.count) Codex sessions")
        }
        .frame(height: vm.effectiveClosedNotchHeight, alignment: .center)
    }

    @ViewBuilder
    func ClaudeLiveActivity() -> some View {
        let activity = claudeStatusService.snapshot.currentActivity
        let statusSize = max(0, vm.effectiveClosedNotchHeight - 12)

        HStack {
            ClaudeAppIcon(size: statusSize, isWorking: activity?.state == .working)
            .help(activity?.headline ?? "Claude is working")

            Rectangle()
                .fill(.black)
                .overlay(
                    HStack(alignment: .center, spacing: 8) {
                        if coordinator.expandingView.show && Defaults[.sneakPeekStyles] == .inline {
                            MarqueeText(
                                .constant(activity?.headline ?? "Claude is working"),
                                textColor: .orange,
                                minDuration: 0.4,
                                frameWidth: 120
                            )
                            Spacer(minLength: vm.closedNotchSize.width)
                            Text(activity?.lastToolName ?? "Claude")
                                .lineLimit(1)
                                .foregroundStyle(Color.orange)
                        }
                    }
                )
                .frame(width: vm.closedNotchSize.width + -cornerRadiusInsets.closed.top)

            ClaudeClosedSessionCountBadge(count: claudeStatusService.snapshot.recentSessions.count, width: codexClosedSessionCountWidth)
            .help("\(claudeStatusService.snapshot.recentSessions.count) Claude sessions")
        }
        .frame(height: vm.effectiveClosedNotchHeight, alignment: .center)
    }

    @ViewBuilder
    func MusicLiveActivity() -> some View {
        HStack {
            Image(nsImage: musicManager.albumArt)
                .resizable()
                .clipped()
                .clipShape(
                    RoundedRectangle(
                        cornerRadius: MusicPlayerImageSizes.cornerRadiusInset.closed)
                )
                .matchedGeometryEffect(id: "albumArt", in: albumArtNamespace)
                .frame(
                    width: max(0, vm.effectiveClosedNotchHeight - 12),
                    height: max(0, vm.effectiveClosedNotchHeight - 12)
                )

            Rectangle()
                .fill(.black)
                .overlay(
                    HStack(alignment: .top) {
                        if coordinator.expandingView.show
                            && coordinator.expandingView.type == .music
                        {
                            MarqueeText(
                                .constant(musicManager.songTitle),
                                textColor: Defaults[.coloredSpectrogram]
                                    ? Color(nsColor: musicManager.avgColor) : Color.gray,
                                minDuration: 0.4,
                                frameWidth: 100
                            )
                            .opacity(
                                (coordinator.expandingView.show
                                    && Defaults[.sneakPeekStyles] == .inline)
                                    ? 1 : 0
                            )
                            Spacer(minLength: vm.closedNotchSize.width)
                            // Song Artist
                            Text(musicManager.artistName)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .foregroundStyle(
                                    Defaults[.coloredSpectrogram]
                                        ? Color(nsColor: musicManager.avgColor)
                                        : Color.gray
                                )
                                .opacity(
                                    (coordinator.expandingView.show
                                        && coordinator.expandingView.type == .music
                                        && Defaults[.sneakPeekStyles] == .inline)
                                        ? 1 : 0
                                )
                        }
                    }
                )
                .frame(
                    width: (coordinator.expandingView.show
                        && coordinator.expandingView.type == .music
                        && Defaults[.sneakPeekStyles] == .inline)
                        ? 380
                        : vm.closedNotchSize.width
                            + -cornerRadiusInsets.closed.top
                )

            HStack {
                if useMusicVisualizer {
                    Rectangle()
                        .fill(
                            Defaults[.coloredSpectrogram]
                                ? Color(nsColor: musicManager.avgColor).gradient
                                : Color.gray.gradient
                        )
                        .frame(width: 50, alignment: .center)
                        .matchedGeometryEffect(id: "spectrum", in: albumArtNamespace)
                        .mask {
                            AudioSpectrumView(isPlaying: $musicManager.isPlaying)
                                .frame(width: 16, height: 12)
                        }
                } else {
                    LottieAnimationContainer()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(
                width: max(
                    0,
                    vm.effectiveClosedNotchHeight - 12
                        + gestureProgress / 2
                ),
                height: max(
                    0,
                    vm.effectiveClosedNotchHeight - 12
                ),
                alignment: .center
            )
        }
        .frame(
            height: vm.effectiveClosedNotchHeight,
            alignment: .center
        )
    }

    @ViewBuilder
    var dragDetector: some View {
        if Defaults[.boringShelf] && vm.notchState == .closed {
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        .onDrop(of: [.fileURL, .url, .utf8PlainText, .plainText, .data], isTargeted: $vm.dragDetectorTargeting) { providers in
            vm.dropEvent = true
            ShelfStateViewModel.shared.load(providers)
            return true
        }
        } else {
            EmptyView()
        }
    }

    private func doOpen() {
        withAnimation(animationSpring) {
            vm.open()
        }
    }

    // MARK: - Hover Management

    private func handleHover(_ hovering: Bool) {
        if coordinator.firstLaunch { return }
        hoverTask?.cancel()
        
        if hovering {
            isHovering = true

            if vm.notchState == .closed && Defaults[.enableHaptics] {
                haptics.toggle()
            }
            
            guard vm.notchState == .closed,
                  !coordinator.sneakPeek.show,
                  Defaults[.openNotchOnHover] else { return }
            
            hoverTask = Task {
                try? await Task.sleep(for: .seconds(Defaults[.minimumHoverDuration]))
                guard !Task.isCancelled else { return }
                
                await MainActor.run {
                    guard self.vm.notchState == .closed,
                          self.isHovering,
                          !self.coordinator.sneakPeek.show else { return }
                    
                    self.doOpen()
                }
            }
        } else {
            hoverTask = Task {
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled else { return }

                await MainActor.run {
                    withAnimation(animationSpring) {
                        self.isHovering = false
                    }

                    if self.vm.notchState == .open && !self.vm.isBatteryPopoverActive && !SharingStateManager.shared.preventNotchClose {
                        self.vm.close()
                    }
                }
            }
        }
    }

    // MARK: - Gesture Handling

    private func handleDownGesture(translation: CGFloat, phase: NSEvent.Phase) {
        guard vm.notchState == .closed else { return }

        if phase == .ended {
            withAnimation(animationSpring) { gestureProgress = .zero }
            return
        }

        withAnimation(animationSpring) {
            gestureProgress = (translation / Defaults[.gestureSensitivity]) * 20
        }

        if translation > Defaults[.gestureSensitivity] {
            if Defaults[.enableHaptics] {
                haptics.toggle()
            }
            withAnimation(animationSpring) {
                gestureProgress = .zero
            }
            doOpen()
        }
    }

    private func handleUpGesture(translation: CGFloat, phase: NSEvent.Phase) {
        guard vm.notchState == .open && !vm.isHoveringCalendar else { return }

        withAnimation(animationSpring) {
            gestureProgress = (translation / Defaults[.gestureSensitivity]) * -20
        }

        if phase == .ended {
            withAnimation(animationSpring) {
                gestureProgress = .zero
            }
        }

        if translation > Defaults[.gestureSensitivity] {
            withAnimation(animationSpring) {
                isHovering = false
            }
            if !SharingStateManager.shared.preventNotchClose { 
                gestureProgress = .zero
                vm.close()
            }

            if Defaults[.enableHaptics] {
                haptics.toggle()
            }
        }
    }
}

private struct CodexAppIcon: View {
    let size: CGFloat
    let isWorking: Bool
    @State private var isAnimating = false

    var body: some View {
        CodexGlyphIcon(size: size * 0.76, foreground: isWorking ? .green : .white)
            .opacity(isWorking ? 1 : 0.72)
            .scaleEffect(isWorking && isAnimating ? 1.06 : 0.94)
            .frame(width: size, height: size)
            .animation(
                isWorking
                    ? Animation.easeInOut(duration: 0.9).repeatForever(autoreverses: true)
                    : .smooth(duration: 0.18),
                value: isAnimating
            )
            .onAppear {
                isAnimating = isWorking
            }
            .onChange(of: isWorking) { _, isWorking in
                isAnimating = false
                if isWorking {
                    DispatchQueue.main.async {
                        isAnimating = true
                    }
                }
            }
    }
}

struct CodexGlyphIcon: View {
    let size: CGFloat
    let foreground: Color

    var body: some View {
        CodexAppIconShape()
            .fill(foreground, style: FillStyle(eoFill: true))
            .frame(width: size, height: size)
    }
}

struct CodexAppIconShape: Shape {
    private static let pathData = "M235.00,5.00 L234.00,6.00 L232.00,6.00 L231.00,7.00 L229.00,7.00 L228.00,8.00 L225.00,8.00 L222.00,10.00 L220.00,10.00 L219.00,11.00 L217.00,11.00 L212.00,14.00 L210.00,14.00 L209.00,15.00 L208.00,15.00 L207.00,16.00 L206.00,16.00 L205.00,17.00 L204.00,17.00 L203.00,18.00 L202.00,18.00 L201.00,19.00 L198.00,20.00 L196.00,22.00 L193.00,23.00 L191.00,25.00 L190.00,25.00 L189.00,26.00 L188.00,26.00 L186.00,28.00 L185.00,28.00 L182.00,31.00 L181.00,31.00 L178.00,34.00 L177.00,34.00 L172.00,39.00 L171.00,39.00 L155.00,55.00 L155.00,56.00 L150.00,61.00 L150.00,62.00 L147.00,65.00 L147.00,66.00 L144.00,69.00 L144.00,70.00 L142.00,72.00 L142.00,73.00 L138.00,78.00 L138.00,79.00 L137.00,80.00 L137.00,81.00 L135.00,83.00 L135.00,84.00 L134.00,85.00 L134.00,86.00 L133.00,87.00 L133.00,88.00 L132.00,89.00 L132.00,90.00 L129.00,95.00 L129.00,97.00 L126.00,102.00 L126.00,104.00 L125.00,105.00 L125.00,107.00 L124.00,108.00 L124.00,109.00 L123.00,110.00 L123.00,112.00 L122.00,113.00 L122.00,116.00 L121.00,117.00 L121.00,119.00 L119.00,121.00 L118.00,121.00 L117.00,122.00 L115.00,122.00 L114.00,123.00 L111.00,123.00 L108.00,125.00 L106.00,125.00 L105.00,126.00 L103.00,126.00 L102.00,127.00 L100.00,127.00 L97.00,129.00 L95.00,129.00 L94.00,130.00 L93.00,130.00 L92.00,131.00 L91.00,131.00 L90.00,132.00 L89.00,132.00 L88.00,133.00 L87.00,133.00 L86.00,134.00 L83.00,135.00 L81.00,137.00 L78.00,138.00 L76.00,140.00 L75.00,140.00 L73.00,142.00 L72.00,142.00 L70.00,144.00 L69.00,144.00 L66.00,147.00 L65.00,147.00 L62.00,150.00 L61.00,150.00 L57.00,154.00 L56.00,154.00 L39.00,171.00 L39.00,172.00 L31.00,181.00 L31.00,182.00 L29.00,184.00 L29.00,185.00 L27.00,187.00 L27.00,188.00 L23.00,193.00 L23.00,194.00 L22.00,195.00 L21.00,198.00 L19.00,200.00 L19.00,201.00 L18.00,202.00 L18.00,203.00 L17.00,204.00 L17.00,205.00 L14.00,210.00 L14.00,212.00 L11.00,217.00 L11.00,219.00 L9.00,222.00 L9.00,224.00 L8.00,225.00 L8.00,227.00 L7.00,228.00 L7.00,230.00 L6.00,231.00 L6.00,233.00 L5.00,234.00 L5.00,237.00 L4.00,238.00 L4.00,242.00 L3.00,243.00 L3.00,247.00 L2.00,248.00 L2.00,254.00 L1.00,255.00 L1.00,264.00 L0.00,265.00 L0.00,291.00 L1.00,292.00 L1.00,302.00 L2.00,303.00 L2.00,308.00 L3.00,309.00 L3.00,313.00 L4.00,314.00 L4.00,317.00 L5.00,318.00 L5.00,321.00 L6.00,322.00 L6.00,324.00 L7.00,325.00 L7.00,328.00 L9.00,331.00 L9.00,333.00 L10.00,334.00 L10.00,336.00 L11.00,337.00 L11.00,338.00 L12.00,339.00 L12.00,341.00 L13.00,342.00 L13.00,343.00 L16.00,348.00 L16.00,350.00 L17.00,351.00 L17.00,352.00 L19.00,354.00 L19.00,355.00 L20.00,356.00 L20.00,357.00 L21.00,358.00 L22.00,361.00 L24.00,363.00 L24.00,364.00 L26.00,366.00 L26.00,367.00 L28.00,369.00 L28.00,370.00 L30.00,372.00 L30.00,373.00 L33.00,376.00 L33.00,377.00 L36.00,380.00 L36.00,381.00 L44.00,389.00 L44.00,390.00 L47.00,393.00 L47.00,396.00 L46.00,397.00 L46.00,401.00 L45.00,402.00 L45.00,406.00 L44.00,407.00 L44.00,412.00 L43.00,413.00 L43.00,421.00 L42.00,422.00 L42.00,449.00 L43.00,450.00 L43.00,458.00 L44.00,459.00 L44.00,464.00 L45.00,465.00 L45.00,469.00 L46.00,470.00 L46.00,473.00 L47.00,474.00 L47.00,477.00 L48.00,478.00 L48.00,480.00 L49.00,481.00 L49.00,484.00 L50.00,485.00 L50.00,487.00 L52.00,490.00 L52.00,492.00 L53.00,493.00 L53.00,495.00 L55.00,498.00 L55.00,500.00 L56.00,501.00 L56.00,502.00 L59.00,507.00 L59.00,509.00 L60.00,510.00 L60.00,511.00 L61.00,512.00 L62.00,515.00 L64.00,517.00 L64.00,518.00 L66.00,520.00 L66.00,521.00 L68.00,523.00 L68.00,524.00 L71.00,527.00 L71.00,528.00 L77.00,535.00 L77.00,536.00 L81.00,540.00 L81.00,541.00 L98.00,558.00 L99.00,558.00 L108.00,566.00 L109.00,566.00 L111.00,568.00 L112.00,568.00 L114.00,570.00 L115.00,570.00 L120.00,574.00 L121.00,574.00 L122.00,575.00 L125.00,576.00 L127.00,578.00 L128.00,578.00 L129.00,579.00 L130.00,579.00 L131.00,580.00 L132.00,580.00 L137.00,583.00 L139.00,583.00 L140.00,584.00 L141.00,584.00 L142.00,585.00 L144.00,585.00 L147.00,587.00 L149.00,587.00 L150.00,588.00 L152.00,588.00 L153.00,589.00 L155.00,589.00 L156.00,590.00 L158.00,590.00 L159.00,591.00 L162.00,591.00 L163.00,592.00 L165.00,592.00 L166.00,593.00 L170.00,593.00 L171.00,594.00 L175.00,594.00 L176.00,595.00 L182.00,595.00 L183.00,596.00 L193.00,596.00 L194.00,597.00 L217.00,597.00 L218.00,596.00 L227.00,596.00 L228.00,595.00 L233.00,595.00 L234.00,594.00 L238.00,594.00 L239.00,593.00 L241.00,593.00 L242.00,592.00 L247.00,592.00 L253.00,598.00 L254.00,598.00 L259.00,603.00 L260.00,603.00 L267.00,609.00 L268.00,609.00 L270.00,611.00 L271.00,611.00 L273.00,613.00 L274.00,613.00 L279.00,617.00 L280.00,617.00 L281.00,618.00 L284.00,619.00 L286.00,621.00 L287.00,621.00 L288.00,622.00 L289.00,622.00 L294.00,625.00 L296.00,625.00 L301.00,628.00 L303.00,628.00 L306.00,630.00 L308.00,630.00 L309.00,631.00 L311.00,631.00 L312.00,632.00 L314.00,632.00 L315.00,633.00 L318.00,633.00 L319.00,634.00 L322.00,634.00 L323.00,635.00 L327.00,635.00 L328.00,636.00 L332.00,636.00 L333.00,637.00 L338.00,637.00 L339.00,638.00 L348.00,638.00 L349.00,639.00 L373.00,639.00 L374.00,638.00 L383.00,638.00 L384.00,637.00 L390.00,637.00 L391.00,636.00 L395.00,636.00 L396.00,635.00 L399.00,635.00 L400.00,634.00 L403.00,634.00 L404.00,633.00 L407.00,633.00 L408.00,632.00 L410.00,632.00 L411.00,631.00 L413.00,631.00 L414.00,630.00 L416.00,630.00 L417.00,629.00 L419.00,629.00 L422.00,627.00 L424.00,627.00 L429.00,624.00 L431.00,624.00 L432.00,623.00 L433.00,623.00 L434.00,622.00 L437.00,621.00 L439.00,619.00 L440.00,619.00 L441.00,618.00 L444.00,617.00 L446.00,615.00 L449.00,614.00 L451.00,612.00 L452.00,612.00 L454.00,610.00 L455.00,610.00 L458.00,607.00 L459.00,607.00 L463.00,603.00 L464.00,603.00 L469.00,598.00 L470.00,598.00 L481.00,587.00 L481.00,586.00 L487.00,580.00 L487.00,579.00 L491.00,575.00 L491.00,574.00 L494.00,571.00 L494.00,570.00 L496.00,568.00 L496.00,567.00 L500.00,562.00 L500.00,561.00 L501.00,560.00 L502.00,557.00 L504.00,555.00 L504.00,554.00 L505.00,553.00 L505.00,552.00 L508.00,547.00 L508.00,545.00 L511.00,540.00 L511.00,538.00 L513.00,535.00 L513.00,533.00 L514.00,532.00 L514.00,530.00 L516.00,527.00 L516.00,525.00 L517.00,524.00 L517.00,522.00 L518.00,521.00 L518.00,520.00 L520.00,518.00 L522.00,518.00 L523.00,517.00 L525.00,517.00 L526.00,516.00 L528.00,516.00 L529.00,515.00 L531.00,515.00 L532.00,514.00 L534.00,514.00 L537.00,512.00 L539.00,512.00 L544.00,509.00 L546.00,509.00 L547.00,508.00 L548.00,508.00 L549.00,507.00 L550.00,507.00 L551.00,506.00 L554.00,505.00 L556.00,503.00 L557.00,503.00 L558.00,502.00 L561.00,501.00 L563.00,499.00 L564.00,499.00 L566.00,497.00 L567.00,497.00 L569.00,495.00 L570.00,495.00 L572.00,493.00 L573.00,493.00 L576.00,490.00 L577.00,490.00 L582.00,485.00 L583.00,485.00 L600.00,468.00 L600.00,467.00 L604.00,463.00 L604.00,462.00 L610.00,455.00 L610.00,454.00 L614.00,449.00 L615.00,446.00 L617.00,444.00 L617.00,443.00 L618.00,442.00 L618.00,441.00 L619.00,440.00 L619.00,439.00 L620.00,438.00 L621.00,435.00 L623.00,433.00 L623.00,432.00 L624.00,431.00 L624.00,429.00 L625.00,428.00 L625.00,427.00 L627.00,424.00 L627.00,422.00 L629.00,419.00 L629.00,417.00 L630.00,416.00 L630.00,414.00 L631.00,413.00 L631.00,411.00 L632.00,410.00 L632.00,408.00 L633.00,407.00 L633.00,405.00 L634.00,404.00 L634.00,401.00 L635.00,400.00 L635.00,396.00 L636.00,395.00 L636.00,391.00 L637.00,390.00 L637.00,385.00 L638.00,384.00 L638.00,376.00 L639.00,375.00 L639.00,350.00 L638.00,349.00 L638.00,341.00 L637.00,340.00 L637.00,334.00 L636.00,333.00 L636.00,328.00 L635.00,327.00 L635.00,323.00 L634.00,322.00 L634.00,320.00 L633.00,319.00 L633.00,316.00 L632.00,315.00 L632.00,313.00 L631.00,312.00 L631.00,310.00 L630.00,309.00 L630.00,307.00 L629.00,306.00 L629.00,304.00 L627.00,301.00 L627.00,299.00 L626.00,298.00 L626.00,297.00 L625.00,296.00 L625.00,295.00 L624.00,294.00 L624.00,293.00 L623.00,292.00 L623.00,291.00 L622.00,290.00 L622.00,289.00 L621.00,288.00 L621.00,287.00 L620.00,286.00 L620.00,285.00 L619.00,284.00 L618.00,281.00 L616.00,279.00 L615.00,276.00 L613.00,274.00 L613.00,273.00 L611.00,271.00 L611.00,270.00 L605.00,263.00 L605.00,262.00 L601.00,258.00 L601.00,257.00 L593.00,249.00 L593.00,248.00 L592.00,247.00 L592.00,244.00 L593.00,243.00 L593.00,239.00 L594.00,238.00 L594.00,234.00 L595.00,233.00 L595.00,228.00 L596.00,227.00 L596.00,219.00 L597.00,218.00 L597.00,192.00 L596.00,191.00 L596.00,182.00 L595.00,181.00 L595.00,176.00 L594.00,175.00 L594.00,171.00 L593.00,170.00 L593.00,166.00 L592.00,165.00 L592.00,162.00 L591.00,161.00 L591.00,159.00 L590.00,158.00 L590.00,156.00 L589.00,155.00 L589.00,153.00 L588.00,152.00 L588.00,150.00 L587.00,149.00 L587.00,147.00 L585.00,144.00 L585.00,142.00 L584.00,141.00 L584.00,140.00 L583.00,139.00 L583.00,138.00 L582.00,137.00 L582.00,136.00 L581.00,135.00 L581.00,134.00 L580.00,133.00 L580.00,132.00 L579.00,131.00 L579.00,130.00 L578.00,129.00 L578.00,128.00 L577.00,127.00 L576.00,124.00 L574.00,122.00 L573.00,119.00 L571.00,117.00 L571.00,116.00 L569.00,114.00 L569.00,113.00 L567.00,111.00 L567.00,110.00 L565.00,108.00 L565.00,107.00 L561.00,103.00 L561.00,102.00 L556.00,97.00 L556.00,96.00 L543.00,83.00 L542.00,83.00 L537.00,78.00 L536.00,78.00 L529.00,72.00 L528.00,72.00 L526.00,70.00 L525.00,70.00 L520.00,66.00 L517.00,65.00 L515.00,63.00 L514.00,63.00 L513.00,62.00 L512.00,62.00 L511.00,61.00 L510.00,61.00 L509.00,60.00 L508.00,60.00 L507.00,59.00 L506.00,59.00 L505.00,58.00 L504.00,58.00 L499.00,55.00 L497.00,55.00 L496.00,54.00 L495.00,54.00 L494.00,53.00 L492.00,53.00 L489.00,51.00 L487.00,51.00 L486.00,50.00 L484.00,50.00 L483.00,49.00 L480.00,49.00 L479.00,48.00 L477.00,48.00 L476.00,47.00 L473.00,47.00 L472.00,46.00 L468.00,46.00 L467.00,45.00 L463.00,45.00 L462.00,44.00 L457.00,44.00 L456.00,43.00 L447.00,43.00 L446.00,42.00 L425.00,42.00 L424.00,43.00 L414.00,43.00 L413.00,44.00 L408.00,44.00 L407.00,45.00 L402.00,45.00 L401.00,46.00 L398.00,46.00 L397.00,47.00 L392.00,47.00 L387.00,42.00 L386.00,42.00 L381.00,37.00 L380.00,37.00 L376.00,33.00 L375.00,33.00 L372.00,30.00 L371.00,30.00 L369.00,28.00 L368.00,28.00 L363.00,24.00 L360.00,23.00 L358.00,21.00 L357.00,21.00 L356.00,20.00 L355.00,20.00 L354.00,19.00 L353.00,19.00 L352.00,18.00 L351.00,18.00 L350.00,17.00 L349.00,17.00 L348.00,16.00 L347.00,16.00 L346.00,15.00 L345.00,15.00 L340.00,12.00 L338.00,12.00 L335.00,10.00 L333.00,10.00 L332.00,9.00 L330.00,9.00 L329.00,8.00 L327.00,8.00 L326.00,7.00 L324.00,7.00 L323.00,6.00 L320.00,6.00 L319.00,5.00 L316.00,5.00 L315.00,4.00 L312.00,4.00 L311.00,3.00 L306.00,3.00 L305.00,2.00 L300.00,2.00 L299.00,1.00 L291.00,1.00 L290.00,0.00 L264.00,0.00 L263.00,1.00 L255.00,1.00 L254.00,2.00 L249.00,2.00 L248.00,3.00 L244.00,3.00 L243.00,4.00 L239.00,4.00 L238.00,5.00 ZM317.00,407.00 L318.00,406.00 L318.00,403.00 L319.00,402.00 L319.00,400.00 L321.00,398.00 L321.00,397.00 L327.00,391.00 L328.00,391.00 L330.00,389.00 L331.00,389.00 L332.00,388.00 L335.00,388.00 L336.00,387.00 L472.00,387.00 L473.00,388.00 L475.00,388.00 L476.00,389.00 L479.00,390.00 L482.00,393.00 L483.00,393.00 L484.00,394.00 L484.00,395.00 L487.00,398.00 L487.00,399.00 L489.00,402.00 L489.00,404.00 L490.00,405.00 L490.00,415.00 L489.00,416.00 L489.00,418.00 L488.00,419.00 L487.00,422.00 L485.00,424.00 L485.00,425.00 L483.00,427.00 L482.00,427.00 L479.00,430.00 L478.00,430.00 L475.00,432.00 L473.00,432.00 L472.00,433.00 L335.00,433.00 L334.00,432.00 L332.00,432.00 L331.00,431.00 L328.00,430.00 L321.00,423.00 L321.00,422.00 L319.00,420.00 L319.00,418.00 L318.00,417.00 L318.00,414.00 L317.00,413.00 ZM171.00,209.00 L178.00,209.00 L179.00,210.00 L181.00,210.00 L182.00,211.00 L184.00,211.00 L186.00,213.00 L187.00,213.00 L194.00,220.00 L194.00,221.00 L195.00,222.00 L196.00,225.00 L198.00,227.00 L198.00,228.00 L199.00,229.00 L200.00,232.00 L202.00,234.00 L202.00,235.00 L203.00,236.00 L204.00,239.00 L206.00,241.00 L206.00,242.00 L207.00,243.00 L208.00,246.00 L210.00,248.00 L210.00,249.00 L211.00,250.00 L212.00,253.00 L214.00,255.00 L214.00,256.00 L215.00,257.00 L216.00,260.00 L218.00,262.00 L218.00,263.00 L219.00,264.00 L220.00,267.00 L222.00,269.00 L222.00,270.00 L223.00,271.00 L224.00,274.00 L226.00,276.00 L226.00,277.00 L227.00,278.00 L228.00,281.00 L230.00,283.00 L230.00,284.00 L231.00,285.00 L232.00,288.00 L234.00,290.00 L234.00,291.00 L235.00,292.00 L236.00,295.00 L238.00,297.00 L238.00,298.00 L239.00,299.00 L240.00,302.00 L242.00,304.00 L242.00,305.00 L243.00,306.00 L244.00,309.00 L246.00,311.00 L246.00,312.00 L247.00,313.00 L247.00,315.00 L248.00,316.00 L248.00,318.00 L249.00,319.00 L249.00,326.00 L248.00,327.00 L248.00,330.00 L247.00,331.00 L247.00,332.00 L246.00,333.00 L246.00,334.00 L245.00,335.00 L244.00,338.00 L242.00,340.00 L241.00,343.00 L239.00,345.00 L238.00,348.00 L236.00,350.00 L235.00,353.00 L233.00,355.00 L232.00,358.00 L230.00,360.00 L229.00,363.00 L227.00,365.00 L227.00,366.00 L226.00,367.00 L225.00,370.00 L223.00,372.00 L222.00,375.00 L220.00,377.00 L219.00,380.00 L217.00,382.00 L216.00,385.00 L214.00,387.00 L213.00,390.00 L211.00,392.00 L211.00,393.00 L210.00,394.00 L209.00,397.00 L207.00,399.00 L206.00,402.00 L204.00,404.00 L203.00,407.00 L201.00,409.00 L200.00,412.00 L198.00,414.00 L198.00,415.00 L197.00,416.00 L197.00,417.00 L195.00,419.00 L194.00,422.00 L187.00,429.00 L186.00,429.00 L183.00,431.00 L181.00,431.00 L180.00,432.00 L169.00,432.00 L168.00,431.00 L166.00,431.00 L165.00,430.00 L164.00,430.00 L162.00,428.00 L161.00,428.00 L155.00,422.00 L155.00,421.00 L152.00,416.00 L152.00,412.00 L151.00,411.00 L151.00,408.00 L152.00,407.00 L152.00,403.00 L153.00,402.00 L153.00,400.00 L154.00,399.00 L154.00,398.00 L156.00,396.00 L156.00,395.00 L157.00,394.00 L157.00,393.00 L159.00,391.00 L159.00,390.00 L160.00,389.00 L161.00,386.00 L163.00,384.00 L164.00,381.00 L166.00,379.00 L167.00,376.00 L169.00,374.00 L170.00,371.00 L172.00,369.00 L173.00,366.00 L175.00,364.00 L175.00,363.00 L176.00,362.00 L177.00,359.00 L179.00,357.00 L180.00,354.00 L182.00,352.00 L183.00,349.00 L185.00,347.00 L186.00,344.00 L188.00,342.00 L188.00,341.00 L189.00,340.00 L189.00,339.00 L191.00,337.00 L191.00,336.00 L192.00,335.00 L193.00,332.00 L195.00,330.00 L196.00,327.00 L198.00,325.00 L198.00,324.00 L199.00,323.00 L199.00,322.00 L198.00,321.00 L197.00,318.00 L195.00,316.00 L195.00,315.00 L194.00,314.00 L193.00,311.00 L191.00,309.00 L191.00,308.00 L190.00,307.00 L189.00,304.00 L187.00,302.00 L187.00,301.00 L186.00,300.00 L185.00,297.00 L183.00,295.00 L183.00,294.00 L182.00,293.00 L181.00,290.00 L179.00,288.00 L179.00,287.00 L178.00,286.00 L177.00,283.00 L175.00,281.00 L175.00,280.00 L174.00,279.00 L173.00,276.00 L171.00,274.00 L171.00,273.00 L170.00,272.00 L169.00,269.00 L167.00,267.00 L167.00,266.00 L166.00,265.00 L165.00,262.00 L163.00,260.00 L163.00,259.00 L162.00,258.00 L161.00,255.00 L159.00,253.00 L159.00,252.00 L158.00,251.00 L157.00,248.00 L155.00,246.00 L155.00,245.00 L152.00,240.00 L152.00,238.00 L151.00,237.00 L151.00,228.00 L152.00,227.00 L152.00,225.00 L153.00,224.00 L153.00,222.00 L155.00,220.00 L155.00,219.00 L161.00,213.00 L162.00,213.00 L167.00,210.00 L170.00,210.00 Z"

    private static let logoPath: CGPath = {
        var tokens: [String] = []
        var tokBuf = ""
        for ch in pathData {
            if ch.isLetter {
                if !tokBuf.isEmpty { tokens.append(tokBuf); tokBuf = "" }
                tokens.append(String(ch))
            } else if ch.isWhitespace || ch == "," {
                if !tokBuf.isEmpty { tokens.append(tokBuf); tokBuf = "" }
            } else {
                tokBuf.append(ch)
            }
        }
        if !tokBuf.isEmpty { tokens.append(tokBuf) }

        let path = CGMutablePath()
        var i = 0
        var current = CGPoint.zero
        var start = CGPoint.zero

        while i < tokens.count {
            switch tokens[i] {
            case "M":
                if i + 2 < tokens.count,
                   let x = Double(tokens[i + 1]),
                   let y = Double(tokens[i + 2])
                {
                    let pt = CGPoint(x: x, y: y)
                    path.move(to: pt)
                    current = pt
                    start = pt
                    i += 3
                } else {
                    i += 1
                }
            case "L":
                if i + 2 < tokens.count,
                   let x = Double(tokens[i + 1]),
                   let y = Double(tokens[i + 2])
                {
                    let pt = CGPoint(x: x, y: y)
                    path.addLine(to: pt)
                    current = pt
                    i += 3
                } else {
                    i += 1
                }
            case "Z", "z":
                path.closeSubpath()
                current = start
                i += 1
            default:
                i += 1
            }
        }
        return path
    }()

    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / 640
        var transform = CGAffineTransform(
            translationX: rect.midX - 320 * scale,
            y: rect.midY - 320 * scale
        ).scaledBy(x: scale, y: scale)

        guard let scaled = Self.logoPath.copy(using: &transform) else {
            return Path()
        }
        return Path(scaled)
    }
}

private struct CodexClosedSessionCountBadge: View {
    let count: Int
    let width: CGFloat

    var body: some View {
        Text("\(count)")
            .font(.system(size: 11, weight: .bold, design: .monospaced))
            .foregroundStyle(Color.green)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(width: width, height: width)
            .background(
                Circle()
                    .fill(Color.green.opacity(0.12))
            )
            .overlay(
                Circle()
                    .stroke(Color.green.opacity(0.22), lineWidth: 1)
            )
    }
}

private struct ClaudeAppIcon: View {
    let size: CGFloat
    let isWorking: Bool
    @State private var isAnimating = false

    var body: some View {
        ClaudeGlyphIcon(size: size * 0.76, foreground: isWorking ? .orange : .white)
            .opacity(isWorking ? 1 : 0.72)
            .scaleEffect(isWorking && isAnimating ? 1.06 : 0.94)
            .frame(width: size, height: size)
            .animation(
                isWorking
                    ? Animation.easeInOut(duration: 0.9).repeatForever(autoreverses: true)
                    : .smooth(duration: 0.18),
                value: isAnimating
            )
            .onAppear {
                isAnimating = isWorking
            }
            .onChange(of: isWorking) { _, isWorking in
                isAnimating = false
                if isWorking {
                    DispatchQueue.main.async {
                        isAnimating = true
                    }
                }
            }
    }
}

struct ClaudeGlyphIcon: View {
    let size: CGFloat
    let foreground: Color

    var body: some View {
        ClaudeAppIconShape()
            .fill(foreground)
            .frame(width: size, height: size)
    }
}

struct ClaudeAppIconShape: Shape {
    private static let pathData = "M 75 30 L 73 31 L 69 36 L 70 46 L 75 53 L 84 70 L 86 72 L 95 90 L 93 91 L 53 61 L 47 61 L 43 65 L 44 72 L 59 84 L 93 106 L 96 110 L 95 111 L 90 111 L 89 110 L 80 110 L 79 109 L 66 109 L 65 108 L 51 108 L 50 107 L 37 107 L 34 106 L 31 108 L 31 111 L 36 115 L 47 115 L 48 116 L 72 116 L 73 117 L 94 117 L 96 119 L 94 122 L 62 139 L 56 144 L 48 149 L 48 154 L 51 157 L 52 156 L 58 156 L 100 128 L 103 129 L 95 138 L 86 151 L 67 175 L 67 179 L 71 181 L 74 180 L 74 179 L 86 167 L 91 159 L 111 133 L 112 134 L 112 137 L 111 138 L 109 155 L 108 156 L 108 160 L 106 165 L 106 169 L 105 170 L 105 174 L 104 175 L 104 179 L 102 185 L 104 190 L 108 193 L 114 190 L 114 186 L 115 185 L 115 175 L 116 174 L 116 164 L 117 163 L 117 153 L 118 152 L 118 143 L 120 138 L 124 143 L 131 156 L 148 180 L 154 180 L 156 179 L 157 177 L 156 176 L 156 170 L 137 142 L 138 139 L 160 158 L 172 167 L 175 167 L 176 165 L 175 161 L 137 126 L 138 124 L 141 124 L 142 125 L 145 125 L 154 128 L 158 128 L 159 129 L 162 129 L 163 130 L 166 130 L 175 133 L 179 133 L 184 135 L 186 135 L 193 131 L 193 127 L 186 121 L 166 120 L 165 119 L 142 119 L 138 117 L 141 115 L 145 115 L 146 114 L 149 114 L 150 113 L 153 113 L 162 110 L 166 110 L 167 109 L 171 109 L 172 108 L 176 108 L 181 106 L 189 105 L 191 104 L 193 100 L 193 98 L 189 95 L 183 95 L 182 96 L 177 96 L 176 97 L 171 97 L 170 98 L 156 100 L 155 101 L 147 102 L 146 103 L 143 103 L 142 102 L 147 92 L 170 63 L 170 60 L 172 56 L 167 48 L 161 48 L 159 49 L 144 65 L 130 84 L 125 88 L 124 87 L 124 83 L 125 82 L 125 78 L 126 77 L 126 73 L 128 67 L 128 62 L 130 56 L 130 51 L 131 50 L 131 45 L 132 44 L 132 37 L 126 32 L 121 36 L 119 41 L 118 58 L 117 59 L 117 68 L 116 69 L 116 77 L 115 78 L 115 90 L 113 93 L 111 91 L 110 85 L 95 57 L 95 55 L 90 46 L 90 44 L 86 37 L 85 33 L 83 31 L 80 31 L 79 30 Z"

    private static let logoPath: CGPath = {
        var tokens: [String] = []
        var tokBuf = ""
        for ch in pathData {
            if ch.isLetter {
                if !tokBuf.isEmpty { tokens.append(tokBuf); tokBuf = "" }
                tokens.append(String(ch))
            } else if ch.isWhitespace || ch == "," {
                if !tokBuf.isEmpty { tokens.append(tokBuf); tokBuf = "" }
            } else {
                tokBuf.append(ch)
            }
        }
        if !tokBuf.isEmpty { tokens.append(tokBuf) }

        let path = CGMutablePath()
        var i = 0
        var current = CGPoint.zero
        var start = CGPoint.zero

        while i < tokens.count {
            switch tokens[i] {
            case "M":
                if i + 2 < tokens.count,
                   let x = Double(tokens[i + 1]),
                   let y = Double(tokens[i + 2])
                {
                    let pt = CGPoint(x: x, y: y)
                    path.move(to: pt)
                    current = pt
                    start = pt
                    i += 3
                } else {
                    i += 1
                }
            case "L":
                if i + 2 < tokens.count,
                   let x = Double(tokens[i + 1]),
                   let y = Double(tokens[i + 2])
                {
                    let pt = CGPoint(x: x, y: y)
                    path.addLine(to: pt)
                    current = pt
                    i += 3
                } else {
                    i += 1
                }
            case "Z", "z":
                path.closeSubpath()
                current = start
                i += 1
            default:
                i += 1
            }
        }
        return path
    }()

    func path(in rect: CGRect) -> Path {
        // SVG viewBox is 225x224 but actual path content is ~162x163 (X:31→193, Y:30→193)
        let contentWidth: CGFloat = 162
        let contentHeight: CGFloat = 163
        let scale = min(rect.width / contentWidth, rect.height / contentHeight)
        let contentCenterX: CGFloat = 112 // (31 + 193) / 2
        let contentCenterY: CGFloat = 111.5 // (30 + 193) / 2

        var transform = CGAffineTransform(
            translationX: rect.midX - contentCenterX * scale,
            y: rect.midY - contentCenterY * scale
        ).scaledBy(x: scale, y: scale)

        guard let scaled = Self.logoPath.copy(using: &transform) else {
            return Path()
        }
        return Path(scaled)
    }
}

private struct ClaudeClosedSessionCountBadge: View {
    let count: Int
    let width: CGFloat

    var body: some View {
        Text("\(count)")
            .font(.system(size: 11, weight: .bold, design: .monospaced))
            .foregroundStyle(Color.orange)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(width: width, height: width)
            .background(
                Circle()
                    .fill(Color.orange.opacity(0.12))
            )
            .overlay(
                Circle()
                    .stroke(Color.orange.opacity(0.22), lineWidth: 1)
            )
    }
}

struct FullScreenDropDelegate: DropDelegate {
    @Binding var isTargeted: Bool
    let onDrop: () -> Void

    func dropEntered(info _: DropInfo) {
        isTargeted = true
    }

    func dropExited(info _: DropInfo) {
        isTargeted = false
    }

    func performDrop(info _: DropInfo) -> Bool {
        isTargeted = false
        onDrop()
        return true
    }

}

struct GeneralDropTargetDelegate: DropDelegate {
    @Binding var isTargeted: Bool

    func dropEntered(info: DropInfo) {
        isTargeted = true
    }

    func dropExited(info: DropInfo) {
        isTargeted = false
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        return DropProposal(operation: .cancel)
    }

    func performDrop(info: DropInfo) -> Bool {
        return false
    }
}

#Preview {
    let vm = BoringViewModel()
    vm.open()
    return ContentView()
        .environmentObject(vm)
        .frame(width: vm.notchSize.width, height: vm.notchSize.height)
}
