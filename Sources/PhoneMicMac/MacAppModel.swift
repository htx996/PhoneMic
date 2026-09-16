import CoreAudio
import Foundation
import PhoneMicCore

@MainActor
final class MacAppModel: ObservableObject {
    @Published var isConnected = false
    @Published var connectionState: PhoneMicConnectionState = .discovering
    @Published var connectedDeviceName: String?
    @Published var connectionDescription = "等待 iPhone"
    @Published var outputDescription = "正在启动"
    @Published var virtualMicrophoneDescription = "--"
    @Published var systemInputDescription = "--"
    @Published var usbProxyDescription = "--"
    @Published var onboardingDescription = "首次使用请安装 BlackHole 2ch，并在 iPhone 上点击开始。"
    @Published var updateDescription = "开发版暂未启用自动更新"
    @Published var privacyDescription = "音频只在本地网络或 USB 内传输，不录音、不上传云端。"
    @Published var latestDeviceStatus: PhoneMicDeviceStatus?
    @Published var pendingPairingRequest: PhoneMicPendingPairing?
    @Published var latencyDescription = "--"
    @Published var bufferDescription = "--"
    @Published var discoveredDevices: [PhoneMicDiscoveredDevice] = []
    @Published private(set) var trustedPeers: [String: PhoneMicTrustedPeer]
    @Published var selectedDeviceID: String? {
        didSet {
            if !suppressSelectedDeviceReconfigure {
                receiver.configureTrustedDevices(
                    preferredDeviceID: selectedDeviceID.flatMap { trustedPeers[$0] == nil ? nil : $0 },
                    trustedSecrets: trustedSecrets
                )
            }
            if let selectedDeviceID {
                UserDefaults.standard.set(selectedDeviceID, forKey: Self.selectedDeviceDefaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.selectedDeviceDefaultsKey)
            }
        }
    }
    @Published var level: Float = 0
    @Published var transportStats = PhoneMicTransportStats()
    @Published var processingSnapshot = AudioProcessingSnapshot()
    @Published var outputGainDecibels: Float {
        didSet {
            let clampedValue = min(max(outputGainDecibels, 0), 12)
            if clampedValue != outputGainDecibels {
                outputGainDecibels = clampedValue
                return
            }

            outputEngine.gainDecibels = clampedValue
            UserDefaults.standard.set(Double(clampedValue), forKey: Self.outputGainDefaultsKey)
        }
    }
    @Published var processingMode: AudioProcessingMode {
        didSet {
            outputEngine.processingMode = processingMode
            UserDefaults.standard.set(processingMode.rawValue, forKey: Self.processingModeDefaultsKey)
        }
    }
    @Published var speakerMonitoringEnabled: Bool {
        didSet {
            outputEngine.monitoringEnabled = speakerMonitoringEnabled
            UserDefaults.standard.set(speakerMonitoringEnabled, forKey: Self.monitoringDefaultsKey)
        }
    }
    @Published var blackHoleOutputBoostDecibels: Float {
        didSet {
            let clampedValue = min(max(blackHoleOutputBoostDecibels, 0), 14)
            if clampedValue != blackHoleOutputBoostDecibels {
                blackHoleOutputBoostDecibels = clampedValue
                return
            }
            persistAudioTuning()
            applyAudioTuning()
        }
    }
    @Published var monitorOutputVolume: Float {
        didSet {
            let clampedValue = min(max(monitorOutputVolume, 0), 1)
            if clampedValue != monitorOutputVolume {
                monitorOutputVolume = clampedValue
                return
            }
            persistAudioTuning()
            applyAudioTuning()
        }
    }
    @Published var voiceTargetRMS: Float {
        didSet {
            let clampedValue = min(max(voiceTargetRMS, 0.035), 0.12)
            if clampedValue != voiceTargetRMS {
                voiceTargetRMS = clampedValue
                return
            }
            persistAudioTuning()
            applyAudioTuning()
        }
    }
    @Published var automaticGainLimit: Float {
        didSet {
            let clampedValue = min(max(automaticGainLimit, 1), 4)
            if clampedValue != automaticGainLimit {
                automaticGainLimit = clampedValue
                return
            }
            persistAudioTuning()
            applyAudioTuning()
        }
    }
    @Published var noiseGateFloor: Float {
        didSet {
            let clampedValue = min(max(noiseGateFloor, 0), 0.5)
            if clampedValue != noiseGateFloor {
                noiseGateFloor = clampedValue
                return
            }
            persistAudioTuning()
            applyAudioTuning()
        }
    }
    @Published var limiterCeiling: Float {
        didSet {
            let clampedValue = min(max(limiterCeiling, 0.70), 0.98)
            if clampedValue != limiterCeiling {
                limiterCeiling = clampedValue
                return
            }
            persistAudioTuning()
            applyAudioTuning()
        }
    }
    @Published var finalLimiterCeiling: Float {
        didSet {
            let clampedValue = min(max(finalLimiterCeiling, 0.70), 0.98)
            if clampedValue != finalLimiterCeiling {
                finalLimiterCeiling = clampedValue
                return
            }
            persistAudioTuning()
            applyAudioTuning()
        }
    }
    @Published var streamTimeoutSeconds: Float {
        didSet {
            let clampedValue = min(max(streamTimeoutSeconds, 1), 8)
            if clampedValue != streamTimeoutSeconds {
                streamTimeoutSeconds = clampedValue
                return
            }
            receiver.streamTimeoutSeconds = TimeInterval(clampedValue)
            UserDefaults.standard.set(Double(clampedValue), forKey: Self.streamTimeoutDefaultsKey)
        }
    }
    @Published var prebufferMilliseconds: Float {
        didSet {
            let clampedValue = min(max(prebufferMilliseconds, 5), 80)
            if clampedValue != prebufferMilliseconds {
                prebufferMilliseconds = clampedValue
                return
            }
            jitterBuffer.setMinimumPrebuffer(milliseconds: clampedValue)
            UserDefaults.standard.set(Double(clampedValue), forKey: Self.prebufferDefaultsKey)
            if !isApplyingLatencyPreset {
                prebufferManuallyOverridden = true
                UserDefaults.standard.set(true, forKey: Self.prebufferManualOverrideDefaultsKey)
            }
            refreshAudioMetrics()
        }
    }
    @Published var autoReconnect = true {
        didSet {
            receiver.autoReconnect = autoReconnect
        }
    }
    @Published var latencyMode: PhoneMicLatencyMode {
        didSet {
            UserDefaults.standard.set(latencyMode.rawValue, forKey: Self.latencyModeDefaultsKey)
            prebufferManuallyOverridden = false
            UserDefaults.standard.set(false, forKey: Self.prebufferManualOverrideDefaultsKey)
            applyLatencyMode(for: transportStats.transport, force: true)
        }
    }
    @Published var connectionMode: PhoneMicConnectionMode {
        didSet {
            UserDefaults.standard.set(connectionMode.rawValue, forKey: Self.connectionModeDefaultsKey)
            applyConnectionMode()
        }
    }
    @Published var calibrationState: PhoneMicCalibrationState = .idle

    private static let outputGainDefaultsKey = "PhoneMic.outputGainDecibels"
    private static let processingModeDefaultsKey = "PhoneMic.processingMode"
    private static let monitoringDefaultsKey = "PhoneMic.speakerMonitoringEnabled"
    private static let blackHoleOutputBoostDefaultsKey = "PhoneMic.blackHoleOutputBoostDecibels"
    private static let monitorOutputVolumeDefaultsKey = "PhoneMic.monitorOutputVolume"
    private static let voiceTargetRMSDefaultsKey = "PhoneMic.voiceTargetRMS"
    private static let automaticGainLimitDefaultsKey = "PhoneMic.automaticGainLimit"
    private static let noiseGateFloorDefaultsKey = "PhoneMic.noiseGateFloor"
    private static let limiterCeilingDefaultsKey = "PhoneMic.limiterCeiling"
    private static let finalLimiterCeilingDefaultsKey = "PhoneMic.finalLimiterCeiling"
    private static let streamTimeoutDefaultsKey = "PhoneMic.streamTimeoutSeconds"
    private static let prebufferDefaultsKey = "PhoneMic.prebufferMilliseconds"
    private static let prebufferManualOverrideDefaultsKey = "PhoneMic.prebufferManualOverride"
    private static let latencyModeDefaultsKey = "PhoneMic.latencyMode"
    private static let connectionModeDefaultsKey = "PhoneMic.connectionMode"
    private static let connectionModeAutoMigrationDefaultsKey = "PhoneMic.connectionModeAutoMigrationV1"
    private static let selectedDeviceDefaultsKey = "PhoneMic.selectedDeviceID"
    private static let trustedPeersDefaultsKey = "PhoneMic.trustedPeers"
    private static let previousInputDeviceDefaultsKey = "PhoneMic.previousInputDeviceID"
    private static let trustedPeerStore = PhoneMicTrustedPeerStore(
        service: "app.phonemic.mac.trustedIPhones",
        account: "trustedIPhones",
        userDefaultsKey: trustedPeersDefaultsKey
    )
    private let jitterBuffer = JitterBuffer()
    private let usbProxy = PhoneMicUSBProxy()
    private lazy var outputEngine: MicrophoneOutputEngine = BlackHoleOutputEngine(jitterBuffer: jitterBuffer)
    private lazy var receiver = MacAudioReceiver(jitterBuffer: jitterBuffer)
    private var metricsTimer: Timer?
    private var slowStatusTimer: Timer?
    private var latestLatencyMilliseconds: Double?
    private var previousInputDeviceID: AudioDeviceID?
    private var lastLimiterHits: UInt64 = 0
    private var lastClippingProtectionAt = Date.distantPast
    private var wiredConnectInFlight = false
    private var wiredNextConnectAttemptAt = Date.distantPast
    private var wiredConnectAttemptCount = 0
    private var resolvedTransport: PhoneMicTransportKind = .wifi
    private var smoothedLevel: Float = 0
    private var lastLevelPublishedAt = Date.distantPast
    private var lastWeakVoiceBoostAt = Date.distantPast
    private var suppressSelectedDeviceReconfigure = false
    private var isApplyingLatencyPreset = false
    private var prebufferManuallyOverridden = false

    init() {
        let defaultTuning = AudioTuningSettings()
        let savedGain = UserDefaults.standard.object(forKey: Self.outputGainDefaultsKey) as? Double
        outputGainDecibels = min(max(Float(savedGain ?? 10), 0), 12)
        blackHoleOutputBoostDecibels = Self.savedFloat(
            key: Self.blackHoleOutputBoostDefaultsKey,
            defaultValue: defaultTuning.blackHoleOutputBoostDecibels,
            range: 0...14
        )
        monitorOutputVolume = Self.savedFloat(
            key: Self.monitorOutputVolumeDefaultsKey,
            defaultValue: defaultTuning.monitorOutputVolume,
            range: 0...1
        )
        voiceTargetRMS = Self.savedFloat(
            key: Self.voiceTargetRMSDefaultsKey,
            defaultValue: defaultTuning.voiceTargetRMS,
            range: 0.035...0.12
        )
        automaticGainLimit = Self.savedFloat(
            key: Self.automaticGainLimitDefaultsKey,
            defaultValue: defaultTuning.automaticGainLimit,
            range: 1...4
        )
        noiseGateFloor = Self.savedFloat(
            key: Self.noiseGateFloorDefaultsKey,
            defaultValue: defaultTuning.noiseGateFloor,
            range: 0...0.5
        )
        limiterCeiling = Self.savedFloat(
            key: Self.limiterCeilingDefaultsKey,
            defaultValue: defaultTuning.limiterCeiling,
            range: 0.70...0.98
        )
        finalLimiterCeiling = Self.savedFloat(
            key: Self.finalLimiterCeilingDefaultsKey,
            defaultValue: defaultTuning.finalLimiterCeiling,
            range: 0.70...0.98
        )
        streamTimeoutSeconds = Self.savedFloat(
            key: Self.streamTimeoutDefaultsKey,
            defaultValue: 2.5,
            range: 1...8
        )
        prebufferMilliseconds = Self.savedFloat(
            key: Self.prebufferDefaultsKey,
            defaultValue: 20,
            range: 5...80
        )
        prebufferManuallyOverridden = UserDefaults.standard.bool(forKey: Self.prebufferManualOverrideDefaultsKey)
        let savedLatencyMode = UserDefaults.standard.string(forKey: Self.latencyModeDefaultsKey)
            .flatMap(PhoneMicLatencyMode.init(rawValue:))
        latencyMode = savedLatencyMode ?? .automatic

        let savedConnectionMode = UserDefaults.standard.string(forKey: Self.connectionModeDefaultsKey)
            .flatMap(PhoneMicConnectionMode.init(rawValue:))
        if !UserDefaults.standard.bool(forKey: Self.connectionModeAutoMigrationDefaultsKey) {
            connectionMode = .automatic
            UserDefaults.standard.set(PhoneMicConnectionMode.automatic.rawValue, forKey: Self.connectionModeDefaultsKey)
            UserDefaults.standard.set(true, forKey: Self.connectionModeAutoMigrationDefaultsKey)
        } else {
            connectionMode = savedConnectionMode ?? .automatic
            if savedConnectionMode == nil {
                UserDefaults.standard.set(PhoneMicConnectionMode.automatic.rawValue, forKey: Self.connectionModeDefaultsKey)
            }
        }

        let savedProcessingMode = UserDefaults.standard.string(forKey: Self.processingModeDefaultsKey)
            .flatMap(AudioProcessingMode.init(rawValue:))
        processingMode = savedProcessingMode ?? .voice

        if let savedMonitoring = UserDefaults.standard.object(forKey: Self.monitoringDefaultsKey) as? Bool {
            speakerMonitoringEnabled = savedMonitoring
        } else {
            speakerMonitoringEnabled = false
        }

        let savedPeers = Self.loadTrustedPeers()
        let savedSelectedDeviceID = UserDefaults.standard.string(forKey: Self.selectedDeviceDefaultsKey)
        previousInputDeviceID = Self.savedPreviousInputDeviceID()
        trustedPeers = savedPeers
        selectedDeviceID = savedSelectedDeviceID ?? savedPeers.keys.sorted().first
        jitterBuffer.setMinimumPrebuffer(milliseconds: prebufferMilliseconds)
    }

    func start() {
        receiver.autoReconnect = autoReconnect
        receiver.streamTimeoutSeconds = TimeInterval(streamTimeoutSeconds)
        usbProxy.onIPhoneUSBConnectionChanged = { [weak self] isIPhoneUSBConnected in
            Task { @MainActor in
                self?.handleUSBConnectionAvailabilityChanged(isIPhoneUSBConnected)
            }
        }
        autoSelectBlackHoleInput()
        refreshUSBProxyDescription()
        jitterBuffer.setMinimumPrebuffer(milliseconds: prebufferMilliseconds)
        outputEngine.processingMode = processingMode
        applyAudioTuning()
        receiver.configureTrustedDevices(
            preferredDeviceID: selectedDeviceID.flatMap { trustedPeers[$0] == nil ? nil : $0 },
            trustedSecrets: trustedSecrets
        )
        receiver.onEvent = { [weak self] event in
            Task { @MainActor in
                self?.handle(event)
            }
        }

        do {
            outputEngine.gainDecibels = outputGainDecibels
            outputEngine.monitoringEnabled = speakerMonitoringEnabled
            try outputEngine.start()
            outputDescription = outputEngine.outputName
        } catch {
            outputDescription = outputEngine.outputName
        }
        refreshAudioMetrics()
        refreshSlowStatus()

        applyConnectionMode()
        metricsTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshAudioMetrics()
            }
        }
        slowStatusTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshSlowStatus()
            }
        }
    }

    func stop() {
        metricsTimer?.invalidate()
        slowStatusTimer?.invalidate()
        usbProxy.onIPhoneUSBConnectionChanged = nil
        receiver.stop()
        outputEngine.stop()
        usbProxy.stop()
        refreshUSBProxyDescription()
    }

    func toggleConnection() {
        guard resolvedTransport == .wifi else {
            usbProxy.startIfAvailable()
            refreshUSBProxyDescription()
            let status = usbProxy.status
            connectionDescription = status.isRunning ? "USB" : "等待 USB"
            connectionState = status.isRunning ? .connecting : .offline
            onboardingDescription = status.message
            if status.isRunning {
                beginWiredConnectionWindow()
            }
            return
        }

        if isConnected {
            receiver.disconnect()
        } else if selectedDeviceID == nil {
            receiver.restartDiscovery()
        } else {
            receiver.restartDiscovery()
        }
    }

    func pair(_ device: PhoneMicDiscoveredDevice) {
        connectionState = .pairing
        let code = PhoneMicSecurity.randomPairingCode()
        let secret = PhoneMicSecurity.randomSecret()
        receiver.beginPairing(
            deviceID: device.id,
            macID: MacIdentity.id,
            macName: MacIdentity.name,
            code: code,
            secret: secret
        )
    }

    func approvePendingPairing() {
        guard let request = pendingPairingRequest else { return }
        receiver.respondToIncomingPairing(request, approved: true)
    }

    func rejectPendingPairing() {
        guard let request = pendingPairingRequest else { return }
        receiver.respondToIncomingPairing(request, approved: false)
        pendingPairingRequest = nil
        connectionState = .discovering
    }

    func forgetSelectedDevice() {
        guard let selectedDeviceID else { return }
        trustedPeers.removeValue(forKey: selectedDeviceID)
        persistTrustedPeers()
        self.selectedDeviceID = trustedPeers.keys.sorted().first
        receiver.disconnect()
    }

    func restorePreviousInputDevice() {
        systemInputDescription = AudioDeviceFinder.restoreDefaultInputDevice(previousInputDeviceID)
        virtualMicrophoneDescription = AudioDeviceFinder.blackHoleInputStatus()
    }

    func startAutoCalibration() {
        calibrationState = .running(startedAt: Date())
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            finishAutoCalibration()
        }
    }

    func checkForUpdates() {
        updateDescription = "当前为开发版，暂未配置正式更新源"
    }

    func isPaired(_ device: PhoneMicDiscoveredDevice) -> Bool {
        trustedPeers[device.id] != nil
    }

    var pairedDiscoveredDevices: [PhoneMicDiscoveredDevice] {
        let discoveredByID = discoveredDevices.reduce(into: [String: PhoneMicDiscoveredDevice]()) { result, device in
            result[device.id] = device
        }

        return trustedPeers.values
            .map { peer in
                let discovered = discoveredByID[peer.id]
                return PhoneMicDiscoveredDevice(
                    id: peer.id,
                    name: preferredDeviceDisplayName(stored: peer.name, discovered: discovered?.name),
                    transport: discovered?.transport ?? .wifi,
                    lastSeenAt: discovered?.lastSeenAt ?? peer.createdAt
                )
            }
            .sorted { lhs, rhs in
                lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
    }

    var unpairedDiscoveredDevices: [PhoneMicDiscoveredDevice] {
        discoveredDevices.filter { trustedPeers[$0.id] == nil }
    }

    private func handle(_ event: MacAudioReceiver.Event) {
        switch event {
        case .devicesChanged(let devices):
            discoveredDevices = devices
            devices.forEach { rememberDeviceNameIfBetter(deviceID: $0.id, name: $0.name) }
            if selectedDeviceID == nil,
               let pairedDevice = devices.first(where: { trustedPeers[$0.id] != nil }) {
                selectedDeviceID = pairedDevice.id
            }
        case .discovered(let name):
            connectedDeviceName = name
            connectionDescription = "已发现"
            connectionState = .connecting
        case .connected(let name, let transport):
            guard allowsCurrentConnectionMode(transport) else {
                receiver.disconnect()
                return
            }
            if transport == .usb {
                wiredConnectInFlight = false
                wiredConnectAttemptCount = 0
            }
            isConnected = true
            connectedDeviceName = name
            connectionDescription = transport.displayName
            connectionState = .streaming
        case .disconnected(let message):
            if connectionMode == .automatic, resolvedTransport == .usb {
                refreshAutomaticConnectionModeIfNeeded(forceUSBRefresh: true)
            }
            if resolvedTransport == .usb {
                wiredConnectInFlight = false
                onboardingDescription = wiredDisconnectDescription(message)
                wiredNextConnectAttemptAt = Date().addingTimeInterval(1.5)
            }
            isConnected = false
            connectionDescription = resolvedTransport == .usb ? "等待 USB" : "等待重连"
            connectionState = resolvedTransport == .usb ? .offline : (autoReconnect ? .recovering : .offline)
            clearLevel()
            latestLatencyMilliseconds = nil
            latestDeviceStatus = nil
            transportStats = PhoneMicTransportStats(transport: transportStats.transport)
            processingSnapshot = AudioProcessingSnapshot()
        case .packet(let packet):
            guard allowsCurrentConnectionMode(packet.transport) else {
                receiver.disconnect()
                resetConnectionAfterRejectedTransport()
                return
            }
            if packet.transport == .usb || packet.transport == .wifi {
                setIfChanged(&connectionDescription, packet.transport.displayName)
            }
            let measuredLevel = LevelMeter.measure(packet.samples)
            let gainedLevel = min(measuredLevel.normalized * outputGainMultiplier, 1)
            smoothedLevel = 0.75 * smoothedLevel + 0.25 * gainedLevel
            publishLevelIfNeeded(smoothedLevel)
            latestLatencyMilliseconds = PhoneMicClock.millisecondsSince(packet.sentWallClockNanoseconds)
        case .transportStats(let stats):
            guard allowsCurrentConnectionMode(stats.transport) else { return }
            transportStats = stats
            applyLatencyMode(for: stats.transport)
        case .deviceStatus(let status):
            guard allowsCurrentConnectionMode(status.transport) else {
                receiver.disconnect()
                resetConnectionAfterRejectedTransport()
                return
            }
            latestDeviceStatus = status
            rememberDeviceNameIfBetter(deviceID: status.deviceID, name: status.deviceName)
            connectedDeviceName = preferredDeviceDisplayName(
                stored: trustedPeers[status.deviceID]?.name,
                discovered: status.deviceName
            )
            connectionDescription = status.transport.displayName
            if status.phase == .sending {
                isConnected = true
                connectionState = .streaming
            } else if status.phase == .idle || status.phase == .stopping {
                isConnected = false
                connectionState = .offline
                clearLevel()
                transportStats = PhoneMicTransportStats(transport: transportStats.transport)
                processingSnapshot = AudioProcessingSnapshot()
            } else {
                isConnected = false
                connectionState = .recovering
                clearLevel()
            }
        case .pairingCode(let code, let deviceName):
            _ = code
            _ = deviceName
        case .pairingRequested(let request):
            pendingPairingRequest = request
            connectionState = .pairing
        case .pairingSucceeded(let device, let secret):
            let peer = PhoneMicTrustedPeer(id: device.id, name: device.name, sharedSecret: secret)
            trustedPeers[device.id] = peer
            persistTrustedPeers()
            if isConnected {
                suppressSelectedDeviceReconfigure = true
                selectedDeviceID = device.id
                suppressSelectedDeviceReconfigure = false
            } else {
                selectedDeviceID = device.id
            }
            pendingPairingRequest = nil
            connectionState = isConnected ? .streaming : .discovering
        case .pairingFailed(let message):
            _ = message
            pendingPairingRequest = nil
            connectionState = .error
        case .streamStopping:
            isConnected = false
            connectionState = .offline
            clearLevel()
            latestLatencyMilliseconds = nil
        case .error(let message):
            if resolvedTransport == .usb {
                wiredConnectInFlight = false
                onboardingDescription = wiredDisconnectDescription(message)
                connectionDescription = "等待 USB"
                if message.contains("需要先通过无线配对") {
                    wiredNextConnectAttemptAt = Date().addingTimeInterval(3)
                }
            }
            connectionState = .error
        }
    }

    private func allowsCurrentConnectionMode(_ transport: PhoneMicTransportKind) -> Bool {
        switch connectionMode {
        case .automatic:
            return normalizedTransport(transport) == resolvedTransport
        case .wireless:
            return transport != .usb
        case .wired:
            return transport == .usb
        }
    }

    private func resetConnectionAfterRejectedTransport() {
        isConnected = false
        connectedDeviceName = nil
        latestDeviceStatus = nil
        clearLevel()
        latestLatencyMilliseconds = nil
        processingSnapshot = AudioProcessingSnapshot()
        switch resolvedTransport {
        case .wifi, .tcp, .udpReserved, .quicReserved:
            connectionDescription = "等待 iPhone"
            connectionState = .discovering
        case .usb:
            connectionDescription = "等待 USB"
            connectionState = .offline
        }
    }

    private var outputGainMultiplier: Float {
        Float(pow(10, Double(outputGainDecibels) / 20))
    }

    var audioTuningSettings: AudioTuningSettings {
        AudioTuningSettings(
            blackHoleOutputBoostDecibels: blackHoleOutputBoostDecibels,
            monitorOutputVolume: monitorOutputVolume,
            voiceTargetRMS: voiceTargetRMS,
            automaticGainLimit: automaticGainLimit,
            noiseGateFloor: noiseGateFloor,
            limiterCeiling: limiterCeiling,
            finalLimiterCeiling: finalLimiterCeiling
        ).clamped()
    }

    private func applyAudioTuning() {
        outputEngine.tuningSettings = audioTuningSettings
    }

    private func persistAudioTuning() {
        UserDefaults.standard.set(Double(blackHoleOutputBoostDecibels), forKey: Self.blackHoleOutputBoostDefaultsKey)
        UserDefaults.standard.set(Double(monitorOutputVolume), forKey: Self.monitorOutputVolumeDefaultsKey)
        UserDefaults.standard.set(Double(voiceTargetRMS), forKey: Self.voiceTargetRMSDefaultsKey)
        UserDefaults.standard.set(Double(automaticGainLimit), forKey: Self.automaticGainLimitDefaultsKey)
        UserDefaults.standard.set(Double(noiseGateFloor), forKey: Self.noiseGateFloorDefaultsKey)
        UserDefaults.standard.set(Double(limiterCeiling), forKey: Self.limiterCeilingDefaultsKey)
        UserDefaults.standard.set(Double(finalLimiterCeiling), forKey: Self.finalLimiterCeilingDefaultsKey)
    }

    private func applyConnectionMode() {
        if connectionMode == .automatic {
            usbProxy.requestIPhoneUSBRefresh(force: true)
        }
        let status = usbProxy.status
        resolveConnectionTransport(isIPhoneUSBConnected: status.isIPhoneConnected, force: true)
    }

    private func refreshUSBProxyDescription() {
        setIfChanged(&usbProxyDescription, usbProxy.status.message)
    }

    private func beginWiredConnectionWindow() {
        wiredNextConnectAttemptAt = .distantPast
        wiredConnectAttemptCount = 0
        connectionDescription = "等待 USB"
        connectionState = .connecting
        onboardingDescription = "\(connectionModeDescription)：请保持 iPhone 上 PhoneMic 打开并点击开始。Mac 会自动等待 USB 直连。"
        connectReceiverViaUSBProxy()
    }

    private func connectReceiverViaUSBProxy() {
        guard !wiredConnectInFlight else { return }
        wiredConnectInFlight = true
        wiredConnectAttemptCount += 1
        wiredNextConnectAttemptAt = Date().addingTimeInterval(1.5)
        let preferredPeer = selectedDeviceID.flatMap { trustedPeers[$0] }
        let fallbackPeer = trustedPeers.count == 1 ? trustedPeers.values.first : nil
        receiver.connectViaUSBProxy(
            deviceID: preferredPeer?.id ?? selectedDeviceID ?? fallbackPeer?.id,
            deviceName: preferredPeer?.name ?? fallbackPeer?.name
        )
    }

    private static func savedFloat(key: String, defaultValue: Float, range: ClosedRange<Float>) -> Float {
        let savedValue = UserDefaults.standard.object(forKey: key) as? Double
        let value = Float(savedValue ?? Double(defaultValue))
        return min(max(value, range.lowerBound), range.upperBound)
    }

    private func refreshAudioMetrics() {
        let snapshot = jitterBuffer.snapshot()
        setIfChanged(&processingSnapshot, outputEngine.processingSnapshot)
        setIfChanged(&bufferDescription, "\(snapshot.availableFrames) / \(snapshot.capacityFrames) (pre \(snapshot.prebufferFrames))")
        continueWiredConnectionWindowIfNeeded()
        protectAudioQualityIfNeeded(snapshot: snapshot)

        let nextLatencyDescription: String
        if let latestLatencyMilliseconds {
            nextLatencyDescription = "\(Int(latestLatencyMilliseconds.rounded())) ms"
        } else {
            nextLatencyDescription = "--"
        }
        setIfChanged(&latencyDescription, nextLatencyDescription)

    }

    private func refreshSlowStatus() {
        let blackHoleStatus = AudioDeviceFinder.blackHoleInputStatus()
        setIfChanged(&virtualMicrophoneDescription, blackHoleStatus)
        setIfChanged(&systemInputDescription, blackHoleStatus)
        usbProxy.requestIPhoneUSBRefresh()
        refreshUSBProxyDescription()
        refreshAutomaticConnectionModeIfNeeded()
    }

    private func publishLevelIfNeeded(_ newLevel: Float) {
        let now = Date()
        guard abs(newLevel - level) > 0.03 || now.timeIntervalSince(lastLevelPublishedAt) > 0.5 else { return }
        level = newLevel
        lastLevelPublishedAt = now
    }

    private func clearLevel() {
        smoothedLevel = 0
        setIfChanged(&level, 0)
        lastLevelPublishedAt = Date()
    }

    private func setIfChanged<T: Equatable>(_ property: inout T, _ value: T) {
        guard property != value else { return }
        property = value
    }

    private func continueWiredConnectionWindowIfNeeded() {
        guard resolvedTransport == .usb, !isConnected else { return }
        guard autoReconnect else { return }

        let now = Date()
        let status = usbProxy.status
        guard status.isRunning else {
            connectionState = .offline
            connectionDescription = "等待 USB"
            onboardingDescription = status.message
            return
        }

        guard !wiredConnectInFlight, now >= wiredNextConnectAttemptAt else { return }
        connectionDescription = "等待 USB"
        connectionState = .connecting
        onboardingDescription = "\(connectionModeDescription)：正在自动等待 iPhone USB 直连。"
        connectReceiverViaUSBProxy()
    }

    private func refreshAutomaticConnectionModeIfNeeded(forceUSBRefresh: Bool = false) {
        guard connectionMode == .automatic else { return }
        if forceUSBRefresh {
            usbProxy.requestIPhoneUSBRefresh(force: true)
        }
        let isIPhoneUSBConnected = usbProxy.status.isIPhoneConnected
        resolveConnectionTransport(isIPhoneUSBConnected: isIPhoneUSBConnected)
    }

    private func handleUSBConnectionAvailabilityChanged(_ isIPhoneUSBConnected: Bool) {
        refreshUSBProxyDescription()
        guard connectionMode == .automatic else { return }
        resolveConnectionTransport(isIPhoneUSBConnected: isIPhoneUSBConnected)
    }

    private func resolveConnectionTransport(isIPhoneUSBConnected: Bool, force: Bool = false) {
        let resolution = PhoneMicConnectionResolution(
            mode: connectionMode,
            currentTransport: resolvedTransport,
            isIPhoneUSBConnected: isIPhoneUSBConnected
        )
        guard force || resolution.shouldSwitchTransport else {
            refreshConnectionModeDescription(isIPhoneUSBConnected: isIPhoneUSBConnected)
            return
        }

        let previousTransport = resolvedTransport
        resolvedTransport = normalizedTransport(resolution.targetTransport)

        switch resolvedTransport {
        case .wifi:
            configureWiFiTransport(previousTransport: previousTransport, isIPhoneUSBConnected: isIPhoneUSBConnected)
        case .usb:
            configureUSBTransport(isIPhoneUSBConnected: isIPhoneUSBConnected)
        case .tcp, .udpReserved, .quicReserved:
            configureWiFiTransport(previousTransport: previousTransport, isIPhoneUSBConnected: isIPhoneUSBConnected)
        }
    }

    private func configureWiFiTransport(previousTransport: PhoneMicTransportKind, isIPhoneUSBConnected: Bool) {
        receiver.setTransportPolicy(.wifiOnly)
        usbProxy.stop()
        wiredConnectInFlight = false
        wiredConnectAttemptCount = 0
        transportStats = PhoneMicTransportStats(transport: .wifi)
        refreshUSBProxyDescription()

        if previousTransport == .usb {
            isConnected = false
            connectedDeviceName = nil
            latestDeviceStatus = nil
            latestLatencyMilliseconds = nil
            processingSnapshot = AudioProcessingSnapshot()
            jitterBuffer.clear()
            clearLevel()
        }

        connectionDescription = isConnected ? connectionDescription : "等待 iPhone"
        refreshConnectionModeDescription(isIPhoneUSBConnected: isIPhoneUSBConnected)
        receiver.start()
        if !isConnected {
            connectionState = autoReconnect ? .recovering : .discovering
        }
        applyLatencyMode(for: .wifi)
    }

    private func configureUSBTransport(isIPhoneUSBConnected: Bool) {
        receiver.setTransportPolicy(.usbOnly)
        receiver.stop()
        isConnected = false
        wiredConnectInFlight = false
        wiredConnectAttemptCount = 0
        connectedDeviceName = nil
        latestDeviceStatus = nil
        clearLevel()
        latestLatencyMilliseconds = nil
        transportStats = PhoneMicTransportStats(transport: .usb)
        jitterBuffer.clear()

        usbProxy.startIfAvailable()
        refreshUSBProxyDescription()
        let status = usbProxy.status
        connectionDescription = status.isRunning && status.isIPhoneConnected ? "USB" : "等待 USB"
        connectionState = status.isRunning ? .connecting : .offline
        refreshConnectionModeDescription(isIPhoneUSBConnected: isIPhoneUSBConnected)
        if status.isRunning {
            beginWiredConnectionWindow()
        }
        applyLatencyMode(for: .usb)
    }

    private func refreshConnectionModeDescription(isIPhoneUSBConnected: Bool) {
        switch connectionMode {
        case .automatic:
            onboardingDescription = isIPhoneUSBConnected
                ? "自动模式：已检测到 iPhone USB，优先使用有线连接。拔掉数据线后会回到无线。"
                : "自动模式：未检测到 iPhone USB，当前使用无线连接。插入 iPhone 数据线后会切到有线。"
        case .wireless:
            onboardingDescription = "无线模式：在 iPhone 上点击开始，Mac 会通过 Wi-Fi Bonjour 查找并连接。"
        case .wired:
            let status = usbProxy.status
            onboardingDescription = status.isAvailable
                ? "有线模式：只通过 USB 直连，不接收 Wi-Fi；拔线后不会自动回无线。"
                : status.message
        }
    }

    private var connectionModeDescription: String {
        switch connectionMode {
        case .automatic:
            return "自动模式"
        case .wireless:
            return "无线模式"
        case .wired:
            return "有线模式"
        }
    }

    private func normalizedTransport(_ transport: PhoneMicTransportKind) -> PhoneMicTransportKind {
        switch transport {
        case .tcp, .wifi, .udpReserved, .quicReserved:
            return .wifi
        case .usb:
            return .usb
        }
    }

    private func wiredDisconnectDescription(_ message: String) -> String {
        let status = usbProxy.status
        if !status.isIPhoneConnected {
            return "\(connectionModeDescription)：未检测到 iPhone USB，请确认数据线已连接并已信任此电脑。"
        }
        if message.localizedCaseInsensitiveContains("refused")
            || message.localizedCaseInsensitiveContains("reset")
            || message.localizedCaseInsensitiveContains("关闭") {
            return "\(connectionModeDescription)：已检测到 iPhone USB，但手机端连接被关闭。请保持 iPhone 上 PhoneMic 打开并点击开始。"
        }
        return "\(connectionModeDescription)：\(message)"
    }

    func deviceName(for deviceID: String?) -> String? {
        guard let deviceID else { return nil }
        return preferredDeviceDisplayName(
            stored: trustedPeers[deviceID]?.name,
            discovered: discoveredDevices.first(where: { $0.id == deviceID })?.name
        )
    }

    private func rememberDeviceNameIfBetter(deviceID: String, name: String) {
        guard var peer = trustedPeers[deviceID] else { return }
        let nextName = Self.preferredDeviceDisplayName(stored: peer.name, discovered: name)
        guard nextName != peer.name else { return }
        peer.name = nextName
        trustedPeers[deviceID] = peer
        persistTrustedPeers()
    }

    private func preferredDeviceDisplayName(stored: String?, discovered: String?) -> String {
        Self.preferredDeviceDisplayName(stored: stored, discovered: discovered)
    }

    private static func preferredDeviceDisplayName(stored: String?, discovered: String?) -> String {
        let storedName = normalizedDeviceName(stored)
        let discoveredName = normalizedDeviceName(discovered)

        if let discoveredName,
           (storedName == nil || storedName.map(isGenericIPhoneName) == true || !isGenericIPhoneName(discoveredName)) {
            return discoveredName
        }

        if let storedName {
            return storedName
        }

        return discoveredName ?? "iPhone"
    }

    private static func normalizedDeviceName(_ name: String?) -> String? {
        guard let name else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func isGenericIPhoneName(_ name: String) -> Bool {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized == "iphone" || normalized == "ios device"
    }

    private var trustedSecrets: [String: String] {
        trustedPeers.mapValues(\.sharedSecret)
    }

    private static func loadTrustedPeers() -> [String: PhoneMicTrustedPeer] {
        trustedPeerStore.load()
    }

    private func persistTrustedPeers() {
        try? Self.trustedPeerStore.save(trustedPeers)
    }

    private func autoSelectBlackHoleInput() {
        do {
            let currentDefault = try AudioDeviceFinder.defaultInputDeviceID()
            if let currentDefault,
               let currentName = try AudioDeviceFinder.defaultInputDeviceName(),
               !currentName.localizedCaseInsensitiveContains("BlackHole") {
                previousInputDeviceID = currentDefault
                UserDefaults.standard.set(Int(currentDefault), forKey: Self.previousInputDeviceDefaultsKey)
            }
        } catch {
            systemInputDescription = "CoreAudio 查询失败"
        }
        systemInputDescription = AudioDeviceFinder.selectBlackHoleAsDefaultInput()
        virtualMicrophoneDescription = AudioDeviceFinder.blackHoleInputStatus()
    }

    private static func savedPreviousInputDeviceID() -> AudioDeviceID? {
        let value = UserDefaults.standard.integer(forKey: previousInputDeviceDefaultsKey)
        guard value > 0 else { return nil }
        return AudioDeviceID(value)
    }

    private func applyLatencyMode(for transport: PhoneMicTransportKind, force: Bool = false) {
        guard force || !prebufferManuallyOverridden else { return }
        let target = latencyMode.targetPrebufferMilliseconds(for: transport)
        guard abs(prebufferMilliseconds - target) > 0.1 else { return }
        isApplyingLatencyPreset = true
        prebufferMilliseconds = target
        isApplyingLatencyPreset = false
    }

    private func finishAutoCalibration() {
        guard case .running = calibrationState else { return }
        let snapshot = processingSnapshot
        if snapshot.inputRMS < 0.002 {
            outputGainDecibels = min(outputGainDecibels + 2, 12)
            blackHoleOutputBoostDecibels = min(blackHoleOutputBoostDecibels + 1, 14)
            calibrationState = .finished("已增强弱声")
        } else if snapshot.outputPeak > 0.80 || snapshot.limiterHits > lastLimiterHits + 200 {
            outputGainDecibels = max(outputGainDecibels - 2, 0)
            automaticGainLimit = max(automaticGainLimit - 0.2, 1)
            calibrationState = .finished("已降低破音")
        } else {
            voiceTargetRMS = min(max(snapshot.inputRMS * 18, 0.045), 0.075)
            calibrationState = .finished("校准完成")
        }
        lastLimiterHits = snapshot.limiterHits
    }

    private func protectAudioQualityIfNeeded(snapshot: JitterBufferSnapshot) {
        let now = Date()
        let limiterDelta = processingSnapshot.limiterHits.saturatingSubtracting(lastLimiterHits)
        if (processingSnapshot.outputPeak > 0.88 || limiterDelta > 700),
           now.timeIntervalSince(lastClippingProtectionAt) > 2 {
            blackHoleOutputBoostDecibels = max(blackHoleOutputBoostDecibels - 0.5, 0)
            automaticGainLimit = max(automaticGainLimit - 0.1, 1)
            onboardingDescription = "检测到破音，已自动降低输出保护音质。"
            lastClippingProtectionAt = now
        }

        if isConnected,
           processingSnapshot.inputRMS > 0,
           processingSnapshot.inputRMS < 0.0012,
           processingSnapshot.outputPeak < 0.08,
           now.timeIntervalSince(lastWeakVoiceBoostAt) > 4 {
            blackHoleOutputBoostDecibels = min(blackHoleOutputBoostDecibels + 0.5, 14)
            outputGainDecibels = min(outputGainDecibels + 1, 12)
            onboardingDescription = "检测到声音偏小，已自动提高麦克风输出。"
            lastWeakVoiceBoostAt = now
        }
        lastLimiterHits = processingSnapshot.limiterHits

        _ = snapshot
    }
}

private extension UInt64 {
    func saturatingSubtracting(_ other: UInt64) -> UInt64 {
        self > other ? self - other : 0
    }
}
