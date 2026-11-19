import Accelerate
import Foundation

final class AudioSpectrumAnalyzer {
    static let frameCount = 2048
    static let bandCount = 48

    private let setup: vDSP_DFT_Setup?
    private var window = [Float](repeating: 0, count: frameCount)
    private var input = [Float](repeating: 0, count: frameCount)
    private let imaginaryInput = [Float](repeating: 0, count: frameCount)
    private var real = [Float](repeating: 0, count: frameCount)
    private var imaginary = [Float](repeating: 0, count: frameCount)
    private var power = [Float](repeating: 0, count: frameCount / 2)
    private let normalization: Float

    init() {
        setup = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(Self.frameCount), .FORWARD)
        vDSP_hann_window(&window, vDSP_Length(Self.frameCount), Int32(vDSP_HANN_NORM))
        let windowSum = window.reduce(0, +)
        normalization = 4 / (windowSum * windowSum)
    }

    deinit {
        if let setup { vDSP_DFT_DestroySetup(setup) }
    }

    func levels(channels: [[Float]], sampleRate: Double) -> [Float] {
        let silence = [Float](repeating: 0, count: Self.bandCount)
        guard let setup, sampleRate.isFinite, sampleRate > 80,
              !channels.isEmpty,
              channels.allSatisfy({ $0.count >= Self.frameCount }) else { return silence }

        for index in power.indices { power[index] = 0 }
        for channel in channels {
            var mean: Float = 0
            for index in input.indices {
                input[index] = channel[index].isFinite ? min(1, max(-1, channel[index])) : 0
                mean += input[index]
            }
            mean /= Float(Self.frameCount)
            for index in input.indices { input[index] = (input[index] - mean) * window[index] }
            vDSP_DFT_Execute(setup, input, imaginaryInput, &real, &imaginary)
            for index in power.indices {
                power[index] += (real[index] * real[index] + imaginary[index] * imaginary[index])
                    * normalization / Float(channels.count)
            }
        }

        let lowFrequency = 40.0
        let highFrequency = min(16_000, sampleRate / 2 * 0.98)
        let ratio = highFrequency / lowFrequency
        let binWidth = sampleRate / Double(Self.frameCount)
        return (0..<Self.bandCount).map { band in
            let lower = lowFrequency * pow(ratio, Double(band) / Double(Self.bandCount))
            let upper = lowFrequency * pow(ratio, Double(band + 1) / Double(Self.bandCount))
            let firstBin = min(power.count - 1, max(1, Int(lower / binWidth)))
            let lastBin = min(power.count - 1, max(firstBin, Int(ceil(upper / binWidth))))
            let peak = power[firstBin...lastBin].max() ?? 0
            let decibels = 10 * log10(max(peak, 1e-12))
            return min(1, max(0, (decibels + 65) / 65))
        }
    }
}
