import Foundation

public struct AudioLevel: Equatable {
    public var rms: Float
    public var peak: Float

    public var normalized: Float {
        min(max(rms * 8, 0), 1)
    }

    public static let silence = AudioLevel(rms: 0, peak: 0)
}

public enum LevelMeter {
    public static func measure(_ samples: [Float]) -> AudioLevel {
        guard !samples.isEmpty else { return .silence }

        var sumOfSquares: Float = 0
        var peak: Float = 0

        for sample in samples {
            let magnitude = abs(sample)
            peak = max(peak, magnitude)
            sumOfSquares += sample * sample
        }

        return AudioLevel(
            rms: sqrt(sumOfSquares / Float(samples.count)),
            peak: peak
        )
    }
}
