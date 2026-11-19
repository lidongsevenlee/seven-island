import Foundation

struct MusicSpectrumBar: Equatable {
    static let restingHeight: CGFloat = 3
    static let maximumHeight: CGFloat = 32 * 5 / 3
    static let peakCeiling = maximumHeight + 10

    private(set) var height = restingHeight
    private(set) var peak = restingHeight
    private var peakVelocity: CGFloat = 0

    mutating func advance(level: CGFloat, elapsed: TimeInterval) {
        guard elapsed > 0 else { return }
        let step = CGFloat(elapsed)
        let target = max(Self.restingHeight, level * Self.maximumHeight)
        let previousHeight = height
        let response = target >= height ? 0.03 : 0.065
        height += (target - height) * (1 - exp(-elapsed / response))
        if abs(target - height) < 0.01 { height = target }

        let riseSpeed = (height - previousHeight) / step
        let gravity: CGFloat = peakVelocity > 0 ? 460 : 110
        let nextVelocity = max(-60, peakVelocity - gravity * step)
        let nextPeak = peak + (peakVelocity + nextVelocity) * step / 2

        if nextPeak <= height {
            peak = height
            peakVelocity = riseSpeed > 12 ? min(150, riseSpeed * 1.5) : 0
        } else {
            peak = min(Self.peakCeiling, nextPeak)
            peakVelocity = nextPeak >= Self.peakCeiling ? 0 : nextVelocity
        }
    }
}
