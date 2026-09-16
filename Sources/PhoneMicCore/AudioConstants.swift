import CryptoKit
import Foundation

public enum PhoneMicAudio {
    public static let sampleRate: Double = 48_000
    public static let channels: UInt16 = 1
    public static let frameDurationMilliseconds: Double = 5
    public static let framesPerPacket: Int = 240
    public static let audioPort: UInt16 = 48_240
    public static let controlPort: UInt16 = 48_241
    public static let bonjourServiceType = "_phonemic._tcp"
    public static let macReceiverBonjourServiceType = "_phonemic-receiver._tcp"
    public static let protocolVersion: UInt16 = 3
    public static let legacyProtocolVersion: UInt16 = 1
    public static let previousProtocolVersion: UInt16 = 2
    public static let controlMessageMaximumBytes = 8 * 1024
}

public enum PhoneMicClock {
    public static func wallClockNanoseconds() -> UInt64 {
        UInt64(Date().timeIntervalSince1970 * 1_000_000_000)
    }

    public static func millisecondsSince(_ senderWallClockNanoseconds: UInt64) -> Double {
        let now = wallClockNanoseconds()
        guard now >= senderWallClockNanoseconds else { return 0 }
        return Double(now - senderWallClockNanoseconds) / 1_000_000
    }
}

public enum PhoneMicTransportKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case tcp
    case wifi
    case usb
    case udpReserved
    case quicReserved

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .tcp, .wifi:
            return "Wi-Fi"
        case .usb:
            return "USB"
        case .udpReserved:
            return "UDP"
        case .quicReserved:
            return "QUIC"
        }
    }
}

public enum PhoneMicAudioCodec: UInt16, Codable {
    case pcmFloat32 = 1
}

public struct PhoneMicTrustedPeer: Codable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var sharedSecret: String
    public var createdAt: Date

    public init(id: String, name: String, sharedSecret: String, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.sharedSecret = sharedSecret
        self.createdAt = createdAt
    }
}

public struct PhoneMicPairingRequest: Codable, Equatable, Identifiable {
    public var id: String { macID }
    public var macID: String
    public var macName: String
    public var deviceID: String?
    public var deviceName: String?
    public var pairingCode: String
    public var sharedSecret: String
    public var protocolVersion: UInt16

    public init(
        macID: String,
        macName: String,
        deviceID: String? = nil,
        deviceName: String? = nil,
        pairingCode: String,
        sharedSecret: String,
        protocolVersion: UInt16 = PhoneMicAudio.protocolVersion
    ) {
        self.macID = macID
        self.macName = macName
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.pairingCode = pairingCode
        self.sharedSecret = sharedSecret
        self.protocolVersion = protocolVersion
    }
}

public enum PhoneMicConnectionRole: String, Codable, Equatable {
    case legacyMacInitiated
    case iPhoneInitiated
}

public struct PhoneMicDiscoveredMac: Codable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var isPaired: Bool
    public var lastSeenAt: Date
    public var features: [String]

    public init(
        id: String,
        name: String,
        isPaired: Bool,
        lastSeenAt: Date = Date(),
        features: [String] = []
    ) {
        self.id = id
        self.name = name
        self.isPaired = isPaired
        self.lastSeenAt = lastSeenAt
        self.features = features
    }
}

public struct PhoneMicPendingPairing: Codable, Equatable, Identifiable {
    public var id: String { "\(role.rawValue)|\(deviceID)|\(macID)" }
    public var role: PhoneMicConnectionRole
    public var macID: String
    public var macName: String
    public var deviceID: String
    public var deviceName: String
    public var pairingCode: String
    public var sharedSecret: String
    public var protocolVersion: UInt16

    public init(
        role: PhoneMicConnectionRole,
        macID: String,
        macName: String,
        deviceID: String,
        deviceName: String,
        pairingCode: String,
        sharedSecret: String,
        protocolVersion: UInt16 = PhoneMicAudio.protocolVersion
    ) {
        self.role = role
        self.macID = macID
        self.macName = macName
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.pairingCode = pairingCode
        self.sharedSecret = sharedSecret
        self.protocolVersion = protocolVersion
    }
}

public enum PhoneMicControlMessageKind: String, Codable {
    case pairRequest
    case pairAccepted
    case pairRejected
    case streamHello
    case streamAccepted
    case streamRejected
    case sourceHello
    case sourceAccepted
    case controlHello
    case controlAccepted
    case statusUpdate
    case command
    case streamStopping
    case heartbeat
}

public enum PhoneMicStreamingPhase: String, Codable, Equatable {
    case idle
    case advertising
    case pairing
    case capturing
    case sending
    case stopping
    case interrupted
    case failed
}

public enum PhoneMicCommand: String, Codable, Equatable {
    case stopStreaming
    case forgetMac
    case requestStatus
}

public struct PhoneMicDeviceStatus: Codable, Equatable {
    public var deviceID: String
    public var deviceName: String
    public var phase: PhoneMicStreamingPhase
    public var isCapturing: Bool
    public var isSendingAudio: Bool
    public var inputName: String
    public var connectedMacName: String?
    public var packetCount: UInt64
    public var transport: PhoneMicTransportKind
    public var isInBackground: Bool
    public var errorSummary: String?
    public var updatedAt: Date

    public init(
        deviceID: String,
        deviceName: String,
        phase: PhoneMicStreamingPhase,
        isCapturing: Bool,
        isSendingAudio: Bool,
        inputName: String,
        connectedMacName: String?,
        packetCount: UInt64,
        transport: PhoneMicTransportKind,
        isInBackground: Bool,
        errorSummary: String? = nil,
        updatedAt: Date = Date()
    ) {
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.phase = phase
        self.isCapturing = isCapturing
        self.isSendingAudio = isSendingAudio
        self.inputName = inputName
        self.connectedMacName = connectedMacName
        self.packetCount = packetCount
        self.transport = transport
        self.isInBackground = isInBackground
        self.errorSummary = errorSummary
        self.updatedAt = updatedAt
    }
}

public struct PhoneMicControlMessage: Codable, Equatable {
    public var kind: PhoneMicControlMessageKind
    public var protocolVersion: UInt16
    public var transport: PhoneMicTransportKind
    public var macID: String?
    public var macName: String?
    public var deviceID: String?
    public var deviceName: String?
    public var pairingCode: String?
    public var sharedSecret: String?
    public var nonce: String?
    public var authentication: String?
    public var reason: String?
    public var status: PhoneMicDeviceStatus?
    public var command: PhoneMicCommand?

    public init(
        kind: PhoneMicControlMessageKind,
        protocolVersion: UInt16 = PhoneMicAudio.protocolVersion,
        transport: PhoneMicTransportKind = .wifi,
        macID: String? = nil,
        macName: String? = nil,
        deviceID: String? = nil,
        deviceName: String? = nil,
        pairingCode: String? = nil,
        sharedSecret: String? = nil,
        nonce: String? = nil,
        authentication: String? = nil,
        reason: String? = nil,
        status: PhoneMicDeviceStatus? = nil,
        command: PhoneMicCommand? = nil
    ) {
        self.kind = kind
        self.protocolVersion = protocolVersion
        self.transport = transport
        self.macID = macID
        self.macName = macName
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.pairingCode = pairingCode
        self.sharedSecret = sharedSecret
        self.nonce = nonce
        self.authentication = authentication
        self.reason = reason
        self.status = status
        self.command = command
    }

    public func encodedLine() throws -> Data {
        var data = try JSONEncoder().encode(self)
        data.append(0x0A)
        return data
    }

    public static func decodeLine(_ data: Data) throws -> PhoneMicControlMessage {
        try JSONDecoder().decode(PhoneMicControlMessage.self, from: data)
    }
}

public struct PhoneMicTransportStats: Codable, Equatable {
    public var transport: PhoneMicTransportKind
    public var packetsReceived: UInt64
    public var bytesReceived: UInt64
    public var sequenceGaps: UInt64
    public var duplicatePackets: UInt64
    public var lastSequence: UInt64?
    public var lastPacketAt: Date?

    public init(
        transport: PhoneMicTransportKind = .wifi,
        packetsReceived: UInt64 = 0,
        bytesReceived: UInt64 = 0,
        sequenceGaps: UInt64 = 0,
        duplicatePackets: UInt64 = 0,
        lastSequence: UInt64? = nil,
        lastPacketAt: Date? = nil
    ) {
        self.transport = transport
        self.packetsReceived = packetsReceived
        self.bytesReceived = bytesReceived
        self.sequenceGaps = sequenceGaps
        self.duplicatePackets = duplicatePackets
        self.lastSequence = lastSequence
        self.lastPacketAt = lastPacketAt
    }
}

public enum PhoneMicSecurity {
    public static func randomPairingCode() -> String {
        String(format: "%06d", Int.random(in: 0...999_999))
    }

    public static func randomSecret() -> String {
        "\(UUID().uuidString)-\(UUID().uuidString)-\(UUID().uuidString)"
    }

    public static func randomNonce() -> String {
        "\(UUID().uuidString)-\(UInt64.random(in: UInt64.min...UInt64.max))"
    }

    public static func authenticationCode(
        secret: String,
        nonce: String,
        protocolVersion: UInt16 = PhoneMicAudio.protocolVersion
    ) -> String {
        let key = SymmetricKey(data: Data(secret.utf8))
        let message = Data("PhoneMic|\(protocolVersion)|\(nonce)".utf8)
        let mac = HMAC<SHA256>.authenticationCode(for: message, using: key)
        return Data(mac).base64EncodedString()
    }

    public static func verifyAuthentication(
        secret: String,
        nonce: String,
        authentication: String,
        protocolVersion: UInt16 = PhoneMicAudio.protocolVersion
    ) -> Bool {
        authenticationCode(secret: secret, nonce: nonce, protocolVersion: protocolVersion) == authentication
    }
}
