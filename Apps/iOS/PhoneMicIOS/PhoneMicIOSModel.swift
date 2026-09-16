import Foundation
import PhoneMicCore
import SwiftUI
import UIKit

enum PhoneMicThemePreference: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system:
            return "跟随系统"
        case .light:
            return "浅色"
        case .dark:
            return "深色"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system:
            return nil
        case .light:
            return .light
        case .dark:
            return .dark
        }
    }

    var interfaceStyle: UIUserInterfaceStyle {
        switch self {
        case .system:
            return .unspecified
        case .light:
            return .light
        case .dark:
            return .dark
        }
    }
}

enum PhoneMicDeviceNameMode: String, CaseIterable, Identifiable {
    case automatic
    case custom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .automatic:
            return "自动"
        case .custom:
            return "自定义"
        }
    }
}

@MainActor
final class PhoneMicIOSModel: ObservableObject {
    @Published var themePreference: PhoneMicThemePreference {
        didSet {
            UserDefaults.standard.set(themePreference.rawValue, forKey: Self.themePreferenceDefaultsKey)
        }
    }
    @Published var deviceNameMode: PhoneMicDeviceNameMode {
        didSet {
            guard deviceNameMode != oldValue else { return }
            if deviceNameMode == .automatic {
                restoreAutomaticDeviceName()
            } else {
                streamer.setDeviceDisplayName(deviceDisplayName)
            }
        }
    }
    @Published var isStreaming = false
    @Published var statusText = "已就绪，可以把这台 iPhone 作为麦克风广播。"
    @Published var clientText = "Waiting"
    @Published var transportText = "Wi-Fi Bonjour"
    @Published var packetCount: UInt64 = 0
    @Published var latestStatus: PhoneMicDeviceStatus?
    @Published var discoveredMacs: [PhoneMicDiscoveredMac] = []
    @Published var pendingOutgoingPairing: PhoneMicPendingPairing?
    @Published var pendingPairingRequest: PhoneMicPairingRequest?
    @Published var deviceDisplayName: String {
        didSet {
            if deviceNameMode == .custom {
                streamer.setDeviceDisplayName(deviceDisplayName)
            }
        }
    }
    @Published var inputMode: MicrophoneInputMode = .builtIn {
        didSet {
            streamer.setInputMode(inputMode)
        }
    }

    private let streamer = MicrophoneStreamer()
    private var startInFlight = false
    private static let themePreferenceDefaultsKey = "PhoneMic.themePreference"

    init() {
        if
            let rawTheme = UserDefaults.standard.string(forKey: Self.themePreferenceDefaultsKey),
            let savedTheme = PhoneMicThemePreference(rawValue: rawTheme)
        {
            themePreference = savedTheme
        } else {
            themePreference = .system
        }

        if MicrophoneStreamer.hasCustomDeviceDisplayName() {
            deviceNameMode = .custom
            deviceDisplayName = MicrophoneStreamer.savedDeviceDisplayName()
        } else {
            deviceNameMode = .automatic
            deviceDisplayName = MicrophoneStreamer.systemDeviceDisplayName()
        }

        streamer.onEvent = { [weak self] event in
            Task { @MainActor in
                self?.handle(event)
            }
        }
    }

    func toggle() {
        setStreamingRequested(!isStreaming)
    }

    func setStreamingRequested(_ shouldStream: Bool) {
        if shouldStream {
            startStreamingIfNeeded()
        } else {
            stopStreamingIfNeeded()
        }
    }

    private func startStreamingIfNeeded() {
        guard !isStreaming, !startInFlight else {
            return
        }

        startInFlight = true
        statusText = "正在连接 Mac..."
        Task {
            do {
                try await streamer.start()
            } catch {
                startInFlight = false
                statusText = Self.userFacingMessage(for: error)
            }
        }
    }

    private func stopStreamingIfNeeded() {
        startInFlight = false
        guard isStreaming else {
            return
        }

        streamer.stop()
    }

    func approvePairing() {
        if let request = pendingPairingRequest {
            statusText = "正在信任 \(request.macName)..."
        }
        streamer.respondToPairing(approved: true)
    }

    func rejectPairing() {
        if let request = pendingPairingRequest {
            statusText = "正在拒绝 \(request.macName)..."
        }
        streamer.respondToPairing(approved: false)
    }

    func pairWithMac(_ mac: PhoneMicDiscoveredMac) {
        statusText = "正在请求信任 \(mac.name)..."
        streamer.pairWithMac(id: mac.id)
    }

    func forgetTrustedMacs() {
        pendingPairingRequest = nil
        pendingOutgoingPairing = nil
        discoveredMacs = []
        clientText = "Waiting"
        statusText = "已忘记信任的 Mac，请重新配对。"
        streamer.forgetTrustedMacs()
    }

    func restoreAutomaticDeviceName() {
        deviceDisplayName = MicrophoneStreamer.systemDeviceDisplayName()
        streamer.useAutomaticDeviceDisplayName()
    }

    var systemDeviceDisplayName: String {
        MicrophoneStreamer.systemDeviceDisplayName()
    }

    var rawSystemDeviceDisplayName: String {
        MicrophoneStreamer.rawSystemDeviceDisplayName()
    }

    var canReadUserAssignedDeviceName: Bool {
        MicrophoneStreamer.canReadUserAssignedDeviceName()
    }

    var deviceModelDisplayName: String {
        MicrophoneStreamer.deviceModelDisplayName()
    }

    private func handle(_ event: MicrophoneStreamer.Event) {
        switch event {
        case .macsChanged(let macs):
            discoveredMacs = macs
            if !isStreaming {
                if let pairedMac = macs.first(where: \.isPaired) {
                    clientText = pairedMac.name
                    statusText = "已发现 \(pairedMac.name)，点击开始发送。"
                } else if let mac = macs.first {
                    clientText = mac.name
                    statusText = "已发现 \(mac.name)，请先信任此 Mac。"
                } else {
                    clientText = "Waiting"
                    statusText = "正在查找 Mac。"
                }
            }
        case .pairingStarted(let request):
            pendingOutgoingPairing = request
            statusText = "请在 Mac 上确认配对码 \(request.pairingCode)。"
        case .started:
            startInFlight = false
            isStreaming = true
            statusText = "正在连接 Mac。"
        case .pairingRequested(let request):
            pendingPairingRequest = request
            statusText = "收到来自 \(request.macName) 的配对请求。"
        case .pairingResponding(let macName):
            statusText = "正在信任 \(macName)..."
        case .pairingCompleted(let macName):
            pendingPairingRequest = nil
            pendingOutgoingPairing = nil
            statusText = "已信任 \(macName)，点击开始发送。"
        case .pairingRejected(let macName):
            pendingPairingRequest = nil
            pendingOutgoingPairing = nil
            statusText = "已拒绝 \(macName) 的配对请求。"
        case .clientConnected(let description):
            clientText = description
            statusText = "正在发送麦克风音频。"
        case .clientDisconnected:
            clientText = "Waiting"
            statusText = "Mac 已断开，仍在等待重新连接。"
        case .packetSent(let count):
            packetCount = count
        case .statusChanged(let status):
            latestStatus = status
            transportText = status.transport.displayName
            packetCount = status.packetCount
            if let macName = status.connectedMacName {
                clientText = macName
            }
        case .stopped:
            startInFlight = false
            isStreaming = false
            statusText = "已停止。"
            clientText = "Waiting"
        case .failed(let message):
            startInFlight = false
            pendingOutgoingPairing = nil
            statusText = message
        }
    }

    private static func userFacingMessage(for error: Error) -> String {
        if let streamerError = error as? MicrophoneStreamerError {
            return streamerError.errorDescription ?? "PhoneMic 无法启动。"
        }

        let nsError = error as NSError
        let detail = "\(nsError.domain) \(nsError.code)"
        if let fourCC = fourCharacterCode(nsError.code) {
            return "\(nsError.localizedDescription) (\(detail), \(fourCC))"
        }

        return "\(nsError.localizedDescription) (\(detail))"
    }

    private static func fourCharacterCode(_ code: Int) -> String? {
        let value = UInt32(bitPattern: Int32(truncatingIfNeeded: code))
        let bytes = [
            UInt8((value >> 24) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8(value & 0xff),
        ]

        guard bytes.allSatisfy({ byte in byte >= 32 && byte <= 126 }) else {
            return nil
        }

        return String(bytes: bytes, encoding: .ascii)
    }
}
