//
//  NotchHomeView.swift
//  boringNotch
//
//  Created by Hugo Persson on 2024-08-18.
//  Modified by Harsh Vardhan Goswami & Richard Kunkli & Mustafa Ramadan
//

import Combine
import Defaults
import SwiftUI

// MARK: - Music Player Components

struct AlbumArtSizePreferenceKey: PreferenceKey {
    static var defaultValue: CGSize = .zero

    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let next = nextValue()
        value = CGSize(width: max(value.width, next.width), height: max(value.height, next.height))
    }
}

struct MusicPlayerView: View {
    @EnvironmentObject var vm: BoringViewModel
    let albumArtNamespace: Namespace.ID

    var body: some View {
        HStack {
            AlbumArtView(vm: vm, albumArtNamespace: albumArtNamespace)
                .padding(.all, 5)
                .background {
                    GeometryReader { geometry in
                        Color.clear.preference(key: AlbumArtSizePreferenceKey.self, value: geometry.size)
                    }
                }
            MusicControlsView().drawingGroup().compositingGroup()
        }
    }
}

struct AlbumArtView: View {
    @ObservedObject var musicManager = MusicManager.shared
    @ObservedObject var vm: BoringViewModel
    let albumArtNamespace: Namespace.ID

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if Defaults[.lightingEffect] {
                albumArtBackground
            }
            albumArtButton
        }
    }

    private var albumArtBackground: some View {
        Image(nsImage: musicManager.albumArt)
            .resizable()
            .clipped()
            .clipShape(
                RoundedRectangle(
                    cornerRadius: Defaults[.cornerRadiusScaling]
                        ? MusicPlayerImageSizes.cornerRadiusInset.opened
                        : MusicPlayerImageSizes.cornerRadiusInset.closed)
            )
            .aspectRatio(1, contentMode: .fit)
            .scaleEffect(x: 1.3, y: 1.4)
            .rotationEffect(.degrees(92))
            .blur(radius: 40)
            .opacity(musicManager.isPlaying ? 0.5 : 0)
    }

    private var albumArtButton: some View {
        ZStack {
            Button {
                musicManager.openMusicApp()
            } label: {
                ZStack(alignment:.bottomTrailing) {
                    albumArtImage
                    appIconOverlay
                }
            }
            .buttonStyle(PlainButtonStyle())
            .scaleEffect(musicManager.isPlaying ? 1 : 0.85)
            
            albumArtDarkOverlay
        }
    }

    private var albumArtDarkOverlay: some View {
        Rectangle()
            .aspectRatio(1, contentMode: .fit)
            .foregroundColor(Color.black)
            .opacity(musicManager.isPlaying ? 0 : 0.8)
            .blur(radius: 50)
    }
                

    private var albumArtImage: some View {
        Image(nsImage: musicManager.albumArt)
            .resizable()
            .aspectRatio(1, contentMode: .fit)
            .matchedGeometryEffect(id: "albumArt", in: albumArtNamespace)
            .clipped()
            .clipShape(
                RoundedRectangle(
                    cornerRadius: Defaults[.cornerRadiusScaling]
                        ? MusicPlayerImageSizes.cornerRadiusInset.opened
                        : MusicPlayerImageSizes.cornerRadiusInset.closed)
            )
    }

    @ViewBuilder
    private var appIconOverlay: some View {
        if vm.notchState == .open && !musicManager.usingAppIconForArtwork {
            AppIcon(for: musicManager.bundleIdentifier ?? "com.apple.Music")
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 30, height: 30)
                .offset(x: 10, y: 10)
                .transition(.scale.combined(with: .opacity))
                .zIndex(2)
        }
    }
}

struct MusicControlsView: View {
    @ObservedObject var musicManager = MusicManager.shared
        @EnvironmentObject var vm: BoringViewModel
        @ObservedObject var webcamManager = WebcamManager.shared
    @State private var sliderValue: Double = 0
    @State private var dragging: Bool = false
    @State private var lastDragged: Date = .distantPast
    @Default(.musicControlSlots) private var slotConfig
    @Default(.musicControlSlotLimit) private var slotLimit

    var body: some View {
        VStack(alignment: .leading) {
            songInfoAndSlider
            slotToolbar
        }
        .buttonStyle(PlainButtonStyle())
    }

    private var songInfoAndSlider: some View {
        GeometryReader { geo in
            VStack(alignment: .leading, spacing: 4) {
                songInfo(width: geo.size.width)
                musicSlider
            }
        }
        .padding(.top, 10)
        .padding(.leading, 5)
    }

    private func songInfo(width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            MarqueeText(
                $musicManager.songTitle, font: .headline, nsFont: .headline, textColor: .white,
                frameWidth: width)
            MarqueeText(
                $musicManager.artistName,
                font: .headline,
                nsFont: .headline,
                textColor: Defaults[.playerColorTinting]
                    ? Color(nsColor: musicManager.avgColor)
                        .ensureMinimumBrightness(factor: 0.6) : .gray,
                frameWidth: width
            )
            .fontWeight(.medium)
        }
    }

    private var musicSlider: some View {
        TimelineView(.animation(minimumInterval: musicManager.playbackRate > 0 ? 0.1 : nil)) { timeline in
            MusicSliderView(
                sliderValue: $sliderValue,
                duration: $musicManager.songDuration,
                lastDragged: $lastDragged,
                color: musicManager.avgColor,
                dragging: $dragging,
                currentDate: timeline.date,
                timestampDate: musicManager.timestampDate,
                elapsedTime: musicManager.elapsedTime,
                playbackRate: musicManager.playbackRate,
                isPlaying: musicManager.isPlaying
            ) { newValue in
                MusicManager.shared.seek(to: newValue)
            }
            .padding(.top, 5)
            .frame(height: 36)
        }
    }

    private var slotToolbar: some View {
        let slots = activeSlots
        return HStack(spacing: 6) {
            ForEach(Array(slots.enumerated()), id: \.offset) { index, slot in
                slotView(for: slot)
                    .frame(alignment: .center)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private var activeSlots: [MusicControlButton] {
        let sanitizedLimit = min(
            max(slotLimit, MusicControlButton.minSlotCount),
            MusicControlButton.maxSlotCount
        )
        let padded = slotConfig.padded(to: sanitizedLimit, filler: .none)
        let result = Array(padded.prefix(sanitizedLimit))
        // If calendar and camera are both visible alongside music, hide the edge slots
        let shouldHideEdges = Defaults[.showCalendar] && Defaults[.showMirror] && webcamManager.cameraAvailable && vm.isCameraExpanded
        if shouldHideEdges && result.count >= 5 {
            return Array(result.dropFirst().dropLast())
        }

        return result
    }

    @ViewBuilder
    private func slotView(for slot: MusicControlButton) -> some View {
        switch slot {
        case .shuffle:
            HoverButton(icon: "shuffle", iconColor: musicManager.isShuffled ? .red : .primary, scale: .medium) {
                MusicManager.shared.toggleShuffle()
            }
        case .previous:
            HoverButton(icon: "backward.fill", scale: .medium) {
                MusicManager.shared.previousTrack()
            }
        case .playPause:
            HoverButton(icon: musicManager.isPlaying ? "pause.fill" : "play.fill", scale: .large) {
                MusicManager.shared.togglePlay()
            }
        case .next:
            HoverButton(icon: "forward.fill", scale: .medium) {
                MusicManager.shared.nextTrack()
            }
        case .repeatMode:
            HoverButton(icon: repeatIcon, iconColor: repeatIconColor, scale: .medium) {
                MusicManager.shared.toggleRepeat()
            }
        case .volume:
            VolumeControlView()
        case .favorite:
            FavoriteControlButton()
        case .goBackward:
            HoverButton(icon: "gobackward.15", scale: .medium) {
                MusicManager.shared.skip(seconds: -15)
            }
        case .goForward:
            HoverButton(icon: "goforward.15", scale: .medium) {
                MusicManager.shared.skip(seconds: 15)
            }
        case .none:
            Color.clear.frame(height: 1)
        }
    }

    private var repeatIcon: String {
        switch musicManager.repeatMode {
        case .off:
            return "repeat"
        case .all:
            return "repeat"
        case .one:
            return "repeat.1"
        }
    }

    private var repeatIconColor: Color {
        switch musicManager.repeatMode {
        case .off:
            return .primary
        case .all, .one:
            return .red
        }
    }
}

struct FavoriteControlButton: View {
    @ObservedObject var musicManager = MusicManager.shared

    var body: some View {
        HoverButton(icon: iconName, iconColor: iconColor, scale: .medium) {
            MusicManager.shared.toggleFavoriteTrack()
        }
        .disabled(!musicManager.canFavoriteTrack)
        .opacity(musicManager.canFavoriteTrack ? 1 : 0.35)
    }

    private var iconName: String {
        musicManager.isFavoriteTrack ? "heart.fill" : "heart"
    }

    private var iconColor: Color {
        musicManager.isFavoriteTrack ? .red : .primary
    }
}

private extension Array where Element == MusicControlButton {
    func padded(to length: Int, filler: MusicControlButton) -> [MusicControlButton] {
        if count >= length { return self }
        return self + Array(repeating: filler, count: length - count)
    }
}

// MARK: - Volume Control View

struct VolumeControlView: View {
    @ObservedObject var musicManager = MusicManager.shared
    @State private var volumeSliderValue: Double = 0.5
    @State private var dragging: Bool = false
    @State private var showVolumeSlider: Bool = false
    @State private var lastVolumeUpdateTime: Date = Date.distantPast
    private let volumeUpdateThrottle: TimeInterval = 0.1
    
    var body: some View {
        HStack(spacing: 4) {
            Button(action: {
                if musicManager.volumeControlSupported {
                    withAnimation(.easeInOut(duration: 0.12)) {
                        showVolumeSlider.toggle()
                    }
                }
            }) {
                Image(systemName: volumeIcon)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(musicManager.volumeControlSupported ? .white : .gray)
            }
            .buttonStyle(PlainButtonStyle())
            .disabled(!musicManager.volumeControlSupported)
            .frame(width: 24)

            if showVolumeSlider && musicManager.volumeControlSupported {
                CustomSlider(
                    value: $volumeSliderValue,
                    range: 0.0...1.0,
                    color: .white,
                    dragging: $dragging,
                    lastDragged: .constant(Date.distantPast),
                    onValueChange: { newValue in
                        MusicManager.shared.setVolume(to: newValue)
                    },
                    onDragChange: { newValue in
                        let now = Date()
                        if now.timeIntervalSince(lastVolumeUpdateTime) > volumeUpdateThrottle {
                            MusicManager.shared.setVolume(to: newValue)
                            lastVolumeUpdateTime = now
                        }
                    }
                )
                .frame(width: 48, height: 8)
                .transition(.scale.combined(with: .opacity))
            }
        }
        .clipped()
        .onReceive(musicManager.$volume) { volume in
            if !dragging {
                volumeSliderValue = volume
            }
        }
        .onReceive(musicManager.$volumeControlSupported) { supported in
            if !supported {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showVolumeSlider = false
                }
            }
        }
        .onChange(of: showVolumeSlider) { _, isShowing in
            if isShowing {
                // Sync volume from app when slider appears
                Task {
                    await MusicManager.shared.syncVolumeFromActiveApp()
                }
            }
        }
        .onDisappear {
            // volumeUpdateTask?.cancel() // No longer needed
        }
    }
    
    
    private var volumeIcon: String {
        if !musicManager.volumeControlSupported {
            return "speaker.slash"
        } else if volumeSliderValue == 0 {
            return "speaker.slash.fill"
        } else if volumeSliderValue < 0.33 {
            return "speaker.1.fill"
        } else if volumeSliderValue < 0.66 {
            return "speaker.2.fill"
        } else {
            return "speaker.3.fill"
        }
    }
}

enum MusicLyricsDisplayMode {
    case closed
    case expanded
}

struct MusicLyricsDisplayView: View {
    @ObservedObject var musicManager = MusicManager.shared
    let mode: MusicLyricsDisplayMode

    private var maxLines: Int {
        mode == .expanded ? 5 : 1
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: mode == .closed ? 0.035 : 0.25)) { timeline in
            let elapsed = estimatedElapsed(at: timeline.date)
            Group {
                switch mode {
                case .closed:
                    let text = closedLyricText(at: elapsed)
                    if !text.isEmpty {
                        GeometryReader { geo in
                            closedLyrics(
                                text,
                                lineProgress: closedLyricLineProgress(at: elapsed),
                                width: geo.size.width
                            )
                                .frame(width: geo.size.width, height: geo.size.height, alignment: .center)
                        }
                    }
                case .expanded:
                    let lines = expandedLyricLines(at: elapsed)
                    if !lines.isEmpty {
                        expandedLyrics(lines)
                    }
                }
            }
        }
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private var lyricColor: Color {
        if musicManager.isFetchingLyrics {
            return .gray.opacity(0.7)
        }
        return Defaults[.playerColorTinting]
            ? Color(nsColor: musicManager.avgColor).ensureMinimumBrightness(factor: 0.68)
            : .gray
    }

    private func lyricFont(for text: String) -> Font {
        if LyricsDisplayText.containsPersianScript(text) {
            return .custom("Vazirmatn-Regular", size: NSFont.preferredFont(forTextStyle: .subheadline).pointSize)
        }
        return .subheadline
    }

    private func estimatedElapsed(at date: Date) -> Double {
        guard musicManager.isPlaying else { return musicManager.elapsedTime }
        let delta = date.timeIntervalSince(musicManager.timestampDate)
        let progressed = musicManager.elapsedTime + (delta * musicManager.playbackRate)
        return min(max(progressed, 0), musicManager.songDuration)
    }

    private func closedLyricText(at elapsed: Double) -> String {
        if musicManager.isFetchingLyrics {
            return LyricsDisplayText.displayFallback(isFetching: true)
        }

        if let currentIndex = LyricsDisplayText.currentSyncedIndex(
            from: musicManager.syncedLyrics,
            elapsed: elapsed
        ) {
            return musicManager.syncedLyrics[currentIndex].text
        }

        let lyrics = musicManager.currentLyrics.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lyrics.isEmpty else {
            return ""
        }
        return LyricsDisplayText.singleLine(fromPlainLyrics: lyrics)
    }

    @ViewBuilder
    private func closedLyrics(_ text: String, lineProgress: Double?, width: CGFloat) -> some View {
        if closedLyricWidth(text) <= max(width - 2, 0) {
            KTVClosedLyricText(
                text: text,
                progress: lineProgress,
                baseColor: lyricColor.opacity(0.45),
                activeColor: lyricColor
            )
                .frame(maxWidth: .infinity, alignment: .center)
        } else {
            MarqueeText(
                .constant(text),
                font: .caption,
                nsFont: .caption1,
                textColor: lyricColor,
                minDuration: 1,
                frameWidth: width
            )
            .frame(width: width, alignment: .center)
        }
    }

    private func closedLyricLineProgress(at elapsed: Double) -> Double? {
        guard !musicManager.isFetchingLyrics, !musicManager.syncedLyrics.isEmpty else {
            return nil
        }
        return LyricsDisplayText.activeLineProgress(from: musicManager.syncedLyrics, elapsed: elapsed, leadTime: 0.22)
    }

    private func closedLyricWidth(_ text: String) -> CGFloat {
        let font = NSFont.preferredFont(forTextStyle: .caption1)
        return ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }

    private func expandedLyricLines(at elapsed: Double) -> [LyricsDisplayText.Line] {
        if musicManager.isFetchingLyrics {
            return [LyricsDisplayText.Line(text: LyricsDisplayText.displayFallback(isFetching: true), isCurrent: true)]
        }

        if !musicManager.syncedLyrics.isEmpty {
            return LyricsDisplayText.syncedWindow(from: musicManager.syncedLyrics, elapsed: elapsed, limit: maxLines)
        }

        let lyrics = musicManager.currentLyrics.trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = Array(LyricsDisplayText.lines(fromPlainLyrics: lyrics).prefix(maxLines))
        if lines.isEmpty {
            return [LyricsDisplayText.Line(text: LyricsDisplayText.displayFallback(isFetching: false), isCurrent: true)]
        }

        return lines.enumerated().map { index, text in
            LyricsDisplayText.Line(text: text, isCurrent: index == min(1, lines.count - 1))
        }
    }

    private func expandedLyrics(_ lines: [LyricsDisplayText.Line]) -> some View {
        let signature = lines.map { $0.text }.joined(separator: "|")

        return ZStack {
            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                Text(line.text.isEmpty ? " " : line.text)
                    .font(lyricFont(for: line.text))
                    .fontWeight(line.isCurrent ? .semibold : .regular)
                    .foregroundStyle(line.isCurrent ? activeLyricColor : inactiveLyricColor)
                    .lineLimit(1)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.82)
                    .frame(maxWidth: .infinity, minHeight: 18, alignment: .center)
                    .scaleEffect(line.isCurrent ? 1.03 : 0.94)
                    .opacity(line.text.isEmpty ? 0 : (line.isCurrent ? 1 : 0.34))
                    .offset(y: lyricYOffset(for: index, count: lines.count))
                    .id("\(index)-\(line.text)")
                    .transition(.asymmetric(
                        insertion: .offset(y: 18).combined(with: .opacity),
                        removal: .offset(y: -18).combined(with: .opacity)
                    ))
                    .animation(
                        .easeInOut(duration: 0.32).delay(Double(index) * 0.035),
                        value: signature
                    )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .clipped()
        .animation(.easeInOut(duration: 0.34), value: signature)
    }

    private func lyricYOffset(for index: Int, count: Int) -> CGFloat {
        let center = CGFloat(max(count - 1, 0)) / 2
        return (CGFloat(index) - center) * 20
    }

    private var activeLyricColor: Color {
        Defaults[.playerColorTinting]
            ? Color(nsColor: musicManager.avgColor).ensureMinimumBrightness(factor: 0.78)
            : .white
    }

    private var inactiveLyricColor: Color {
        .gray.opacity(0.72)
    }
}

struct KTVClosedLyricText: View {
    let text: String
    let progress: Double?
    let baseColor: Color
    let activeColor: Color
    @State private var textSize: CGSize = .zero

    var body: some View {
        ZStack {
            lyricText(color: baseColor)
                .modifier(MeasureSizeModifier())
                .onPreferenceChange(SizePreferenceKey.self) { size in
                    textSize = size
                }

            lyricText(color: activeColor)
                .mask(alignment: .leading) {
                    Rectangle()
                        .frame(width: max(0, textSize.width * CGFloat(progress ?? 0)))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(width: textSize.width, alignment: .leading)
                .animation(.linear(duration: 0.035), value: progress)
        }
        .frame(height: 18, alignment: .center)
        .frame(maxWidth: .infinity, alignment: .center)
        .clipped()
    }

    private func lyricText(color: Color) -> some View {
        Text(text)
            .font(.caption)
            .fontWeight(.medium)
            .foregroundStyle(color)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
    }
}

struct ClosedMusicLyricsLineView: View {
    let width: CGFloat

    var body: some View {
        MusicLyricsDisplayView(mode: .closed)
            .padding(.horizontal, 18)
            .frame(width: width, height: 24, alignment: .center)
    }
}

// MARK: - Main View

struct NotchHomeView: View {
    @EnvironmentObject var vm: BoringViewModel
    @ObservedObject var webcamManager = WebcamManager.shared
    @ObservedObject var batteryModel = BatteryStatusViewModel.shared
    @ObservedObject var coordinator = BoringViewCoordinator.shared
    @ObservedObject var musicManager = MusicManager.shared
    @State private var albumArtHeight: CGFloat = 0
    let albumArtNamespace: Namespace.ID

    var body: some View {
        Group {
            if !coordinator.firstLaunch {
                mainContent
            }
        }
        // simplified: use a straightforward opacity transition
        .transition(.opacity)
    }

    private var shouldShowCamera: Bool {
        Defaults[.showMirror] && webcamManager.cameraAvailable && vm.isCameraExpanded
    }

    private var mainContent: some View {
        HStack(alignment: .top, spacing: (shouldShowCamera && Defaults[.showCalendar]) ? 10 : 15) {
            HStack(alignment: .center, spacing: 12) {
                MusicPlayerView(albumArtNamespace: albumArtNamespace)
                    .onPreferenceChange(AlbumArtSizePreferenceKey.self) { size in
                        guard size.height > 0 else { return }
                        albumArtHeight = size.height
                    }

                if shouldShowExpandedLyrics {
                    MusicLyricsDisplayView(mode: .expanded)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .frame(width: 190, alignment: .center)
                        .frame(height: expandedLyricsHeight, alignment: .center)
                        .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(.white.opacity(0.06), lineWidth: 1)
                        )
                        .transition(.opacity.combined(with: .move(edge: .leading)))
                }
            }

            if Defaults[.showCalendar] {
                CalendarView()
                    .frame(width: shouldShowCamera ? 170 : 215)
                    .onHover { isHovering in
                        vm.isHoveringCalendar = isHovering
                    }
                    .environmentObject(vm)
                    .transition(.opacity)
            }

            if shouldShowCamera {
                CameraPreviewView(webcamManager: webcamManager)
                    .scaledToFit()
                    .opacity(vm.notchState == .closed ? 0 : 1)
                    .blur(radius: vm.notchState == .closed ? 20 : 0)
                    .animation(.interactiveSpring(response: 0.32, dampingFraction: 0.76, blendDuration: 0), value: shouldShowCamera)
            }
        }
        .transition(.asymmetric(insertion: .opacity.combined(with: .move(edge: .top)), removal: .opacity))
        .blur(radius: vm.notchState == .closed ? 30 : 0)
    }

    private var shouldShowExpandedLyrics: Bool {
        Defaults[.enableLyrics] && (musicManager.isPlaying || !musicManager.isPlayerIdle)
    }

    private var expandedLyricsHeight: CGFloat {
        max(albumArtHeight, MusicPlayerImageSizes.size.opened.height + 10)
    }
}

struct MusicSliderView: View {
    @Binding var sliderValue: Double
    @Binding var duration: Double
    @Binding var lastDragged: Date
    var color: NSColor
    @Binding var dragging: Bool
    let currentDate: Date
    let timestampDate: Date
    let elapsedTime: Double
    let playbackRate: Double
    let isPlaying: Bool
    var onValueChange: (Double) -> Void


    var body: some View {
        VStack {
            CustomSlider(
                value: $sliderValue,
                range: 0...duration,
                color: Defaults[.sliderColor] == SliderColorEnum.albumArt
                    ? Color(nsColor: color).ensureMinimumBrightness(factor: 0.8)
                    : Defaults[.sliderColor] == SliderColorEnum.accent ? .effectiveAccent : .white,
                dragging: $dragging,
                lastDragged: $lastDragged,
                onValueChange: onValueChange
            )
            .frame(height: 10, alignment: .center)

            HStack {
                Text(timeString(from: sliderValue))
                Spacer()
                Text(timeString(from: duration))
            }
            .fontWeight(.medium)
            .foregroundColor(
                Defaults[.playerColorTinting]
                    ? Color(nsColor: color).ensureMinimumBrightness(factor: 0.6) : .gray
            )
            .font(.caption)
        }
        .onChange(of: currentDate) {
           guard !dragging, timestampDate.timeIntervalSince(lastDragged) > -1 else { return }
            sliderValue = MusicManager.shared.estimatedPlaybackPosition(at: currentDate)
        }
    }

    func timeString(from seconds: Double) -> String {
        let totalMinutes = Int(seconds) / 60
        let remainingSeconds = Int(seconds) % 60
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, remainingSeconds)
        } else {
            return String(format: "%d:%02d", minutes, remainingSeconds)
        }
    }
}

struct CustomSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double>
    var color: Color = .white
    @Binding var dragging: Bool
    @Binding var lastDragged: Date
    var onValueChange: ((Double) -> Void)?
    var onDragChange: ((Double) -> Void)?

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = CGFloat(dragging ? 9 : 5)
            let rangeSpan = range.upperBound - range.lowerBound

            let progress = rangeSpan == .zero ? 0 : (value - range.lowerBound) / rangeSpan
            let filledTrackWidth = min(max(progress, 0), 1) * width

            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(.gray.opacity(0.3))
                    .frame(height: height)

                Rectangle()
                    .fill(color)
                    .frame(width: filledTrackWidth, height: height)
            }
            .cornerRadius(height / 2)
            .frame(height: 10)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        withAnimation {
                            dragging = true
                        }
                        let newValue = range.lowerBound + Double(gesture.location.x / width) * rangeSpan
                        value = min(max(newValue, range.lowerBound), range.upperBound)
                        onDragChange?(value)
                    }
                    .onEnded { _ in
                        onValueChange?(value)
                        dragging = false
                        lastDragged = Date()
                    }
            )
            .animation(.spring(response: 0.35, dampingFraction: 0.7), value: dragging)
        }
    }
}
