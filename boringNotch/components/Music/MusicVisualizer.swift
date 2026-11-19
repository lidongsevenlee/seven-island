//
//  MusicVisualizer.swift
//  boringNotch
//
//  Created by Harsh Vardhan  Goswami  on 02/08/24.
//
import SwiftUI

@MainActor
struct CompactMusicSpectrum: View {
    let isPlaying: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var spectrum = MusicAudioSpectrum.shared
    private let columnCount = 4

    var body: some View {
        GeometryReader { geometry in
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(0..<columnCount, id: \.self) { column in
                    let level = isPlaying && !reduceMotion ? spectrum.level(for: column, outOf: columnCount) : 0
                    Capsule()
                        .fill(.white)
                        .frame(width: 2, height: max(2, geometry.size.height * CGFloat(level)))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .animation(reduceMotion ? nil : .linear(duration: 0.06), value: spectrum.levels)
        }
        .allowsHitTesting(false)
    }
}

@MainActor
struct MusicBarsView: View {
    let isPlaying: Bool
    let color: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var spectrum = MusicAudioSpectrum.shared
    @State private var bars: [MusicSpectrumBar] = []

    private struct AnimationConfiguration: Equatable {
        let count: Int
        let isPlaying: Bool
        let reduceMotion: Bool
    }

    var body: some View {
        GeometryReader { geometry in
            let count = min(AudioSpectrumAnalyzer.bandCount, max(1, Int(geometry.size.width / 6)))
            let configuration = AnimationConfiguration(count: count, isPlaying: isPlaying, reduceMotion: reduceMotion)
            ZStack {
                Canvas { context, size in
                    drawBars(context: context, size: size, configuration: configuration)
                }
                .allowsHitTesting(false)
                .task(id: configuration) { await animateBars(configuration) }

                if isPlaying && !reduceMotion, let message = spectrum.statusMessage {
                    HStack(spacing: 6) {
                        Text(message)
                            .lineLimit(1)
                        Button {
                            spectrum.retry()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .buttonStyle(.plain)
                        .help("重新连接播放器音频")
                    }
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.black.opacity(0.8), in: Capsule())
                }
            }
        }
        .contentShape(Rectangle())
        .contextMenu {
            Button("重新连接播放器音频") { spectrum.retry() }
            Button("系统音频权限设置") { spectrum.openAudioPrivacySettings() }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("音乐律动")
        .accessibilityValue(spectrum.statusMessage ?? (isPlaying ? "实时频谱播放中" : "已暂停"))
    }

    private func drawBars(context: GraphicsContext, size: CGSize, configuration: AnimationConfiguration) {
        guard size.width > 0, size.height > 0 else { return }
        let count = configuration.count
        let width = min(3, size.width / CGFloat(count))
        let step = count > 1 ? (size.width - width) / CGFloat(count - 1) : 0
        let dotGap: CGFloat = 1
        let scale = min(1, max(0, size.height - width - dotGap) / MusicSpectrumBar.peakCeiling)
        let barColor = GraphicsContext.Shading.color(color.opacity(isPlaying ? 0.85 : 0.25))
        let dotColor = GraphicsContext.Shading.color(color.opacity(isPlaying ? 1 : 0.35))
        let hasMovingBars = !configuration.reduceMotion && bars.count == count

        for index in 0..<count {
            let bar = hasMovingBars ? bars[index] : MusicSpectrumBar()
            let x = CGFloat(index) * step
            let height = bar.height * scale
            let rect = CGRect(x: x, y: size.height - height, width: width, height: height)
            context.fill(Path(roundedRect: rect, cornerRadius: width / 2), with: barColor)
            let distanceAboveBar = (bar.peak - bar.height) * scale
            let showsPlayingDot = configuration.isPlaying && !configuration.reduceMotion
            if showsPlayingDot || distanceAboveBar > 0 {
                let gap = showsPlayingDot ? dotGap : min(dotGap, distanceAboveBar)
                let dot = CGRect(x: x, y: rect.minY - distanceAboveBar - gap - width, width: width, height: width)
                context.fill(Path(ellipseIn: dot), with: dotColor)
            }
        }
    }

    private func animateBars(_ configuration: AnimationConfiguration) async {
        guard !configuration.reduceMotion else {
            bars = []
            return
        }

        let restingBar = MusicSpectrumBar()
        var next = bars.count == configuration.count ? bars : Array(repeating: restingBar, count: configuration.count)
        var previousTime = ProcessInfo.processInfo.systemUptime
        while !Task.isCancelled && (configuration.isPlaying || next.contains { $0 != restingBar }) {
            do {
                try await Task.sleep(for: .milliseconds(16))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            let now = ProcessInfo.processInfo.systemUptime
            let elapsed = min(now - previousTime, 0.05)
            previousTime = now

            for index in next.indices {
                let level = configuration.isPlaying ? spectrum.level(for: index, outOf: configuration.count) : 0
                next[index].advance(level: CGFloat(level), elapsed: elapsed)
            }
            if bars != next { bars = next }
        }
    }
}

#Preview {
    CompactMusicSpectrum(isPlaying: false)
        .frame(width: 16, height: 20)
        .padding()
}
