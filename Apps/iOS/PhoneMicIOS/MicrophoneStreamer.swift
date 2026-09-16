import AVFoundation
import Foundation
import Network
import PhoneMicCore
import UIKit

enum MicrophoneInputMode: String, CaseIterable, Identifiable {
    case builtIn
    case bluetooth

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .builtIn:
            return "内置麦克风"
        case .bluetooth:
            return "蓝牙麦克风"
        }
    }
}

final class MicrophoneStreamer {
    enum Event {
        case started
        case macsChanged([PhoneMicDiscoveredMac])
        case pairingStarted(PhoneMicPendingPairing)
        case pairingRequested(PhoneMicPairingRequest)
        case pairingResponding(String)
        case pairingCompleted(String)
        case pairingRejected(String)
        case clientConnected(String)
        case clientDisconnected
        case packetSent(UInt64)
        case statusChanged(PhoneMicDeviceStatus)
        case stopped
        case failed(String)
    }

    var onEvent: ((Event) -> Void)?

    private let queue = DispatchQueue(label: "PhoneMic.iOS.MicrophoneStreamer")
    private let engine = AVAudioEngine()
    private let session = AVAudioSession.sharedInstance()
    private let trustedPeerStore = PhoneMicTrustedPeerStore(
        service: "app.phonemic.ios.trustedMacs",
        account: "trustedMacs",
        userDefaultsKey: MicrophoneStreamer.trustedPeersDefaultsKey
    )
    private var listener: NWListener?
    private var macBrowser: NWBrowser?
    private var connection: NWConnection?
    private var sourceEndpoint: NWEndpoint?
    private var controlConnections: [NWConnection] = []
    private var controlConnection: NWConnection?
    private var converter: AVAudioConverter?
    private var desiredFormat: AVAudioFormat?
    private var wantsStreaming = false
    private var sequence: UInt64 = 0
    private var sentPackets: UInt64 = 0
    private var packetsAtLastClientConnect: UInt64 = 0
    private var inputMode: MicrophoneInputMode = .builtIn
    private var pendingPairing: PendingPairing?
    private var outgoingPairing: OutgoingPairing?
    private var latestMacResults: [String: NWBrowser.Result] = [:]
    private var selectedMacID: String?
    private var autoConnectSuppressed = false
    private var isConnectingToMac = false
    private var audioSendingEnabled = false
    private var statusTimer: DispatchSourceTimer?
    private var packetWatchdogTimer: DispatchSourceTimer?
    private var currentMacName: String?
    private var currentTransport: PhoneMicTransportKind = .wifi
    private var lastErrorSummary: String?
    private var isInBackground = false
    private var lastPacketSentAt = Date.distantPast
    private var audioRecoveryAttempts = 0
    private var deviceDisplayName: String

    private struct PendingPairing {
        var request: PhoneMicPairingRequest
        var connection: NWConnection
    }

    private struct OutgoingPairing {
        var request: PhoneMicPendingPairing
        var connection: NWConnection
    }

    init() {
        selectedMacID = UserDefaults.standard.string(forKey: Self.selectedMacDefaultsKey)
        deviceDisplayName = Self.savedDeviceDisplayName()
        registerForRuntimeNotifications()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func start() async throws {
        do {
            try await requestMicrophonePermission()
            wantsStreaming = true
            try configureAudioSession()
            try configureNetworkListener()
            try configureAudioEngine()

            try engine.start()
            onEvent?(.started)
        } catch {
            reset(notify: false)
            throw error
        }
    }

    func startMacDiscovery() {
        queue.async { [weak self] in
            self?.startMacBrowser()
        }
    }

    func stop() {
        autoConnectSuppressed = true
        reset(notify: true)
    }

    func allowAutomaticReconnect() {
        queue.async { [weak self] in
            guard let self else { return }
            self.autoConnectSuppressed = false
            self.publishDiscoveredMacs()
        }
    }

    func pairWithMac(id macID: String) {
        queue.async { [weak self] in
            guard let self else { return }
            guard let result = self.latestMacResults[macID] else {
                self.onEvent?(.failed("Mac 已不在附近，请保持 Mac 端 PhoneMic 打开。"))
                return
            }

            let code = PhoneMicSecurity.randomPairingCode()
            let secret = PhoneMicSecurity.randomSecret()
            let request = PhoneMicPendingPairing(
                role: .iPhoneInitiated,
                macID: macID,
                macName: result.endpoint.phoneMicDisplayName,
                deviceID: self.deviceID,
                deviceName: self.currentDeviceDisplayName,
                pairingCode: code,
                sharedSecret: secret
            )
            self.connectForPairing(to: result.endpoint, request: request)
        }
    }

    func setDeviceDisplayName(_ name: String) {
        queue.async { [weak self] in
            guard let self else { return }
            let nextName = Self.normalizedDeviceDisplayName(name)
            guard nextName != self.deviceDisplayName else { return }
            self.deviceDisplayName = nextName
            UserDefaults.standard.set(nextName, forKey: Self.deviceDisplayNameDefaultsKey)
            self.refreshAdvertisedDeviceName(errorPrefix: "设备名称已保存，但 Bonjour 更新失败")
        }
    }

    func useAutomaticDeviceDisplayName() {
        queue.async { [weak self] in
            guard let self else { return }
            UserDefaults.standard.removeObject(forKey: Self.deviceDisplayNameDefaultsKey)
            let nextName = Self.defaultDeviceDisplayName()
            guard nextName != self.deviceDisplayName else {
                self.sendStatusToControlConnections()
                return
            }
            self.deviceDisplayName = nextName
            self.refreshAdvertisedDeviceName(errorPrefix: "设备名称已恢复自动，但 Bonjour 更新失败")
        }
    }

    private func refreshAdvertisedDeviceName(errorPrefix: String) {
        if listener != nil {
            listener?.cancel()
            listener = nil
            do {
                try configureNetworkListener()
            } catch {
                onEvent?(.failed("\(errorPrefix)：\(Self.describe(error))"))
            }
        }

        sendStatusToControlConnections()
    }

    func setInputMode(_ mode: MicrophoneInputMode) {
        queue.async { [weak self] in
            guard let self else { return }
            self.inputMode = mode
            guard self.wantsStreaming else { return }

            do {
                try self.restartCaptureForClient()
            } catch {
                self.onEvent?(.failed("输入切换失败：\(Self.describe(error))"))
            }
        }
    }

    func respondToPairing(approved: Bool) {
        queue.async { [weak self] in
            guard let self else { return }
            guard let pendingPairing = self.pendingPairing else {
                self.onEvent?(.failed("配对请求已失效，请在 Mac 上重新点击配对。"))
                return
            }
            self.pendingPairing = nil

            if approved {
                self.onEvent?(.pairingResponding(pendingPairing.request.macName))
                self.saveTrustedPeer(
                    PhoneMicTrustedPeer(
                        id: pendingPairing.request.macID,
                        name: pendingPairing.request.macName,
                        sharedSecret: pendingPairing.request.sharedSecret
                    )
                )
                let response = PhoneMicControlMessage(
                    kind: .pairAccepted,
                    protocolVersion: pendingPairing.request.protocolVersion,
                    deviceID: self.deviceID,
                    nonce: pendingPairing.request.pairingCode,
                    authentication: PhoneMicSecurity.authenticationCode(
                        secret: pendingPairing.request.sharedSecret,
                        nonce: pendingPairing.request.pairingCode,
                        protocolVersion: pendingPairing.request.protocolVersion
                    )
                )
                self.sendControl(response, on: pendingPairing.connection) { [weak self] error in
                    guard let self else { return }
                    if let error {
                        self.onEvent?(.failed("信任失败：\(error.localizedDescription)。请在 Mac 上重新点击配对。"))
                        pendingPairing.connection.cancel()
                        return
                    }
                    self.onEvent?(.pairingCompleted(pendingPairing.request.macName))
                }
            } else {
                let response = PhoneMicControlMessage(
                    kind: .pairRejected,
                    deviceID: self.deviceID,
                    reason: "User rejected pairing on iPhone."
                )
                self.sendControl(response, on: pendingPairing.connection) { [weak self] _ in
                    pendingPairing.connection.cancel()
                    self?.onEvent?(.pairingRejected(pendingPairing.request.macName))
                }
            }
        }
    }

    private func reset(notify: Bool) {
        sendStreamStopping(reason: "iPhone 已停止发送。")
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        connection?.cancel()
        controlConnection?.cancel()
        controlConnections.forEach { $0.cancel() }
        listener?.cancel()
        pendingPairing?.connection.cancel()
        outgoingPairing?.connection.cancel()
        pendingPairing = nil
        outgoingPairing = nil
        connection = nil
        controlConnection = nil
        sourceEndpoint = nil
        controlConnections.removeAll()
        listener = nil
        converter = nil
        desiredFormat = nil
        wantsStreaming = false
        isConnectingToMac = false
        audioSendingEnabled = false
        currentMacName = nil
        lastErrorSummary = nil
        stopStatusTimer()
        stopPacketWatchdog()
        sentPackets = 0
        sequence = 0
        lastPacketSentAt = Date.distantPast
        audioRecoveryAttempts = 0

        try? session.setActive(false)
        if notify {
            onEvent?(.stopped)
        }
    }

    private func registerForRuntimeNotifications() {
        let center = NotificationCenter.default
        center.addObserver(
            self,
            selector: #selector(handleAudioInterruption),
            name: AVAudioSession.interruptionNotification,
            object: session
        )
        center.addObserver(
            self,
            selector: #selector(handleMediaServicesReset),
            name: AVAudioSession.mediaServicesWereResetNotification,
            object: session
        )
        center.addObserver(
            self,
            selector: #selector(handleRouteChange),
            name: AVAudioSession.routeChangeNotification,
            object: session
        )
        center.addObserver(
            self,
            selector: #selector(handleAppDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(handleAppWillEnterForeground),
            name: UIApplication.willEnterForegroundNotification,
            object: nil
        )
    }

    @objc private func handleAudioInterruption(_ notification: Notification) {
        guard wantsStreaming,
              let typeValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue),
              type == .ended else {
            return
        }

        queue.async { [weak self] in
            self?.ensureEngineRunning(reason: "Audio interruption ended")
        }
    }

    @objc private func handleMediaServicesReset(_ notification: Notification) {
        guard wantsStreaming else { return }

        queue.async { [weak self] in
            guard let self else { return }
            do {
                try self.configureAudioSession()
                try self.configureAudioEngine()
                try self.startEngineIfNeeded()
                self.sendStatusToControlConnections()
            } catch {
                self.lastErrorSummary = "音频服务恢复失败：\(Self.describe(error))"
                self.onEvent?(.failed(self.lastErrorSummary ?? "音频服务恢复失败"))
            }
        }
    }

    @objc private func handleRouteChange(_ notification: Notification) {
        guard wantsStreaming else { return }

        queue.async { [weak self] in
            guard let self else { return }
            do {
                try self.preferSelectedMicrophone()
                try self.restartCaptureForClient()
                self.sendStatusToControlConnections()
            } catch {
                self.lastErrorSummary = "音频路由恢复失败：\(Self.describe(error))"
                self.onEvent?(.failed(self.lastErrorSummary ?? "音频路由恢复失败"))
            }
        }
    }

    @objc private func handleAppDidEnterBackground(_ notification: Notification) {
        guard wantsStreaming else { return }

        queue.async { [weak self] in
            self?.isInBackground = true
            self?.ensureEngineRunning(reason: "Entered background")
            self?.sendStatusToControlConnections()
        }
    }

    @objc private func handleAppWillEnterForeground(_ notification: Notification) {
        queue.async { [weak self] in
            guard let self else { return }
            self.isInBackground = false
            if self.wantsStreaming {
                self.ensureEngineRunning(reason: "Entered foreground")
                self.sendStatusToControlConnections()
            } else {
                self.autoConnectSuppressed = false
                self.publishDiscoveredMacs()
            }
        }
    }

    private func ensureEngineRunning(reason: String) {
        do {
            try configureAudioSession()
            try startEngineIfNeeded()
            sendStatusToControlConnections()
        } catch {
            lastErrorSummary = "\(reason)：\(Self.describe(error))"
            onEvent?(.failed(lastErrorSummary ?? reason))
        }
    }

    private func startEngineIfNeeded() throws {
        guard wantsStreaming, !engine.isRunning else { return }
        try engine.start()
        onEvent?(.started)
    }

    private func requestMicrophonePermission() async throws {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            return
        case .denied:
            throw MicrophoneStreamerError.microphonePermissionDenied
        case .undetermined:
            let granted = await withCheckedContinuation { continuation in
                AVAudioApplication.requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }

            guard granted else {
                throw MicrophoneStreamerError.microphonePermissionDenied
            }

        @unknown default:
            throw MicrophoneStreamerError.microphonePermissionDenied
        }
    }

    private func configureAudioSession() throws {
        var options: AVAudioSession.CategoryOptions = [.defaultToSpeaker, .mixWithOthers]
        if inputMode == .bluetooth {
            options.insert(.allowBluetoothHFP)
        }

        let sessionMode: AVAudioSession.Mode = inputMode == .bluetooth ? .voiceChat : .videoRecording
        try session.setCategory(.playAndRecord, mode: sessionMode, options: options)
        try? session.setPreferredSampleRate(PhoneMicAudio.sampleRate)
        try? session.setPreferredInputNumberOfChannels(Int(PhoneMicAudio.channels))
        try? session.setPreferredIOBufferDuration(PhoneMicAudio.frameDurationMilliseconds / 1_000)
        try session.setActive(true)
        try preferSelectedMicrophone()
    }

    private func preferSelectedMicrophone() throws {
        let availableInputs = session.availableInputs ?? []
        let preferredInput: AVAudioSessionPortDescription?

        switch inputMode {
        case .builtIn:
            preferredInput = availableInputs.first(where: { $0.portType == .builtInMic })
        case .bluetooth:
            preferredInput = availableInputs.first(where: { $0.portType == .bluetoothHFP })
                ?? availableInputs.first(where: { $0.portType == .builtInMic })
        }

        guard let preferredInput else {
            return
        }

        try session.setPreferredInput(preferredInput)
    }

    private func configureNetworkListener() throws {
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true

        guard let port = NWEndpoint.Port(rawValue: PhoneMicAudio.audioPort) else {
            throw MicrophoneStreamerError.cannotCreateAudioFormat
        }
        let listener = try NWListener(using: parameters, on: port)
        listener.service = NWListener.Service(
            name: currentDeviceDisplayName,
            type: PhoneMicAudio.bonjourServiceType
        )

        listener.newConnectionHandler = { [weak self] newConnection in
            self?.queue.async {
                self?.accept(newConnection)
            }
        }

        listener.stateUpdateHandler = { [weak self] state in
            if case .failed(let error) = state {
                self?.onEvent?(.failed("Bonjour 广播失败：\(error.localizedDescription)"))
            }
        }

        listener.start(queue: queue)
        self.listener = listener
    }

    private func startMacBrowser() {
        macBrowser?.cancel()

        let descriptor = NWBrowser.Descriptor.bonjour(type: PhoneMicAudio.macReceiverBonjourServiceType, domain: nil)
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true

        let browser = NWBrowser(for: descriptor, using: parameters)
        macBrowser = browser
        browser.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            if case .failed(let error) = state {
                self.onEvent?(.failed("Mac 发现失败：\(error.localizedDescription)"))
                self.queue.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                    self?.startMacBrowser()
                }
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            self.latestMacResults = Dictionary(uniqueKeysWithValues: results.map {
                ($0.endpoint.phoneMicStableID, $0)
            })
            self.publishDiscoveredMacs()
        }
        browser.start(queue: queue)
    }

    private func publishDiscoveredMacs() {
        let peers = trustedPeers()
        let macs = latestMacResults.map { id, result in
            PhoneMicDiscoveredMac(
                id: id,
                name: result.endpoint.phoneMicDisplayName,
                isPaired: peers[id] != nil || (peers.count == 1 && latestMacResults.count == 1),
                features: ["receiver", "source-connect"]
            )
        }
        .sorted { lhs, rhs in
            if lhs.isPaired != rhs.isPaired { return lhs.isPaired && !rhs.isPaired }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
        onEvent?(.macsChanged(macs))
    }

    private func preferredPairedMacResult() -> NWBrowser.Result? {
        let peers = trustedPeers()
        if let selectedMacID,
           peers[selectedMacID] != nil,
           let result = latestMacResults[selectedMacID] {
            return result
        }

        if peers.count == 1,
           latestMacResults.count == 1,
           let discovered = latestMacResults.first,
           peers[discovered.key] == nil,
           let oldPeer = peers.values.first {
            saveTrustedPeer(
                PhoneMicTrustedPeer(
                    id: discovered.key,
                    name: discovered.value.endpoint.phoneMicDisplayName,
                    sharedSecret: oldPeer.sharedSecret
                )
            )
            selectedMacID = discovered.key
            UserDefaults.standard.set(discovered.key, forKey: Self.selectedMacDefaultsKey)
            return discovered.value
        }

        let pairedResults = latestMacResults
            .filter { peers[$0.key] != nil }
            .sorted { lhs, rhs in
                lhs.value.endpoint.phoneMicDisplayName.localizedCaseInsensitiveCompare(
                    rhs.value.endpoint.phoneMicDisplayName
                ) == .orderedAscending
            }
        guard let first = pairedResults.first else { return nil }
        selectedMacID = first.key
        UserDefaults.standard.set(first.key, forKey: Self.selectedMacDefaultsKey)
        return first.value
    }

    private func connectToMac(_ result: NWBrowser.Result) {
        let macID = result.endpoint.phoneMicStableID
        connectToMacEndpoint(result.endpoint, macID: macID, displayName: result.endpoint.phoneMicDisplayName)
    }

    private func connectToMacEndpoint(_ endpoint: NWEndpoint, macID: String, displayName: String) {
        guard !isConnectingToMac else { return }
        guard trustedPeers()[macID] != nil else { return }

        listener?.cancel()
        listener = nil
        sourceEndpoint = endpoint
        isConnectingToMac = true
        audioSendingEnabled = false
        currentTransport = .wifi
        currentMacName = displayName

        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        let connection = NWConnection(to: endpoint, using: parameters)
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.sendSourceHello(on: connection, macID: macID)
                self.receiveMacControlResponse(on: connection, purpose: .source(macID: macID))
            case .failed(let error):
                self.isConnectingToMac = false
                self.audioSendingEnabled = false
                self.connection = nil
                self.lastErrorSummary = "连接 Mac 失败：\(error.localizedDescription)"
                self.onEvent?(.failed(self.lastErrorSummary ?? "连接 Mac 失败"))
            case .cancelled:
                self.isConnectingToMac = false
                if self.connection === connection {
                    self.audioSendingEnabled = false
                    self.connection = nil
                    self.currentMacName = nil
                    self.onEvent?(.clientDisconnected)
                    self.sendStatusToControlConnections()
                }
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private enum MacConnectionPurpose {
        case source(macID: String)
        case control(macID: String)
        case pair(PhoneMicPendingPairing)
    }

    private func connectForPairing(to endpoint: NWEndpoint, request: PhoneMicPendingPairing) {
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        let connection = NWConnection(to: endpoint, using: parameters)
        outgoingPairing = OutgoingPairing(request: request, connection: connection)
        onEvent?(.pairingStarted(request))

        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                let message = PhoneMicControlMessage(
                    kind: .pairRequest,
                    macID: request.macID,
                    macName: request.macName,
                    deviceID: request.deviceID,
                    deviceName: request.deviceName,
                    pairingCode: request.pairingCode,
                    sharedSecret: request.sharedSecret
                )
                self.sendControl(message, on: connection)
                self.receiveMacControlResponse(on: connection, purpose: .pair(request))
            case .failed(let error):
                self.outgoingPairing = nil
                self.onEvent?(.failed("配对连接失败：\(error.localizedDescription)"))
            case .cancelled:
                if self.outgoingPairing?.connection === connection {
                    self.outgoingPairing = nil
                }
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func sendSourceHello(on connection: NWConnection, macID: String) {
        guard let peer = trustedPeers()[macID] else {
            connection.cancel()
            return
        }
        let nonce = PhoneMicSecurity.randomNonce()
        let message = PhoneMicControlMessage(
            kind: .sourceHello,
            transport: .wifi,
            macID: macID,
            deviceID: deviceID,
            deviceName: currentDeviceDisplayName,
            nonce: nonce,
            authentication: PhoneMicSecurity.authenticationCode(secret: peer.sharedSecret, nonce: nonce)
        )
        sendControl(message, on: connection)
    }

    private func receiveMacControlResponse(on connection: NWConnection, purpose: MacConnectionPurpose, buffer: Data = Data()) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: PhoneMicAudio.controlMessageMaximumBytes) { [weak self] data, _, isComplete, error in
            guard let self else { return }

            var nextBuffer = buffer
            if let data, !data.isEmpty {
                nextBuffer.append(data)
                if let newlineRange = nextBuffer.firstRange(of: Data([0x0A])) {
                    let line = nextBuffer.subdata(in: 0..<newlineRange.lowerBound)
                    self.handleMacControlLine(line, connection: connection, purpose: purpose)
                    return
                }

                if nextBuffer.count > PhoneMicAudio.controlMessageMaximumBytes {
                    connection.cancel()
                    return
                }
            }

            guard error == nil, !isComplete else {
                connection.cancel()
                return
            }
            self.receiveMacControlResponse(on: connection, purpose: purpose, buffer: nextBuffer)
        }
    }

    private func handleMacControlLine(_ line: Data, connection: NWConnection, purpose: MacConnectionPurpose) {
        do {
            let message = try PhoneMicControlMessage.decodeLine(line)
            switch (purpose, message.kind) {
            case (.source(let macID), .sourceAccepted):
                guard let peer = trustedPeers()[macID],
                      let nonce = message.nonce,
                      let authentication = message.authentication,
                      PhoneMicSecurity.verifyAuthentication(
                          secret: peer.sharedSecret,
                          nonce: nonce,
                          authentication: authentication,
                          protocolVersion: message.protocolVersion
                      ) else {
                    connection.cancel()
                    onEvent?(.failed("Mac 鉴权失败，请重新配对。"))
                    return
                }
                isConnectingToMac = false
                audioSendingEnabled = true
                packetsAtLastClientConnect = sentPackets
                lastPacketSentAt = Date()
                audioRecoveryAttempts = 0
                currentMacName = message.macName ?? currentMacName
                currentTransport = .wifi
                selectedMacID = macID
                UserDefaults.standard.set(macID, forKey: Self.selectedMacDefaultsKey)
                do {
                    try restartCaptureForClient()
                    onEvent?(.clientConnected(currentMacName ?? "Mac"))
                    startOutgoingControlChannel(macID: macID)
                    startStatusTimer()
                    sendStatusToControlConnections()
                    startPacketWatchdog()
                } catch {
                    audioSendingEnabled = false
                    lastErrorSummary = "Mac 已连接，但麦克风采集重启失败：\(Self.describe(error))"
                    onEvent?(.failed(lastErrorSummary ?? "Mac 已连接，但麦克风采集重启失败"))
                }
            case (.control, .controlAccepted):
                controlConnection = connection
                startStatusTimer()
                sendStatusToControlConnections()
            case (.pair(let request), .pairAccepted):
                guard let nonce = message.nonce,
                      let authentication = message.authentication,
                      PhoneMicSecurity.verifyAuthentication(
                          secret: request.sharedSecret,
                          nonce: nonce,
                          authentication: authentication,
                          protocolVersion: message.protocolVersion
                      ) else {
                    connection.cancel()
                    onEvent?(.failed("Mac 信任响应验证失败，请重新配对。"))
                    return
                }
                let peerID = request.macID
                let peerName = message.macName ?? request.macName
                saveTrustedPeer(PhoneMicTrustedPeer(id: peerID, name: peerName, sharedSecret: request.sharedSecret))
                selectedMacID = peerID
                UserDefaults.standard.set(peerID, forKey: Self.selectedMacDefaultsKey)
                outgoingPairing = nil
                connection.cancel()
                publishDiscoveredMacs()
                onEvent?(.pairingCompleted(peerName))
            case (.pair(let request), .pairRejected):
                outgoingPairing = nil
                connection.cancel()
                onEvent?(.pairingRejected(request.macName))
            default:
                connection.cancel()
                onEvent?(.failed("收到非预期的 Mac 响应：\(message.kind.rawValue)"))
            }
        } catch {
            connection.cancel()
            onEvent?(.failed("Mac 响应无效：\(error.localizedDescription)"))
        }
    }

    private func startOutgoingControlChannel(macID: String) {
        guard let endpoint = sourceEndpoint,
              let peer = trustedPeers()[macID] else { return }

        controlConnection?.cancel()
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        let controlConnection = NWConnection(to: endpoint, using: parameters)
        self.controlConnection = controlConnection
        controlConnection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                let nonce = PhoneMicSecurity.randomNonce()
                let message = PhoneMicControlMessage(
                    kind: .controlHello,
                    transport: .wifi,
                    macID: macID,
                    deviceID: self.deviceID,
                    deviceName: self.currentDeviceDisplayName,
                    nonce: nonce,
                    authentication: PhoneMicSecurity.authenticationCode(secret: peer.sharedSecret, nonce: nonce)
                )
                self.sendControl(message, on: controlConnection)
                self.receiveMacControlResponse(on: controlConnection, purpose: .control(macID: macID))
            case .failed, .cancelled:
                if self.controlConnection === controlConnection {
                    self.controlConnection = nil
                }
            default:
                break
            }
        }
        controlConnection.start(queue: queue)
    }

    private func accept(_ newConnection: NWConnection) {
        newConnection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.receiveInitialControlMessage(on: newConnection)
            case .cancelled, .failed:
                if self.connection === newConnection {
                    self.audioSendingEnabled = false
                    self.connection = nil
                    self.currentMacName = nil
                    self.onEvent?(.clientDisconnected)
                    self.sendStatusToControlConnections()
                } else if self.pendingPairing?.connection === newConnection {
                    self.pendingPairing = nil
                    self.onEvent?(.failed("配对连接已关闭，请在 Mac 上重新点击配对。"))
                } else {
                    self.controlConnections.removeAll { $0 === newConnection }
                }
            default:
                break
            }
        }

        newConnection.start(queue: queue)
    }

    private func receiveInitialControlMessage(on connection: NWConnection, buffer: Data = Data()) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: PhoneMicAudio.controlMessageMaximumBytes) { [weak self] data, _, isComplete, error in
            guard let self else { return }

            var nextBuffer = buffer
            if let data, !data.isEmpty {
                nextBuffer.append(data)
                if let newlineRange = nextBuffer.firstRange(of: Data([0x0A])) {
                    let line = nextBuffer.subdata(in: 0..<newlineRange.lowerBound)
                    self.handleInitialControlLine(line, on: connection)
                    return
                }

                if nextBuffer.count > PhoneMicAudio.controlMessageMaximumBytes {
                    self.rejectStream(on: connection, reason: "Handshake too large.")
                    return
                }
            }

            guard error == nil, !isComplete else {
                if self.connection === connection {
                    self.audioSendingEnabled = false
                    self.connection = nil
                }
                self.onEvent?(.clientDisconnected)
                return
            }
            self.receiveInitialControlMessage(on: connection, buffer: nextBuffer)
        }
    }

    private func handleInitialControlLine(_ line: Data, on connection: NWConnection) {
        do {
            let message = try PhoneMicControlMessage.decodeLine(line)
            switch message.kind {
            case .pairRequest:
                guard let macID = message.macID,
                      let macName = message.macName,
                      let pairingCode = message.pairingCode,
                      let sharedSecret = message.sharedSecret else {
                    rejectStream(on: connection, reason: "Invalid pairing request.")
                    return
                }

                let request = PhoneMicPairingRequest(
                    macID: macID,
                    macName: macName,
                    pairingCode: pairingCode,
                    sharedSecret: sharedSecret,
                    protocolVersion: message.protocolVersion
                )
                pendingPairing = PendingPairing(request: request, connection: connection)
                onEvent?(.pairingRequested(request))
            case .streamHello:
                authenticateStream(message, on: connection)
            case .controlHello:
                authenticateControl(message, on: connection)
            default:
                rejectStream(on: connection, reason: "Unexpected handshake message.")
            }
        } catch {
            rejectStream(on: connection, reason: "Invalid handshake: \(error.localizedDescription)")
        }
    }

    private func authenticateStream(_ message: PhoneMicControlMessage, on connection: NWConnection) {
        guard let macID = message.macID,
              let nonce = message.nonce,
              let authentication = message.authentication else {
            rejectStream(on: connection, reason: "Missing authentication.")
            return
        }

        guard let peer = trustedPeers()[macID] else {
            rejectStream(on: connection, reason: "Mac is not paired.")
            return
        }

        guard PhoneMicSecurity.verifyAuthentication(
            secret: peer.sharedSecret,
            nonce: nonce,
            authentication: authentication,
            protocolVersion: message.protocolVersion
        ) else {
            rejectStream(on: connection, reason: "Authentication failed.")
            return
        }

        if self.connection !== connection {
            self.connection?.cancel()
            self.connection = connection
        }
        audioSendingEnabled = true
        packetsAtLastClientConnect = sentPackets
        lastPacketSentAt = Date()
        audioRecoveryAttempts = 0
        currentTransport = normalizedTransport(message.transport)
        currentMacName = peer.name

        let responseNonce = PhoneMicSecurity.randomNonce()
        sendControl(
            PhoneMicControlMessage(
                kind: .streamAccepted,
                protocolVersion: message.protocolVersion,
                transport: currentTransport,
                deviceID: deviceID,
                nonce: responseNonce,
                authentication: PhoneMicSecurity.authenticationCode(
                    secret: peer.sharedSecret,
                    nonce: responseNonce,
                    protocolVersion: message.protocolVersion
                )
            ),
            on: connection
        )

        do {
            try restartCaptureForClient()
            onEvent?(.clientConnected(peer.name))
            sendStatusToControlConnections()
            startPacketWatchdog()
        } catch {
            lastErrorSummary = "Mac 已连接，但麦克风采集重启失败：\(Self.describe(error))"
            onEvent?(.failed(lastErrorSummary ?? "Mac 已连接，但麦克风采集重启失败"))
        }
    }

    private func authenticateControl(_ message: PhoneMicControlMessage, on connection: NWConnection) {
        guard let macID = message.macID,
              let nonce = message.nonce,
              let authentication = message.authentication else {
            rejectStream(on: connection, reason: "Missing control authentication.")
            return
        }

        guard let peer = trustedPeers()[macID],
              PhoneMicSecurity.verifyAuthentication(
                  secret: peer.sharedSecret,
                  nonce: nonce,
                  authentication: authentication,
                  protocolVersion: message.protocolVersion
              ) else {
            rejectStream(on: connection, reason: "Control authentication failed.")
            return
        }

        currentTransport = normalizedTransport(message.transport)
        currentMacName = peer.name
        controlConnections.removeAll { $0 === connection }
        controlConnections.append(connection)

        let responseNonce = PhoneMicSecurity.randomNonce()
        sendControl(
            PhoneMicControlMessage(
                kind: .controlAccepted,
                protocolVersion: message.protocolVersion,
                transport: currentTransport,
                deviceID: deviceID,
                nonce: responseNonce,
                authentication: PhoneMicSecurity.authenticationCode(
                    secret: peer.sharedSecret,
                    nonce: responseNonce,
                    protocolVersion: message.protocolVersion
                )
            ),
            on: connection
        )
        startStatusTimer()
        sendStatusToControlConnections()
    }

    private func rejectStream(on connection: NWConnection, reason: String) {
        sendControl(
            PhoneMicControlMessage(kind: .streamRejected, deviceID: deviceID, reason: reason),
            on: connection
        )
        connection.cancel()
    }

    private func sendControl(
        _ message: PhoneMicControlMessage,
        on connection: NWConnection,
        completion: ((Error?) -> Void)? = nil
    ) {
        do {
            connection.send(content: try message.encodedLine(), completion: .contentProcessed { error in
                completion?(error)
            })
        } catch {
            onEvent?(.failed("控制消息发送失败：\(error.localizedDescription)"))
            connection.cancel()
            completion?(error)
        }
    }

    private func restartCaptureForClient() throws {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        try configureAudioSession()
        try configureAudioEngine()
        try engine.start()
    }

    private func startPacketWatchdog() {
        packetWatchdogTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(1200), repeating: .milliseconds(800), leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in
            self?.recoverIfAudioPacketsStalled()
        }
        packetWatchdogTimer = timer
        timer.resume()
    }

    private func stopPacketWatchdog() {
        packetWatchdogTimer?.cancel()
        packetWatchdogTimer = nil
    }

    private func recoverIfAudioPacketsStalled() {
        guard wantsStreaming, audioSendingEnabled, connection != nil else { return }
        guard Date().timeIntervalSince(lastPacketSentAt) > 1.5 else { return }

        audioRecoveryAttempts += 1
        lastErrorSummary = "音频发送中断，正在自动恢复。"
        onEvent?(.statusChanged(makeStatus(phase: .advertising)))
        sendStatusToControlConnections()

        if audioRecoveryAttempts <= 1 {
            do {
                try restartCaptureForClient()
                lastPacketSentAt = Date()
            } catch {
                lastErrorSummary = "音频采集恢复失败：\(Self.describe(error))"
                onEvent?(.failed(lastErrorSummary ?? "音频采集恢复失败"))
            }
            return
        }

        connection?.cancel()
        connection = nil
        audioSendingEnabled = false
        isConnectingToMac = false
        lastErrorSummary = "主动连接音频不稳定，已切换到兼容连接。"
        do {
            try configureNetworkListener()
            sendStatusToControlConnections()
        } catch {
            lastErrorSummary = "兼容连接启动失败：\(Self.describe(error))"
            onEvent?(.failed(lastErrorSummary ?? "兼容连接启动失败"))
        }
    }

    private func configureAudioEngine() throws {
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        engine.mainMixerNode.outputVolume = 0

        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: PhoneMicAudio.sampleRate,
            channels: AVAudioChannelCount(PhoneMicAudio.channels),
            interleaved: false
        ) else {
            throw MicrophoneStreamerError.cannotCreateAudioFormat
        }

        desiredFormat = outputFormat
        converter = AVAudioConverter(from: inputFormat, to: outputFormat)

        input.removeTap(onBus: 0)
        engine.disconnectNodeOutput(input)
        engine.connect(input, to: engine.mainMixerNode, format: inputFormat)
        input.installTap(
            onBus: 0,
            bufferSize: AVAudioFrameCount(PhoneMicAudio.framesPerPacket),
            format: inputFormat
        ) { [weak self] buffer, _ in
            self?.process(buffer)
        }

        engine.prepare()
    }

    private static func describe(_ error: Error) -> String {
        let nsError = error as NSError
        return "\(nsError.localizedDescription) (\(nsError.domain) \(nsError.code))"
    }

    private func process(_ inputBuffer: AVAudioPCMBuffer) {
        guard let outputFormat = desiredFormat else { return }

        let convertedFrameCapacity = AVAudioFrameCount(
            ceil(Double(inputBuffer.frameLength) * outputFormat.sampleRate / inputBuffer.format.sampleRate)
        ) + 16

        guard let convertedBuffer = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: convertedFrameCapacity
        ) else {
            return
        }

        var conversionError: NSError?
        var didProvideInput = false

        if let converter {
            converter.convert(to: convertedBuffer, error: &conversionError) { _, status in
                if didProvideInput {
                    status.pointee = .noDataNow
                    return nil
                }

                didProvideInput = true
                status.pointee = .haveData
                return inputBuffer
            }
        } else {
            convertedBuffer.frameLength = inputBuffer.frameLength
            if let source = inputBuffer.floatChannelData?[0],
               let target = convertedBuffer.floatChannelData?[0] {
                for index in 0..<Int(inputBuffer.frameLength) {
                    target[index] = source[index]
                }
            }
        }

        guard conversionError == nil else {
            lastErrorSummary = "音频转换失败：\(conversionError!.localizedDescription)"
            onEvent?(.failed(lastErrorSummary ?? "音频转换失败"))
            return
        }

        guard let channel = convertedBuffer.floatChannelData?[0] else { return }
        let frameLength = Int(convertedBuffer.frameLength)
        guard frameLength > 0 else { return }

        let samples = Array(UnsafeBufferPointer(start: channel, count: frameLength))
        let packet = AudioPacket(sequence: sequence, transport: currentTransport, samples: samples)
        sequence += 1

        send(packet.encoded())
    }

    private func send(_ data: Data) {
        queue.async { [weak self] in
            guard let self, self.audioSendingEnabled, let connection = self.connection else { return }

            connection.send(content: data, completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                if let error {
                    self.lastErrorSummary = "发送失败：\(error.localizedDescription)"
                    self.onEvent?(.failed(self.lastErrorSummary ?? "发送失败"))
                    return
                }

                self.sentPackets += 1
                self.lastPacketSentAt = Date()
                self.audioRecoveryAttempts = 0
                self.lastErrorSummary = nil
                if self.sentPackets % 20 == 0 {
                    self.onEvent?(.packetSent(self.sentPackets))
                    self.sendStatusToControlConnections()
                }
            })
        }
    }

    private func startStatusTimer() {
        guard statusTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .seconds(1), leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in
            self?.sendStatusToControlConnections()
        }
        statusTimer = timer
        timer.resume()
    }

    private func stopStatusTimer() {
        statusTimer?.cancel()
        statusTimer = nil
    }

    private func sendStatusToControlConnections() {
        let status = makeStatus()
        onEvent?(.statusChanged(status))

        let message = PhoneMicControlMessage(
            kind: .statusUpdate,
            transport: currentTransport,
            deviceID: deviceID,
            status: status
        )

        do {
            let data = try message.encodedLine()
            controlConnection?.send(content: data, completion: .contentProcessed { [weak self] error in
                guard error != nil else { return }
                self?.queue.async {
                    self?.controlConnection = nil
                }
            })
            for connection in controlConnections {
                connection.send(content: data, completion: .contentProcessed { [weak self, weak connection] error in
                    guard let self, let connection, error != nil else { return }
                    self.queue.async {
                        self.controlConnections.removeAll { $0 === connection }
                    }
                })
            }
        } catch {
            lastErrorSummary = "状态同步失败：\(error.localizedDescription)"
        }
    }

    private func sendStreamStopping(reason: String) {
        let message = PhoneMicControlMessage(
            kind: .streamStopping,
            transport: currentTransport,
            deviceID: deviceID,
            reason: reason,
            status: makeStatus(phase: .stopping)
        )
        guard let data = try? message.encodedLine() else { return }
        controlConnection?.send(content: data, completion: .contentProcessed { _ in })
        controlConnections.forEach { connection in
            connection.send(content: data, completion: .contentProcessed { _ in })
        }
    }

    private func makeStatus(phase overridePhase: PhoneMicStreamingPhase? = nil) -> PhoneMicDeviceStatus {
        let phase: PhoneMicStreamingPhase
        if let overridePhase {
            phase = overridePhase
        } else if !wantsStreaming {
            phase = .idle
        } else if audioSendingEnabled && connection != nil && Date().timeIntervalSince(lastPacketSentAt) <= 1.5 {
            phase = .sending
        } else {
            phase = .advertising
        }

        return PhoneMicDeviceStatus(
            deviceID: deviceID,
            deviceName: currentDeviceDisplayName,
            phase: phase,
            isCapturing: wantsStreaming && engine.isRunning,
            isSendingAudio: wantsStreaming && audioSendingEnabled && connection != nil && Date().timeIntervalSince(lastPacketSentAt) <= 1.5,
            inputName: inputMode.displayName,
            connectedMacName: currentMacName,
            packetCount: sentPackets,
            transport: currentTransport,
            isInBackground: isInBackground,
            errorSummary: lastErrorSummary
        )
    }

    private func normalizedTransport(_ transport: PhoneMicTransportKind) -> PhoneMicTransportKind {
        transport == .tcp ? .wifi : transport
    }

    private var deviceID: String {
        UIDevice.current.identifierForVendor?.uuidString ?? currentDeviceDisplayName
    }

    private static let trustedPeersDefaultsKey = "PhoneMic.trustedMacs"
    private static let selectedMacDefaultsKey = "PhoneMic.selectedMacID"
    private static let deviceDisplayNameDefaultsKey = "PhoneMic.deviceDisplayName"

    static func savedDeviceDisplayName() -> String {
        if let savedName = UserDefaults.standard.string(forKey: deviceDisplayNameDefaultsKey) {
            return normalizedDeviceDisplayName(savedName)
        }
        return defaultDeviceDisplayName()
    }

    static func hasCustomDeviceDisplayName() -> Bool {
        UserDefaults.standard.string(forKey: deviceDisplayNameDefaultsKey) != nil
    }

    static func systemDeviceDisplayName() -> String {
        defaultDeviceDisplayName()
    }

    static func rawSystemDeviceDisplayName() -> String {
        let systemName = UIDevice.current.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return systemName.isEmpty ? UIDevice.current.model : systemName
    }

    static func canReadUserAssignedDeviceName() -> Bool {
        let systemName = rawSystemDeviceDisplayName()
        return systemName != UIDevice.current.model && systemName != deviceModelDisplayName()
    }

    static func deviceModelDisplayName() -> String {
        DeviceModelName.current
    }

    private var currentDeviceDisplayName: String {
        Self.normalizedDeviceDisplayName(deviceDisplayName)
    }

    private static func normalizedDeviceDisplayName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return defaultDeviceDisplayName()
        }
        return String(trimmed.prefix(48))
    }

    private static func defaultDeviceDisplayName() -> String {
        let systemName = UIDevice.current.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if systemName.isEmpty || systemName == UIDevice.current.model {
            return deviceModelDisplayName()
        }
        return systemName
    }

    private enum DeviceModelName {
        static var current: String {
            let identifier = hardwareIdentifier()
            return marketingNames[identifier] ?? identifier
        }

        private static func hardwareIdentifier() -> String {
            var systemInfo = utsname()
            uname(&systemInfo)
            let mirror = Mirror(reflecting: systemInfo.machine)
            let identifier = mirror.children.reduce(into: "") { result, element in
                guard let value = element.value as? Int8, value != 0 else { return }
                result.append(String(UnicodeScalar(UInt8(value))))
            }
            return identifier.isEmpty ? UIDevice.current.model : identifier
        }

        private static let marketingNames: [String: String] = [
            "iPhone13,1": "iPhone 12 mini",
            "iPhone13,2": "iPhone 12",
            "iPhone13,3": "iPhone 12 Pro",
            "iPhone13,4": "iPhone 12 Pro Max",
            "iPhone14,4": "iPhone 13 mini",
            "iPhone14,5": "iPhone 13",
            "iPhone14,2": "iPhone 13 Pro",
            "iPhone14,3": "iPhone 13 Pro Max",
            "iPhone14,6": "iPhone SE (3rd generation)",
            "iPhone14,7": "iPhone 14",
            "iPhone14,8": "iPhone 14 Plus",
            "iPhone15,2": "iPhone 14 Pro",
            "iPhone15,3": "iPhone 14 Pro Max",
            "iPhone15,4": "iPhone 15",
            "iPhone15,5": "iPhone 15 Plus",
            "iPhone16,1": "iPhone 15 Pro",
            "iPhone16,2": "iPhone 15 Pro Max",
            "iPhone17,3": "iPhone 16",
            "iPhone17,4": "iPhone 16 Plus",
            "iPhone17,1": "iPhone 16 Pro",
            "iPhone17,2": "iPhone 16 Pro Max",
            "iPhone17,5": "iPhone 16e",
            "iPhone18,3": "iPhone 17",
            "iPhone18,1": "iPhone 17 Pro",
            "iPhone18,2": "iPhone 17 Pro Max",
            "iPhone18,4": "iPhone Air",
        ]
    }

    private func trustedPeers() -> [String: PhoneMicTrustedPeer] {
        trustedPeerStore.load()
    }

    private func saveTrustedPeer(_ peer: PhoneMicTrustedPeer) {
        var peers = trustedPeers()
        peers[peer.id] = peer
        try? trustedPeerStore.save(peers)
    }

    func forgetTrustedMacs() {
        queue.async { [weak self] in
            self?.trustedPeerStore.removeAll()
            UserDefaults.standard.removeObject(forKey: Self.selectedMacDefaultsKey)
            self?.selectedMacID = nil
            self?.connection?.cancel()
            self?.controlConnection?.cancel()
            self?.controlConnections.forEach { $0.cancel() }
            self?.connection = nil
            self?.controlConnection = nil
            self?.audioSendingEnabled = false
            self?.controlConnections.removeAll()
            self?.currentMacName = nil
            self?.sendStatusToControlConnections()
            self?.publishDiscoveredMacs()
        }
    }
}

enum MicrophoneStreamerError: LocalizedError {
    case microphonePermissionDenied
    case cannotCreateAudioFormat

    var errorDescription: String? {
        switch self {
        case .microphonePermissionDenied:
            "麦克风权限未开启。请在设置 > 隐私与安全性 > 麦克风中允许 PhoneMic。"
        case .cannotCreateAudioFormat:
            "无法创建 48 kHz 单声道 Float32 音频格式。"
        }
    }
}

private extension NWEndpoint {
    var phoneMicDisplayName: String {
        switch self {
        case .service(let name, _, _, _):
            return name
        case .hostPort(let host, let port):
            return "\(host):\(port)"
        default:
            return "Mac"
        }
    }

    var phoneMicStableID: String {
        switch self {
        case .service(let name, let type, let domain, _):
            return "\(name)|\(type)|\(domain)"
        case .hostPort(let host, let port):
            return "\(host):\(port)"
        default:
            return String(describing: self)
        }
    }
}
