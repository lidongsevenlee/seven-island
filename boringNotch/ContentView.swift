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
import OSLog
import SwiftUI
import SwiftUIIntrospect

@MainActor
struct ContentView: View {
    @EnvironmentObject var vm: BoringViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var webcamManager = WebcamManager.shared

    @ObservedObject var coordinator = BoringViewCoordinator.shared
    @ObservedObject var musicManager = MusicManager.shared
    @ObservedObject var batteryModel = BatteryStatusViewModel.shared
    @ObservedObject var brightnessManager = BrightnessManager.shared
    @ObservedObject var volumeManager = VolumeManager.shared
    @State private var spectrumClient = UUID()

    @State private var haptics: Bool = false

    private let openPanelBottomInset: CGFloat = 12
    private let todoContentSpacing: CGFloat = 8
    private struct MusicDiagnosticPresentation: Equatable {
        let expansionCycle: Int
        let tabSelectionCycle: Int
        let firstLaunch: Bool
    }

    private var musicDiagnosticPresentation: MusicDiagnosticPresentation? {
        guard vm.notchState == .open, coordinator.currentView == .music else { return nil }
        return MusicDiagnosticPresentation(
            expansionCycle: vm.expansionCycle, tabSelectionCycle: coordinator.tabSelectionCycle,
            firstLaunch: coordinator.firstLaunch
        )
    }

    private var openHeaderHeight: CGFloat { max(24, vm.effectiveClosedNotchHeight) }
    private var hiddenNotchBottomInset: CGFloat { vm.effectiveClosedNotchHeight == 0 ? 10 : 0 }
    private var compactTodoContentHeight: CGFloat {
        openNotchSize.height - openHeaderHeight - todoContentSpacing - openPanelBottomInset - hiddenNotchBottomInset
    }

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

    private var shouldShowMusicLiveActivity: Bool {
        (!coordinator.expandingView.show || coordinator.expandingView.type == .music)
            && vm.notchState == .closed
            && (musicManager.isPlaying || !musicManager.isPlayerIdle)
            && coordinator.musicLiveActivityEnabled
            && !vm.hideOnClosed
    }

    private var shouldShowInlineHUD: Bool {
        vm.notchState == .closed
            && coordinator.sneakPeek.show
            && Defaults[.inlineHUD]
            && coordinator.sneakPeek.type != .music
            && coordinator.sneakPeek.type != .battery
    }

    private var musicSpectrumSource: String? {
        guard musicManager.isPlaying, !reduceMotion else { return nil }
        let showsMusic = vm.notchState == .open && coordinator.currentView == .music && !coordinator.firstLaunch
        let showsCompactSpectrum = shouldShowMusicLiveActivity && useMusicVisualizer
            && !shouldShowInlineHUD && !coordinator.helloAnimationRunning
            && vm.effectiveClosedNotchHeight > 12
        return showsMusic || showsCompactSpectrum ? musicManager.bundleIdentifier : nil
    }

    var body: some View {
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
                    .padding(.horizontal, vm.notchState == .open ? 12 : 0)
                    .padding(.bottom, vm.notchState == .open ? openPanelBottomInset : 0)
                    .background(.black)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height.rounded() } action: { height in
                        vm.measuredPanelHeight = height
                    }
                    .clipShape(currentNotchShape)
                    .overlay(alignment: .top) {
                        Rectangle()
                            .fill(.black)
                            .frame(height: 1)
                            .padding(.horizontal, topCornerRadius)
                    }
                    .shadow(
                        color: ((vm.notchState == .open || vm.isHovering) && Defaults[.enableShadow])
                            ? .black.opacity(0.7) : .clear, radius: Defaults[.cornerRadiusScaling] ? 6 : 4
                    )
                    .padding(.bottom, hiddenNotchBottomInset)
                
                mainLayout
                    .frame(height: vm.notchState == .open ? vm.notchSize.height : nil, alignment: .top)
                    .conditionalModifier(true) { view in
                        let openAnimation = Animation.spring(response: 0.42, dampingFraction: 0.8, blendDuration: 0)
                        let closeAnimation = Animation.spring(response: 0.45, dampingFraction: 1.0, blendDuration: 0)

                        return view
                            .animation(animationSpring, value: vm.isHovering)
                            .animation(vm.notchState == .open ? openAnimation : closeAnimation, value: vm.notchState)
                    }
                    .contentShape(Rectangle())
                    .onHover { hovering in
                        handleHover(hovering)
                    }
                    .gesture(
                        TapGesture()
                            .onEnded { _ in
                                guard vm.notchState == .closed else { return }
                                doOpen()
                            }
                    )
                    .onChange(of: vm.notchState) { _, newState in
                        if newState == .open && coordinator.currentView != .todo {
                            withAnimation(.smooth(duration: 0.35)) {
                                vm.setOpenNotchHeight(openNotchSize.height)
                            }
                        }
                    }
                    .onChange(of: coordinator.currentView) { _, view in
                        if view != .music {
                            vm.measuredMusicContentHeight = nil
                        }
                        guard view != .todo else { return }
                        withAnimation(.smooth(duration: 0.35)) {
                            vm.setOpenNotchHeight(openNotchSize.height)
                        }
                    }
                    .sensoryFeedback(.alignment, trigger: haptics)
                    .contextMenu {
                        Button("设置") {
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
        .preferredColorScheme(.dark)
        .environmentObject(vm)
        .onChange(of: musicSpectrumSource, initial: true) { _, source in
            MusicAudioSpectrum.shared.setSource(source, for: spectrumClient)
        }
        .task(id: musicDiagnosticPresentation) {
            guard let presentation = musicDiagnosticPresentation else { return }
            try? await Task.sleep(for: .milliseconds(650))
            guard !Task.isCancelled, musicDiagnosticPresentation == presentation else { return }
            logMusicLayout()
        }
        .onDisappear {
            vm.cancelPanelTimers()
            MusicAudioSpectrum.shared.setSource(nil, for: spectrumClient)
        }
    }

    private func logMusicLayout() {
        let panelHeight = vm.measuredPanelHeight.map { String(describing: $0) } ?? "unmeasured"
        let contentHeight = vm.measuredMusicContentHeight.map { String(describing: $0) } ?? "unmeasured"
        let source = Defaults[.mediaController].rawValue
        let hasTitle = !musicManager.songTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        NotchDiagnostics.logger.notice("""
            panel=\(self.vm.diagnosticID, privacy: .public) event=music_layout cycle=\(self.vm.expansionCycle) \
            target_height_pt=\(Double(self.vm.notchSize.height)) visible_height_pt=\(panelHeight, privacy: .public) \
            content_height_pt=\(contentHeight, privacy: .public) first_launch=\(self.coordinator.firstLaunch) \
            welcome_animation=\(self.coordinator.helloAnimationRunning) source="\(source, privacy: .public)" \
            playing=\(self.musicManager.isPlaying) title_available=\(hasTitle) \
            system_playback_unavailable=\(self.musicManager.isSystemPlaybackUnavailable)
            """)
    }

    @ViewBuilder
    func NotchLayout() -> some View {
        VStack(alignment: .leading, spacing: vm.notchState == .open && coordinator.currentView == .todo ? todoContentSpacing : nil) {
            VStack(alignment: .leading) {
                if coordinator.helloAnimationRunning {
                    Spacer()
                    HelloAnimation(onFinish: {
                        vm.closeHello()
                    }).frame(
                        width: vm.closedNotchSize.width,
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
                      } else if shouldShowInlineHUD {
                          InlineHUD(type: $coordinator.sneakPeek.type, value: $coordinator.sneakPeek.value, icon: $coordinator.sneakPeek.icon)
                              .transition(.opacity)
                      } else if shouldShowMusicLiveActivity {
                          MusicLiveActivity()
                              .frame(alignment: .center)
                      } else if !coordinator.expandingView.show && vm.notchState == .closed && (!musicManager.isPlaying && musicManager.isPlayerIdle) && Defaults[.showNotHumanFace] && !vm.hideOnClosed  {
                          BoringFaceAnimation()
                       } else if vm.notchState == .open {
                           BoringHeader()
                               .frame(height: openHeaderHeight)
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
                    case .music:
                        MusicHomeView(albumArtNamespace: albumArtNamespace)
                            .onGeometryChange(for: CGFloat.self) { $0.size.height.rounded() } action: { height in
                                if vm.notchState == .open && coordinator.currentView == .music {
                                    vm.measuredMusicContentHeight = height
                                }
                            }
                    case .clipboard:
                        ClipboardHistoryView()
                    case .vscodeProjects:
                        ProjectsView()
                    case .appLauncher:
                        AppLauncherView()
                    case .memo:
                        MemoView()
                    case .todo:
                        let presentation = TodoView.Presentation(
                            expansionCycle: vm.expansionCycle, tabSelectionCycle: coordinator.tabSelectionCycle
                        )
                        TodoView(
                            compactContentHeight: compactTodoContentHeight, presentation: presentation,
                            scope: $coordinator.todoListScope, calendarWeek: $coordinator.todoCalendarWeek
                        )
                        .id(presentation)
                    case .toolbox:
                        ToolboxView()
                    }
                }
                .padding(.horizontal, coordinator.currentView == .music ? 0 : sevenIslandContentInset)
                // .id() makes SwiftUI treat each tab as a distinct view identity,
                // so insert/remove fires on every tab switch and triggers the transition.
                // Without this the VStack is never removed — only its content changes
                // in-place — so .transition() is never invoked.
                .id(coordinator.currentView)
                .transition(
                    .scale(scale: 0.8, anchor: .top)
                    .combined(with: .opacity)
                    .animation(.smooth(duration: 0.35))
                )
                .zIndex(1)
                .allowsHitTesting(vm.notchState == .open)
            }
        }
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
                            CompactMusicSpectrum(isPlaying: musicManager.isPlaying)
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

    private func doOpen() {
        withAnimation(animationSpring) {
            vm.open()
        }
    }

    // MARK: - Hover Management

    private func handleHover(_ hovering: Bool) {
        guard !coordinator.firstLaunch else { return }
        if hovering && vm.notchState == .closed && Defaults[.enableHaptics] {
            haptics.toggle()
        }
        vm.hoverChanged(hovering)
    }

}
