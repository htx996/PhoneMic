import Foundation
import Network
import PhoneMicCore

struct PhoneMicDiscoveredDevice: Identifiable, Equatable {
    var id: String
    var name: String
    var transport: PhoneMicTransportKind = .wifi
    var lastSeenAt: Date = Date()
}

final class MacAudioReceiver {
    enum Event {
        case devicesChanged([PhoneMicDiscoveredDevice])
        case discovered(String)
        case connected(String, PhoneMicTransportKind)
        case disconnected(String)
        case packet(AudioPacket)
        case transportStats(PhoneMicTransportStats)
        case deviceStatus(PhoneMicDeviceStatus)
        case pairingCode(String, String)
        case pairingRequested(PhoneMicPendingPairing)
        case pairingSucceeded(PhoneMicDiscoveredDevice, String)
        case pairingFailed(String)
        case streamStopping(String)
        case error(String)
    }

    var onEvent: ((Event) -> Void)?
    var autoReconnect = true
    var streamTimeoutSeconds: TimeInterval = 2.5

    enum TransportPolicy {
        case wifiOnly
        case usbOnly

        func allows(_ transport: PhoneMicTransportKind) -> Bool {
            switch self {
            case .wifiOnly:
                return transport != .usb
            case .usbOnly:
                return transport == .usb
            }
        }
    }

    private enum ConnectionPurpose {
        case stream(deviceID: String, secret: String, transport: PhoneMicTransportKind)
        case control(deviceID: String, secret: String, transport: PhoneMicTransportKind)
        case pair(device: PhoneMicDiscoveredDevice, macID: String, macName: String, code: String, secret: String)

        var isControl: Bool {
            if case .control = self { return true }
            return false
        }

        var transportKind: PhoneMicTransportKind {
            switch self {
            case .stream(_, _, let transport), .control(_, _, let transport):
                return transport
            case .pair:
                return .wifi
            }
        }
    }

    private let queue = DispatchQueue(label: "PhoneMic.MacAudioReceiver")
    private let jitterBuffer: JitterBuffer
    private var browser: NWBrowser?
    private var receiverListener: NWListener?
    private var connection: NWConnection?
    private var controlConnection: NWConnection?
    private var receiveBuffer = Data()
    private var controlBuffer = Data()
    private var latestResults: [String: NWBrowser.Result] = [:]
    private var currentDeviceName: String?
    private var preferredDeviceID: String?
    private var trustedSecrets: [String: String] = [:]
    private var shouldRun = false
    private var receivedByteLogCount = 0
    private var stats = PhoneMicTransportStats()
    private var lastStatsEventAt = Date.distantPast
    private var lastPacketEventAt = Date.distantPast
    private var suppressNextCancelledEvent = false
    private var watchdogTimer: DispatchSourceTimer?
    private var streamStartedAt: Date?
    private var latestStatusAt: Date?
    private var currentTransport: PhoneMicTransportKind = .wifi
    private var transportPolicy: TransportPolicy = .wifiOnly
    private var pendingIncomingPairings: [String: PendingIncomingPairing] = [:]

    private struct PendingIncomingPairing {
        var request: PhoneMicPendingPairing
        var connection: NWConnection
    }

    init(jitterBuffer: JitterBuffer) {
        self.jitterBuffer = jitterBuffer
    }

    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            self.debug("receiver start")
            self.shouldRun = true
            if self.transportPolicy.allows(.wifi) {
                self.startBrowser()
            }
        }
    }

    func setTransportPolicy(_ policy: TransportPolicy) {
        queue.async { [weak self] in
            guard let self else { return }
            self.transportPolicy = policy
            if !policy.allows(.wifi) {
                self.browser?.cancel()
                self.receiverListener?.cancel()
                self.browser = nil
                self.receiverListener = nil
            }
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.shouldRun = false
            self?.browser?.cancel()
            self?.receiverListener?.cancel()
            self?.connection?.cancel()
            self?.controlConnection?.cancel()
            self?.stopStreamWatchdog()
            self?.browser = nil
            self?.receiverListener = nil
            self?.connection = nil
            self?.controlConnection = nil
            self?.receiveBuffer.removeAll()
            self?.controlBuffer.removeAll()
            self?.pendingIncomingPairings.removeAll()
        }
    }

    func disconnect() {
        queue.async { [weak self] in
            self?.connection?.cancel()
            self?.controlConnection?.cancel()
            self?.connection = nil
            self?.controlConnection = nil
            self?.stopStreamWatchdog()
            self?.jitterBuffer.clear()
            self?.onEvent?(.disconnected("已手动断开。"))
        }
    }

    func restartDiscovery() {
        queue.async { [weak self] in
            self?.connection?.cancel()
            self?.controlConnection?.cancel()
            self?.connection = nil
            self?.controlConnection = nil
            self?.stopStreamWatchdog()
            if self?.transportPolicy.allows(.wifi) == true {
                self?.startBrowser()
            }
        }
    }

    func connectViaUSBProxy(deviceID: String?, deviceName: String?) {
        queue.async { [weak self] in
            guard let self else { return }
            self.shouldRun = true
            self.browser?.cancel()
            self.receiverListener?.cancel()
            self.browser = nil
            self.receiverListener = nil

            guard let port = NWEndpoint.Port(rawValue: PhoneMicAudio.audioPort) else {
                self.onEvent?(.error("PhoneMic USB 音频端口无效。"))
                return
            }
            guard let trustedDevice = self.trustedDeviceForUSB(preferredDeviceID: deviceID) else {
                self.onEvent?(.error("有线模式需要先通过无线配对一次。"))
                return
            }

            let name = deviceName ?? trustedDevice.deviceID
            self.currentDeviceName = name
            self.onEvent?(.discovered(name))
            self.connect(
                to: .hostPort(host: .ipv4(IPv4Address("127.0.0.1")!), port: port),
                name: name,
                purpose: .stream(deviceID: trustedDevice.deviceID, secret: trustedDevice.secret, transport: .usb)
            )
        }
    }

    func configureTrustedDevices(preferredDeviceID: String?, trustedSecrets: [String: String]) {
        queue.async { [weak self] in
            guard let self else { return }
            self.preferredDeviceID = preferredDeviceID
            self.trustedSecrets = trustedSecrets
            self.connection?.cancel()
            self.controlConnection?.cancel()
            self.connection = nil
            self.controlConnection = nil
            self.stopStreamWatchdog()
            if self.shouldRun, self.transportPolicy.allows(.wifi) {
                self.startBrowser()
            }
        }
    }

    func beginPairing(deviceID: String, macID: String, macName: String, code: String, secret: String) {
        queue.async { [weak self] in
            guard let self else { return }
            guard let result = self.latestResults[deviceID] else {
                self.onEvent?(.pairingFailed("iPhone 已不在附近或已停止广播。"))
                return
            }

            let device = PhoneMicDiscoveredDevice(id: deviceID, name: result.endpoint.phoneMicDisplayName)
            self.onEvent?(.pairingCode(code, device.name))
            self.connect(
                to: result.endpoint,
                name: device.name,
                purpose: .pair(device: device, macID: macID, macName: macName, code: code, secret: secret)
            )
        }
    }

    func respondToIncomingPairing(_ request: PhoneMicPendingPairing, approved: Bool) {
        queue.async { [weak self] in
            guard let self else { return }
            guard let pendingPairing = self.pendingIncomingPairings.removeValue(forKey: request.id) else {
                self.onEvent?(.pairingFailed("配对请求已失效，请在 iPhone 上重新发起。"))
                return
            }

            let connection = pendingPairing.connection
            if approved {
                let response = PhoneMicControlMessage(
                    kind: .pairAccepted,
                    protocolVersion: request.protocolVersion,
                    macID: MacIdentity.id,
                    macName: MacIdentity.name,
                    deviceID: request.deviceID,
                    deviceName: request.deviceName,
                    nonce: request.pairingCode,
                    authentication: PhoneMicSecurity.authenticationCode(
                        secret: request.sharedSecret,
                        nonce: request.pairingCode,
                        protocolVersion: request.protocolVersion
                    )
                )
                self.sendControl(response, on: connection) { [weak self] error in
                    guard let self else { return }
                    if let error {
                        self.onEvent?(.pairingFailed("信任响应发送失败：\(error.localizedDescription)"))
                        connection.cancel()
                        return
                    }

                    let device = PhoneMicDiscoveredDevice(
                        id: request.deviceID,
                        name: request.deviceName,
                        transport: .wifi
                    )
                    self.onEvent?(.pairingSucceeded(device, request.sharedSecret))
                    connection.cancel()
                }
            } else {
                let response = PhoneMicControlMessage(
                    kind: .pairRejected,
                    protocolVersion: request.protocolVersion,
                    macID: MacIdentity.id,
                    macName: MacIdentity.name,
                    deviceID: request.deviceID,
                    deviceName: request.deviceName,
                    reason: "User rejected pairing on Mac."
                )
                self.sendControl(response, on: connection) { _ in
                    connection.cancel()
                }
            }
        }
    }

    private func startReceiverListener() {
        receiverListener?.cancel()

        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        guard let port = NWEndpoint.Port(rawValue: PhoneMicAudio.audioPort) else {
            onEvent?(.error("PhoneMic 接收端端口无效。"))
            return
        }

        do {
            let listener = try NWListener(using: parameters, on: port)
            listener.service = NWListener.Service(
                name: MacIdentity.name,
                type: PhoneMicAudio.macReceiverBonjourServiceType
            )
            listener.newConnectionHandler = { [weak self] newConnection in
                self?.queue.async {
                    self?.acceptIncoming(newConnection)
                }
            }
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                self.debug("receiver listener state: \(state)")
                if case .failed(let error) = state {
                    self.onEvent?(.error("Mac 接收端广播失败：\(error.localizedDescription)"))
                    self.queue.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                        guard let self, self.shouldRun else { return }
                        self.startReceiverListener()
                    }
                }
            }
            receiverListener = listener
            listener.start(queue: queue)
        } catch {
            onEvent?(.error("Mac 接收端无法启动：\(error.localizedDescription)"))
        }
    }

    private func startBrowser() {
        browser?.cancel()
        debug("starting Bonjour browser")

        let descriptor = NWBrowser.Descriptor.bonjour(type: PhoneMicAudio.bonjourServiceType, domain: nil)
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true

        let browser = NWBrowser(for: descriptor, using: parameters)
        self.browser = browser

        browser.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            self.debug("browser state: \(state)")
            if case .failed(let error) = state {
                self.onEvent?(.error("Bonjour 浏览失败：\(error.localizedDescription)"))
                self.scheduleDiscoveryRetry()
            }
        }

            browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self, self.shouldRun else { return }
            guard self.transportPolicy.allows(.wifi) else {
                self.browser?.cancel()
                self.browser = nil
                return
            }
            self.debug("browser results: \(results.count)")
            let devices = self.devices(from: results)
            self.latestResults = Dictionary(uniqueKeysWithValues: results.map {
                ($0.endpoint.phoneMicStableID, $0)
            })
            self.onEvent?(.devicesChanged(devices))
            guard self.connection == nil else { return }
            guard let result = self.preferredResult(from: results) else { return }

            let deviceID = result.endpoint.phoneMicStableID
            guard let secret = self.trustedSecrets[deviceID] ?? (self.trustedSecrets.count == 1 ? self.trustedSecrets.values.first : nil) else { return }
            let name = result.endpoint.phoneMicDisplayName
            self.currentDeviceName = name
            self.onEvent?(.discovered(name))
            self.connect(to: result.endpoint, name: name, purpose: .stream(deviceID: deviceID, secret: secret, transport: .wifi))
        }

        browser.start(queue: queue)
    }

    private func acceptIncoming(_ newConnection: NWConnection) {
        newConnection.stateUpdateHandler = { [weak self, weak newConnection] state in
            guard let self, let newConnection else { return }
            switch state {
            case .ready:
                self.receiveIncomingInitialControlMessage(on: newConnection)
            case .failed(let error):
                self.pendingIncomingPairings = self.pendingIncomingPairings.filter { $0.value.connection !== newConnection }
                if self.connection === newConnection {
                    self.connection = nil
                    self.stopStreamWatchdog()
                    self.jitterBuffer.clear()
                    self.onEvent?(.disconnected("iPhone 连接失败：\(error.localizedDescription)"))
                } else if self.controlConnection === newConnection {
                    self.controlConnection = nil
                }
            case .cancelled:
                self.pendingIncomingPairings = self.pendingIncomingPairings.filter { $0.value.connection !== newConnection }
                if self.connection === newConnection {
                    self.connection = nil
                    self.stopStreamWatchdog()
                    self.jitterBuffer.clear()
                    self.onEvent?(.disconnected("iPhone 已断开。"))
                } else if self.controlConnection === newConnection {
                    self.controlConnection = nil
                }
            default:
                break
            }
        }
        newConnection.start(queue: queue)
    }

    private func receiveIncomingInitialControlMessage(on connection: NWConnection, buffer: Data = Data()) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: PhoneMicAudio.controlMessageMaximumBytes) { [weak self] data, _, isComplete, error in
            guard let self else { return }

            var nextBuffer = buffer
            if let data, !data.isEmpty {
                nextBuffer.append(data)
                if let newlineRange = nextBuffer.firstRange(of: Data([0x0A])) {
                    let line = nextBuffer.subdata(in: 0..<newlineRange.lowerBound)
                    let remainder = nextBuffer.subdata(in: newlineRange.upperBound..<nextBuffer.endIndex)
                    self.handleIncomingControlLine(line, remainder: remainder, connection: connection)
                    return
                }

                if nextBuffer.count > PhoneMicAudio.controlMessageMaximumBytes {
                    self.rejectIncoming(connection, reason: "Handshake too large.")
                    return
                }
            }

            guard error == nil, !isComplete else {
                connection.cancel()
                return
            }
            self.receiveIncomingInitialControlMessage(on: connection, buffer: nextBuffer)
        }
    }

    private func handleIncomingControlLine(_ line: Data, remainder: Data, connection: NWConnection) {
        do {
            let message = try PhoneMicControlMessage.decodeLine(line)
            switch message.kind {
            case .sourceHello:
                authenticateIncomingSource(message, remainder: remainder, on: connection)
            case .controlHello:
                authenticateIncomingControl(message, remainder: remainder, on: connection)
            case .pairRequest:
                handleIncomingPairRequest(message, on: connection)
            default:
                rejectIncoming(connection, reason: "Unexpected receiver handshake message.")
            }
        } catch {
            rejectIncoming(connection, reason: "Invalid receiver handshake: \(error.localizedDescription)")
        }
    }

    private func authenticateIncomingSource(_ message: PhoneMicControlMessage, remainder: Data, on connection: NWConnection) {
        guard let deviceID = message.deviceID,
              let nonce = message.nonce,
              let authentication = message.authentication else {
            rejectIncoming(connection, reason: "Missing source authentication.")
            return
        }

        guard let secret = trustedSecret(forIncomingDeviceID: deviceID),
              PhoneMicSecurity.verifyAuthentication(
                  secret: secret,
                  nonce: nonce,
                  authentication: authentication,
                  protocolVersion: message.protocolVersion
              ) else {
            rejectIncoming(connection, reason: "iPhone is not paired.")
            return
        }

        self.connection?.cancel()
        self.connection = connection
        receiveBuffer.removeAll()
        controlBuffer.removeAll()
        stats = PhoneMicTransportStats(transport: .wifi)
        lastStatsEventAt = .distantPast
        lastPacketEventAt = .distantPast
        currentTransport = .wifi
        currentDeviceName = message.deviceName ?? deviceID
        streamStartedAt = Date()
        latestStatusAt = Date()

        let responseNonce = PhoneMicSecurity.randomNonce()
        let response = PhoneMicControlMessage(
            kind: .sourceAccepted,
            protocolVersion: message.protocolVersion,
            transport: .wifi,
            macID: MacIdentity.id,
            macName: MacIdentity.name,
            deviceID: deviceID,
            deviceName: currentDeviceName,
            nonce: responseNonce,
            authentication: PhoneMicSecurity.authenticationCode(
                secret: secret,
                nonce: responseNonce,
                protocolVersion: message.protocolVersion
            )
        )
        sendControl(response, on: connection)

        if !remainder.isEmpty {
            receiveBuffer.append(remainder)
            consumePackets()
        }

        guard transportPolicy.allows(.wifi) else {
            connection.cancel()
            return
        }
        onEvent?(.connected(currentDeviceName ?? deviceID, .wifi))
        if trustedSecrets[deviceID] == nil {
            let device = PhoneMicDiscoveredDevice(id: deviceID, name: currentDeviceName ?? "iPhone", transport: .wifi)
            onEvent?(.pairingSucceeded(device, secret))
        }
        startStreamWatchdog()
        receiveAudio(on: connection)
    }

    private func authenticateIncomingControl(_ message: PhoneMicControlMessage, remainder: Data, on connection: NWConnection) {
        guard let deviceID = message.deviceID,
              let nonce = message.nonce,
              let authentication = message.authentication else {
            rejectIncoming(connection, reason: "Missing control authentication.")
            return
        }

        guard let secret = trustedSecret(forIncomingDeviceID: deviceID),
              PhoneMicSecurity.verifyAuthentication(
                  secret: secret,
                  nonce: nonce,
                  authentication: authentication,
                  protocolVersion: message.protocolVersion
              ) else {
            rejectIncoming(connection, reason: "Control authentication failed.")
            return
        }

        controlConnection?.cancel()
        controlConnection = connection
        latestStatusAt = Date()

        let responseNonce = PhoneMicSecurity.randomNonce()
        let response = PhoneMicControlMessage(
            kind: .controlAccepted,
            protocolVersion: message.protocolVersion,
            transport: message.transport,
            macID: MacIdentity.id,
            macName: MacIdentity.name,
            deviceID: deviceID,
            deviceName: message.deviceName,
            nonce: responseNonce,
            authentication: PhoneMicSecurity.authenticationCode(
                secret: secret,
                nonce: responseNonce,
                protocolVersion: message.protocolVersion
            )
        )
        sendControl(response, on: connection)

        if !remainder.isEmpty {
            controlBuffer.append(remainder)
            consumeControlLines(on: connection)
        }
        receiveControlStatus(on: connection)
    }

    private func trustedSecret(forIncomingDeviceID deviceID: String) -> String? {
        if let secret = trustedSecrets[deviceID] {
            return secret
        }
        guard trustedSecrets.count == 1 else { return nil }
        return trustedSecrets.values.first
    }

    private func trustedDeviceForUSB(preferredDeviceID: String?) -> (deviceID: String, secret: String)? {
        if let preferredDeviceID, let secret = trustedSecrets[preferredDeviceID] {
            return (preferredDeviceID, secret)
        }

        guard trustedSecrets.count == 1,
              let trustedDevice = trustedSecrets.first else {
            return nil
        }
        return (trustedDevice.key, trustedDevice.value)
    }

    private func handleIncomingPairRequest(_ message: PhoneMicControlMessage, on connection: NWConnection) {
        guard let deviceID = message.deviceID,
              let pairingCode = message.pairingCode,
              let sharedSecret = message.sharedSecret else {
            rejectIncoming(connection, reason: "Invalid pairing request.")
            return
        }

        let request = PhoneMicPendingPairing(
            role: .iPhoneInitiated,
            macID: MacIdentity.id,
            macName: MacIdentity.name,
            deviceID: deviceID,
            deviceName: message.deviceName ?? "iPhone",
            pairingCode: pairingCode,
            sharedSecret: sharedSecret,
            protocolVersion: message.protocolVersion
        )
        pendingIncomingPairings[request.id] = PendingIncomingPairing(request: request, connection: connection)
        onEvent?(.pairingRequested(request))
    }

    private func rejectIncoming(_ connection: NWConnection, reason: String) {
        sendControl(
            PhoneMicControlMessage(
                kind: .streamRejected,
                macID: MacIdentity.id,
                macName: MacIdentity.name,
                reason: reason
            ),
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
            completion?(error)
            onEvent?(.error("PhoneMic 控制消息发送失败：\(error.localizedDescription)"))
            connection.cancel()
        }
    }

    private func preferredResult(from results: Set<NWBrowser.Result>) -> NWBrowser.Result? {
        if let preferredDeviceID,
           trustedSecrets[preferredDeviceID] != nil,
           let matchedResult = results.first(where: { $0.endpoint.phoneMicStableID == preferredDeviceID }) {
            return matchedResult
        }

        let trustedResults = results.filter { trustedSecrets[$0.endpoint.phoneMicStableID] != nil }
        if trustedResults.count == 1 {
            return trustedResults.first
        }

        if trustedSecrets.count == 1, results.count == 1 {
            return results.first
        }

        return nil
    }

    private func devices(from results: Set<NWBrowser.Result>) -> [PhoneMicDiscoveredDevice] {
        let devices = results.map { result in
            PhoneMicDiscoveredDevice(
                id: result.endpoint.phoneMicStableID,
                name: result.endpoint.phoneMicDisplayName,
                transport: .wifi,
                lastSeenAt: Date()
            )
        }

        return Dictionary(grouping: devices, by: \.id)
            .compactMap { _, groupedDevices in groupedDevices.first }
            .sorted { lhs, rhs in
                lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }

    private func connect(to endpoint: NWEndpoint, name: String, purpose: ConnectionPurpose) {
        connection?.cancel()
        controlConnection?.cancel()
        receiveBuffer.removeAll()
        controlBuffer.removeAll()
        receivedByteLogCount = 0
        stats = PhoneMicTransportStats()
        lastStatsEventAt = .distantPast
        lastPacketEventAt = .distantPast
        currentTransport = purpose.transportKind
        stats.transport = currentTransport
        streamStartedAt = nil
        latestStatusAt = nil
        stopStreamWatchdog()
        debug("connecting to \(endpoint)")

        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true

        let connection = NWConnection(to: endpoint, using: parameters)
        self.connection = connection

        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            self.debug("connection state: \(state)")

            switch state {
            case .ready:
                self.sendInitialControlMessage(on: connection, purpose: purpose)
                self.receiveControlResponse(on: connection, purpose: purpose)
            case .waiting(let error) where purpose.transportKind == .usb:
                if self.connection === connection {
                    self.connection = nil
                }
                self.controlConnection?.cancel()
                self.controlConnection = nil
                self.stopStreamWatchdog()
                self.jitterBuffer.clear()
                self.suppressNextCancelledEvent = true
                connection.cancel()
                self.onEvent?(.disconnected("连接失败：\(error.localizedDescription)"))
            case .failed(let error):
                self.connection = nil
                self.controlConnection?.cancel()
                self.controlConnection = nil
                self.stopStreamWatchdog()
                self.jitterBuffer.clear()
                self.onEvent?(.disconnected("连接失败：\(error.localizedDescription)"))
                if self.transportPolicy.allows(purpose.transportKind) {
                    self.scheduleDiscoveryRetry(for: purpose.transportKind)
                }
            case .cancelled:
                self.connection = nil
                self.controlConnection?.cancel()
                self.controlConnection = nil
                self.stopStreamWatchdog()
                self.jitterBuffer.clear()
                if self.suppressNextCancelledEvent {
                    self.suppressNextCancelledEvent = false
                    return
                }
                self.onEvent?(.disconnected("连接已关闭。"))
                if self.transportPolicy.allows(purpose.transportKind) {
                    self.scheduleDiscoveryRetry(for: purpose.transportKind)
                }
            default:
                break
            }
        }

        connection.start(queue: queue)
    }

    private func sendInitialControlMessage(on connection: NWConnection, purpose: ConnectionPurpose) {
        do {
            let message: PhoneMicControlMessage
            switch purpose {
            case .stream(_, let secret, let transport):
                let nonce = PhoneMicSecurity.randomNonce()
                let protocolVersion = PhoneMicAudio.previousProtocolVersion
                message = PhoneMicControlMessage(
                    kind: .streamHello,
                    protocolVersion: protocolVersion,
                    transport: transport,
                    macID: MacIdentity.shared.id,
                    macName: MacIdentity.shared.name,
                    nonce: nonce,
                    authentication: PhoneMicSecurity.authenticationCode(
                        secret: secret,
                        nonce: nonce,
                        protocolVersion: protocolVersion
                    )
                )
            case .control(_, let secret, let transport):
                let nonce = PhoneMicSecurity.randomNonce()
                message = PhoneMicControlMessage(
                    kind: .controlHello,
                    transport: transport,
                    macID: MacIdentity.shared.id,
                    macName: MacIdentity.shared.name,
                    nonce: nonce,
                    authentication: PhoneMicSecurity.authenticationCode(secret: secret, nonce: nonce)
                )
            case .pair(_, let macID, let macName, let code, let secret):
                message = PhoneMicControlMessage(
                    kind: .pairRequest,
                    macID: macID,
                    macName: macName,
                    pairingCode: code,
                    sharedSecret: secret
                )
            }

            connection.send(content: try message.encodedLine(), completion: .contentProcessed { _ in })
        } catch {
            onEvent?(.error("无法编码 PhoneMic 握手消息：\(error.localizedDescription)"))
            connection.cancel()
        }
    }

    private func receiveControlResponse(on connection: NWConnection, purpose: ConnectionPurpose) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: PhoneMicAudio.controlMessageMaximumBytes) { [weak self] data, _, isComplete, error in
            guard let self else { return }

            if let data, !data.isEmpty {
                self.controlBuffer.append(data)
                if let newlineRange = self.controlBuffer.firstRange(of: Data([0x0A])) {
                    let line = self.controlBuffer.subdata(in: 0..<newlineRange.lowerBound)
                    let remainderStart = newlineRange.upperBound
                    let remainder = self.controlBuffer.subdata(in: remainderStart..<self.controlBuffer.endIndex)
                    self.controlBuffer.removeAll()
                    self.handleControlLine(line, remainder: remainder, connection: connection, purpose: purpose)
                    return
                }

                if self.controlBuffer.count > PhoneMicAudio.controlMessageMaximumBytes {
                    self.onEvent?(.error("PhoneMic 握手消息过大。"))
                    connection.cancel()
                    return
                }
            }

            if let error {
                self.onEvent?(.disconnected("握手失败：\(error.localizedDescription)"))
                connection.cancel()
                return
            }

            if isComplete {
                self.onEvent?(.disconnected("握手连接已关闭。"))
                connection.cancel()
                return
            }

            self.receiveControlResponse(on: connection, purpose: purpose)
        }
    }

    private func handleControlLine(
        _ line: Data,
        remainder: Data,
        connection: NWConnection,
        purpose: ConnectionPurpose
    ) {
        do {
            let message = try PhoneMicControlMessage.decodeLine(line)
            switch (purpose, message.kind) {
            case (.stream(let deviceID, let secret, let transport), .streamAccepted):
                guard let nonce = message.nonce,
                      let authentication = message.authentication else {
                    onEvent?(.error("iPhone 未完成音频流鉴权，请重新配对。"))
                    connection.cancel()
                    return
                }
                if !PhoneMicSecurity.verifyAuthentication(
                    secret: secret,
                    nonce: nonce,
                    authentication: authentication,
                    protocolVersion: message.protocolVersion
                ) {
                    onEvent?(.error("iPhone 鉴权失败，请重新配对。"))
                    connection.cancel()
                    return
                }
                if !remainder.isEmpty {
                    receiveBuffer.append(remainder)
                    consumePackets()
                }
                currentTransport = transport
                stats.transport = transport
                let name = currentDeviceName ?? deviceID
                guard transportPolicy.allows(transport) else {
                    connection.cancel()
                    return
                }
                onEvent?(.connected(name, transport))
                if transport == .usb {
                    latestStatusAt = Date()
                } else {
                    startControlChannel(to: connection.endpoint, deviceID: deviceID, secret: secret, transport: transport)
                }
                startStreamWatchdog()
                receiveAudio(on: connection)
            case (.control(_, let secret, _), .controlAccepted):
                guard let nonce = message.nonce,
                      let authentication = message.authentication,
                      PhoneMicSecurity.verifyAuthentication(
                          secret: secret,
                          nonce: nonce,
                          authentication: authentication,
                          protocolVersion: message.protocolVersion
                      ) else {
                    onEvent?(.error("iPhone 控制通道鉴权失败，请重新连接。"))
                    connection.cancel()
                    return
                }
                if !remainder.isEmpty {
                    controlBuffer.append(remainder)
                    consumeControlLines(on: connection)
                }
                latestStatusAt = Date()
                receiveControlStatus(on: connection)
            case (.stream, .streamRejected):
                onEvent?(.disconnected(message.reason ?? "iPhone 拒绝了连接。"))
                connection.cancel()
            case (.control, .streamRejected):
                onEvent?(.error(message.reason ?? "iPhone 拒绝了控制通道。"))
                connection.cancel()
            case (.pair(let device, _, _, _, let secret), .pairAccepted):
                guard let nonce = message.nonce,
                      let authentication = message.authentication,
                      PhoneMicSecurity.verifyAuthentication(
                          secret: secret,
                          nonce: nonce,
                          authentication: authentication,
                          protocolVersion: message.protocolVersion
                      ) else {
                    onEvent?(.pairingFailed("iPhone 信任响应验证失败，请重新配对。"))
                    suppressNextCancelledEvent = true
                    connection.cancel()
                    return
                }
                onEvent?(.pairingSucceeded(device, secret))
                suppressNextCancelledEvent = true
                connection.cancel()
            case (.pair, .pairRejected):
                onEvent?(.pairingFailed(message.reason ?? "iPhone 拒绝了配对。"))
                suppressNextCancelledEvent = true
                connection.cancel()
            default:
                onEvent?(.error("收到非预期的 PhoneMic 握手响应：\(message.kind.rawValue)"))
                connection.cancel()
            }
        } catch {
            onEvent?(.error("PhoneMic 握手无效：\(error.localizedDescription)"))
            connection.cancel()
        }
    }

    private func receiveAudio(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }

            if let data, !data.isEmpty {
                if self.receivedByteLogCount < 5 {
                    self.debug("received \(data.count) bytes")
                    self.receivedByteLogCount += 1
                }
                self.stats.bytesReceived += UInt64(data.count)
                self.receiveBuffer.append(data)
                self.consumePackets()
            }

            if let error {
                self.debug("receive failed: \(error)")
                self.onEvent?(.disconnected("接收失败：\(error.localizedDescription)"))
                self.stopStreamWatchdog()
                self.connection?.cancel()
                return
            }

            if isComplete {
                self.debug("receive complete")
                self.onEvent?(.disconnected("iPhone 已停止发送。"))
                self.stopStreamWatchdog()
                self.connection?.cancel()
                return
            }

            self.receiveAudio(on: connection)
        }
    }

    private func startControlChannel(
        to endpoint: NWEndpoint,
        deviceID: String,
        secret: String,
        transport: PhoneMicTransportKind
    ) {
        controlConnection?.cancel()

        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        let controlConnection = NWConnection(to: controlEndpoint(for: endpoint, transport: transport), using: parameters)
        self.controlConnection = controlConnection

        controlConnection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.sendInitialControlMessage(
                    on: controlConnection,
                    purpose: .control(deviceID: deviceID, secret: secret, transport: transport)
                )
                self.receiveControlResponse(
                    on: controlConnection,
                    purpose: .control(deviceID: deviceID, secret: secret, transport: transport)
                )
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

    private func controlEndpoint(for endpoint: NWEndpoint, transport: PhoneMicTransportKind) -> NWEndpoint {
        guard transport == .usb,
              let audioPort = NWEndpoint.Port(rawValue: PhoneMicAudio.audioPort) else {
            return endpoint
        }
        // The current iPhone app accepts control connections through the same
        // listener as audio. Keep USB aligned with Wi-Fi until a separate iOS
        // control listener ships, otherwise the 48241 USB leg resets the stream.
        return .hostPort(host: .ipv4(IPv4Address("127.0.0.1")!), port: audioPort)
    }

    private func receiveControlStatus(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: PhoneMicAudio.controlMessageMaximumBytes) { [weak self] data, _, isComplete, error in
            guard let self else { return }

            if let data, !data.isEmpty {
                self.controlBuffer.append(data)
                self.consumeControlLines(on: connection)
            }

            if error != nil || isComplete {
                connection.cancel()
                return
            }

            self.receiveControlStatus(on: connection)
        }
    }

    private func consumeControlLines(on connection: NWConnection) {
        while let newlineRange = controlBuffer.firstRange(of: Data([0x0A])) {
            let line = controlBuffer.subdata(in: 0..<newlineRange.lowerBound)
            controlBuffer.removeSubrange(0..<newlineRange.upperBound)
            do {
                let message = try PhoneMicControlMessage.decodeLine(line)
                switch message.kind {
                case .statusUpdate:
                    if let status = message.status {
                        latestStatusAt = Date()
                        currentTransport = status.transport
                        onEvent?(.deviceStatus(status))
                    }
                case .streamStopping:
                    latestStatusAt = Date()
                    onEvent?(.streamStopping(message.reason ?? "iPhone 已停止发送。"))
                case .heartbeat:
                    latestStatusAt = Date()
                default:
                    break
                }
            } catch {
                onEvent?(.error("PhoneMic 状态消息无效：\(error.localizedDescription)"))
                connection.cancel()
            }
        }
    }

    private func consumePackets() {
        do {
            while var packet = try AudioPacket.consume(from: &receiveBuffer) {
                if packet.transport == .tcp {
                    packet.transport = currentTransport
                }
                if let lastSequence = stats.lastSequence {
                    if packet.sequence == lastSequence {
                        stats.duplicatePackets += 1
                        continue
                    } else if packet.sequence < lastSequence {
                        stats.duplicatePackets += 1
                        continue
                    } else if packet.sequence > lastSequence + 1 {
                        stats.sequenceGaps += packet.sequence - lastSequence - 1
                    }
                }

                stats.lastSequence = packet.sequence
                stats.packetsReceived += 1
                stats.lastPacketAt = Date()
                jitterBuffer.push(packet: packet)
                emitPacketEventIfNeeded(packet)
                emitTransportStatsIfNeeded()
            }
        } catch {
            debug("invalid audio stream: \(error)")
            receiveBuffer.removeAll()
            jitterBuffer.clear()
            onEvent?(.error("音频流无效：\(error)"))
            connection?.cancel()
        }
    }

    private func emitTransportStatsIfNeeded() {
        let now = Date()
        guard now.timeIntervalSince(lastStatsEventAt) >= 1 else { return }
        lastStatsEventAt = now
        onEvent?(.transportStats(stats))
    }

    private func emitPacketEventIfNeeded(_ packet: AudioPacket) {
        let now = Date()
        guard now.timeIntervalSince(lastPacketEventAt) >= 0.1 else { return }
        lastPacketEventAt = now
        onEvent?(.packet(packet))
    }

    private func scheduleDiscoveryRetry(for transport: PhoneMicTransportKind = .wifi) {
        guard shouldRun, autoReconnect, transportPolicy.allows(.wifi), transport != .usb else { return }
        queue.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self,
                  self.shouldRun,
                  self.connection == nil,
                  self.transportPolicy.allows(.wifi) else { return }
            self.startBrowser()
        }
    }

    private func startStreamWatchdog() {
        stopStreamWatchdog()
        streamStartedAt = Date()

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: .milliseconds(500), leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in
            self?.checkStreamTimeout()
        }
        watchdogTimer = timer
        timer.resume()
    }

    private func stopStreamWatchdog() {
        watchdogTimer?.cancel()
        watchdogTimer = nil
        streamStartedAt = nil
    }

    private func checkStreamTimeout() {
        guard connection != nil else { return }

        let now = Date()
        let referenceDate = stats.lastPacketAt ?? streamStartedAt ?? now
        let latestControlDate = latestStatusAt ?? streamStartedAt ?? now
        let audioTimedOut = now.timeIntervalSince(referenceDate) > streamTimeoutSeconds
        let controlTimedOut = currentTransport != .usb && now.timeIntervalSince(latestControlDate) > 2.5
        guard audioTimedOut || controlTimedOut else { return }

        debug("stream timed out after \(streamTimeoutSeconds)s without audio packets")
        suppressNextCancelledEvent = true
        connection?.cancel()
        connection = nil
        stopStreamWatchdog()
        jitterBuffer.clear()
        onEvent?(.disconnected("iPhone 已停止发送。"))
        scheduleDiscoveryRetry()
    }

    private func debug(_ message: String) {
        NSLog("PhoneMic receiver: %@", message)
    }
}

enum MacIdentity {
    private static let idDefaultsKey = "PhoneMic.macID"

    static var id: String {
        if let saved = UserDefaults.standard.string(forKey: idDefaultsKey) {
            return saved
        }
        let value = UUID().uuidString
        UserDefaults.standard.set(value, forKey: idDefaultsKey)
        return value
    }

    static var name: String {
        Host.current().localizedName ?? Host.current().name ?? "Mac"
    }

    static var shared: (id: String, name: String) {
        (id, name)
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
            return "iPhone"
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
