import Foundation
import PhoneMicCore

enum PhoneMicConnectionState: String {
    case idle
    case discovering
    case pairing
    case connecting
    case streaming
    case recovering
    case offline
    case error

    var displayName: String {
        switch self {
        case .idle:
            return "空闲"
        case .discovering:
            return "等待 iPhone"
        case .pairing:
            return "正在配对"
        case .connecting:
            return "正在连接"
        case .streaming:
            return "正在发送到 Mac"
        case .recovering:
            return "正在恢复"
        case .offline:
            return "iPhone 离线"
        case .error:
            return "需要处理"
        }
    }
}

enum PhoneMicLatencyMode: String, CaseIterable, Identifiable {
    case automatic
    case lowLatency
    case stable

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .automatic:
            return "自动"
        case .lowLatency:
            return "低延迟"
        case .stable:
            return "稳定"
        }
    }

    func targetPrebufferMilliseconds(for transport: PhoneMicTransportKind) -> Float {
        switch self {
        case .automatic:
            return transport == .usb ? 8 : 20
        case .lowLatency:
            return transport == .usb ? 5 : 10
        case .stable:
            return 35
        }
    }
}

enum PhoneMicCalibrationState: Equatable {
    case idle
    case running(startedAt: Date)
    case finished(String)

    var displayName: String {
        switch self {
        case .idle:
            return "自动校准"
        case .running:
            return "校准中"
        case .finished(let message):
            return message
        }
    }
}
