import Foundation
import CoreAudio

@main
enum AudioSpectrumTests {
    static func main() {
        let analyzer = AudioSpectrumAnalyzer()
        let silence = [Float](repeating: 0, count: AudioSpectrumAnalyzer.frameCount)
        expect(analyzer.levels(channels: [silence], sampleRate: 48_000).allSatisfy { $0 == 0 }, "silence stays still")
        expect(analyzer.levels(channels: [[Float](repeating: 0.5, count: silence.count)], sampleRate: 48_000).allSatisfy { $0 == 0 }, "removes DC offset")
        expect(analyzer.levels(channels: [], sampleRate: 48_000).allSatisfy { $0 == 0 }, "handles missing samples")
        expect(analyzer.levels(channels: [silence], sampleRate: 0).allSatisfy { $0 == 0 }, "handles invalid sample rates")

        for rate in [44_100.0, 48_000.0, 96_000.0] {
            let bass = analyzer.levels(channels: [tone(250, rate: rate)], sampleRate: rate)
            let treble = analyzer.levels(channels: [tone(4_000, rate: rate)], sampleRate: rate)
            expect(peakIndex(bass) < 20, "bass appears in low frequency bands at \(rate)")
            expect(peakIndex(treble) > 30, "treble appears in high frequency bands at \(rate)")
            expect(peakIndex(treble) - peakIndex(bass) > 15, "pitch changes move the spectrum")
            expect(bass.max()! > 0.8 && treble.max()! > 0.8, "detects audible tones")
        }

        let loud = analyzer.levels(channels: [tone(1_000, amplitude: 0.8)], sampleRate: 48_000)
        let quiet = analyzer.levels(channels: [tone(1_000, amplitude: 0.05)], sampleRate: 48_000)
        expect(loud.max()! > quiet.max()! + 0.2, "louder sound produces taller bars")
        let signal = tone(1_000)
        let stereo = analyzer.levels(channels: [signal, signal.map { -$0 }], sampleRate: 48_000)
        expect(stereo.max()! > 0.8, "preserves opposite phase stereo energy")
        let invalid = analyzer.levels(channels: [[Float](repeating: .nan, count: silence.count)], sampleRate: 48_000)
        expect(invalid.allSatisfy { $0.isFinite && (0...1).contains($0) }, "keeps levels finite and bounded")
        expect(analyzer.levels(channels: [silence], sampleRate: 48_000).allSatisfy { $0 == 0 }, "clears previous signal on silence")
        testInputBuffers()
        testPeakMotion()
        print("AudioSpectrumTests passed")
    }

    private static func testPeakMotion() {
        var bar = MusicSpectrumBar()
        let step = 1.0 / 60
        for _ in 0..<18 {
            bar.advance(level: 0.65, elapsed: step)
        }
        expect(bar.peak > bar.height + 3, "a fast rise launches the marker above the column")

        var gentlyRising = MusicSpectrumBar()
        for frame in 1...180 {
            gentlyRising.advance(level: 0.65 * CGFloat(frame) / 180, elapsed: step)
        }
        expect(gentlyRising.peak - gentlyRising.height < bar.peak - bar.height,
               "a slow rise gives the marker less lift")

        let previousPeak = bar.peak
        for _ in 0..<18 {
            bar.advance(level: 0.2, elapsed: step)
        }
        expect(bar.peak < previousPeak && bar.peak > bar.height, "the marker falls gradually toward the column")
        for _ in 0..<90 {
            bar.advance(level: 0.2, elapsed: step)
        }
        expect(bar.peak == bar.height, "the marker settles on the column")
        for _ in 0..<18 {
            bar.advance(level: 0.65, elapsed: step)
        }
        expect(bar.peak > bar.height + 3, "the next rise launches the marker again")

        for _ in 0..<120 {
            bar.advance(level: 1, elapsed: step)
            expect(bar.peak >= bar.height && bar.peak <= MusicSpectrumBar.peakCeiling,
                   "the marker stays between the column and the top of the plot")
        }
        expect(abs(bar.height - 32 * 5 / 3) < 0.01, "full scale height is two thirds taller")

        for _ in 0..<18 {
            bar.advance(level: 0, elapsed: step)
        }
        expect(bar.peak > bar.height, "the peak is still falling after the audio stops")
        for _ in 0..<120 {
            bar.advance(level: 0, elapsed: step)
        }
        expect(bar == MusicSpectrumBar(), "the peak and column fully settle into one resting point")
    }

    private static func testInputBuffers() {
        let signal = tone(1_000)
        var received: [[Float]] = []
        let processor = SpectrumBufferProcessor(sampleRate: 48_000) { received.append($0) }
        var stereo = signal.flatMap { [$0, -$0] }
        stereo.withUnsafeMutableBytes { bytes in
            for chunk in 0..<4 {
                var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                    mNumberChannels: 2,
                    mDataByteSize: 512 * 2 * UInt32(MemoryLayout<Float>.size),
                    mData: bytes.baseAddress!.advanced(by: chunk * 512 * 2 * MemoryLayout<Float>.size)
                ))
                withUnsafePointer(to: &list) { processor.consume($0) }
                expect(received.count == (chunk == 3 ? 1 : 0), "accumulates complete PCM frames across callbacks")
            }
        }
        expect(received[0].max()! > 0.8, "decodes interleaved stereo without phase cancellation")

        received = []
        let planarProcessor = SpectrumBufferProcessor(sampleRate: 48_000) { received.append($0) }
        var left = [Float](repeating: 0, count: signal.count)
        var right = tone(4_000)
        let byteCount = MemoryLayout<AudioBufferList>.size + MemoryLayout<AudioBuffer>.stride
        let memory = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { memory.deallocate() }
        memory.initializeMemory(as: UInt8.self, repeating: 0, count: byteCount)
        let list = memory.assumingMemoryBound(to: AudioBufferList.self)
        list.pointee.mNumberBuffers = 2
        let buffers = UnsafeMutableAudioBufferListPointer(list)
        left.withUnsafeMutableBytes { leftBytes in
            right.withUnsafeMutableBytes { rightBytes in
                buffers[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(leftBytes.count), mData: leftBytes.baseAddress)
                buffers[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(rightBytes.count), mData: rightBytes.baseAddress)
                planarProcessor.consume(UnsafePointer(list))
            }
        }
        expect(received.count == 1 && received[0].max()! > 0.8, "decodes planar audio from the second channel")
        expect(peakIndex(received[0]) > 30, "preserves planar channel frequency")
        var empty = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: 0, mData: nil))
        withUnsafePointer(to: &empty) { planarProcessor.consume($0) }
        expect(received.count == 1, "ignores empty input buffers")
    }

    private static func tone(_ frequency: Double, amplitude: Float = 0.8, rate: Double = 48_000) -> [Float] {
        (0..<AudioSpectrumAnalyzer.frameCount).map { amplitude * Float(sin(2 * .pi * frequency * Double($0) / rate)) }
    }

    private static func peakIndex(_ levels: [Float]) -> Int {
        levels.indices.max { levels[$0] < levels[$1] }!
    }

    private static func expect(_ condition: Bool, _ message: String) {
        guard condition else { fputs("FAIL: \(message)\n", stderr); exit(1) }
    }
}
