import Foundation

enum AudioProcessingMode: String, CaseIterable, Identifiable {
    case voice
    case raw

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .voice:
            return "人声"
        case .raw:
            return "原声"
        }
    }
}

struct AudioProcessingSnapshot: Equatable {
    var inputRMS: Float = 0
    var outputPeak: Float = 0
    var automaticGain: Float = 1
    var limiterHits: UInt64 = 0
}

struct AudioTuningSettings: Equatable {
    var blackHoleOutputBoostDecibels: Float = 6.0
    var monitorOutputVolume: Float = 0.35
    var voiceTargetRMS: Float = 0.055
    var automaticGainLimit: Float = 1.8
    var noiseGateFloor: Float = 0.28
    var limiterCeiling: Float = 0.82
    var finalLimiterCeiling: Float = 0.84

    func clamped() -> AudioTuningSettings {
        AudioTuningSettings(
            blackHoleOutputBoostDecibels: min(max(blackHoleOutputBoostDecibels, 0), 14),
            monitorOutputVolume: min(max(monitorOutputVolume, 0), 1),
            voiceTargetRMS: min(max(voiceTargetRMS, 0.035), 0.12),
            automaticGainLimit: min(max(automaticGainLimit, 1), 4),
            noiseGateFloor: min(max(noiseGateFloor, 0), 0.5),
            limiterCeiling: min(max(limiterCeiling, 0.70), 0.98),
            finalLimiterCeiling: min(max(finalLimiterCeiling, 0.70), 0.98)
        )
    }
}

protocol MicrophoneOutputEngine {
    var outputName: String { get }
    var monitorName: String { get }
    var gainDecibels: Float { get set }
    var processingMode: AudioProcessingMode { get set }
    var tuningSettings: AudioTuningSettings { get set }
    var monitoringEnabled: Bool { get set }
    var processingSnapshot: AudioProcessingSnapshot { get }
    func start() throws
    func stop()
}

final class HALDriverOutputEngine: MicrophoneOutputEngine {
    var outputName: String { "PhoneMic HAL Driver (not installed)" }
    var monitorName: String { "未启用" }
    var gainDecibels: Float = 10
    var processingMode: AudioProcessingMode = .voice
    var tuningSettings = AudioTuningSettings()
    var monitoringEnabled = false
    var processingSnapshot = AudioProcessingSnapshot()

    func start() throws {
        throw HALDriverOutputError.notImplemented
    }

    func stop() {}
}

enum HALDriverOutputError: LocalizedError {
    case notImplemented

    var errorDescription: String? {
        "The custom HAL driver interface is reserved for phase 2. Use BlackHole 2ch for the MVP."
    }
}
