import Foundation

public enum AudioPacketError: Error, Equatable {
    case invalidMagic
    case invalidVersion(UInt16)
    case invalidHeaderSize(UInt16)
    case invalidPayloadSize(UInt32)
}

public struct AudioPacket: Equatable {
    public static let magic: UInt32 = 0x504D_4943
    public static let legacyHeaderSize = 36
    public static let headerSize = 64
    public static let maximumPayloadBytes: UInt32 = 48_000 * 4

    public var sequence: UInt64
    public var sampleRate: UInt32
    public var channels: UInt16
    public var frames: UInt16
    public var sentWallClockNanoseconds: UInt64
    public var sessionID: UInt64
    public var flags: UInt16
    public var codec: PhoneMicAudioCodec
    public var transport: PhoneMicTransportKind
    public var senderQueuedFrames: UInt32
    public var senderLevelMilliPercent: UInt32
    public var samples: [Float]

    public init(
        sequence: UInt64,
        sampleRate: UInt32 = UInt32(PhoneMicAudio.sampleRate),
        channels: UInt16 = PhoneMicAudio.channels,
        sentWallClockNanoseconds: UInt64 = PhoneMicClock.wallClockNanoseconds(),
        sessionID: UInt64 = 0,
        flags: UInt16 = 0,
        codec: PhoneMicAudioCodec = .pcmFloat32,
        transport: PhoneMicTransportKind = .tcp,
        senderQueuedFrames: UInt32 = 0,
        senderLevelMilliPercent: UInt32 = 0,
        samples: [Float]
    ) {
        self.sequence = sequence
        self.sampleRate = sampleRate
        self.channels = channels
        self.frames = UInt16(samples.count / max(Int(channels), 1))
        self.sentWallClockNanoseconds = sentWallClockNanoseconds
        self.sessionID = sessionID
        self.flags = flags
        self.codec = codec
        self.transport = transport
        self.senderQueuedFrames = senderQueuedFrames
        self.senderLevelMilliPercent = senderLevelMilliPercent
        self.samples = samples
    }

    public func encoded() -> Data {
        var data = Data(capacity: AudioPacket.headerSize + samples.count * MemoryLayout<Float>.size)
        data.appendLittleEndian(AudioPacket.magic)
        data.appendLittleEndian(PhoneMicAudio.protocolVersion)
        data.appendLittleEndian(UInt16(AudioPacket.headerSize))
        data.appendLittleEndian(sequence)
        data.appendLittleEndian(sampleRate)
        data.appendLittleEndian(channels)
        data.appendLittleEndian(frames)
        data.appendLittleEndian(sentWallClockNanoseconds)
        data.appendLittleEndian(UInt32(samples.count * MemoryLayout<Float>.size))
        data.appendLittleEndian(sessionID)
        data.appendLittleEndian(flags)
        data.appendLittleEndian(codec.rawValue)
        data.appendLittleEndian(transport.wireValue)
        data.appendLittleEndian(UInt16(0))
        data.appendLittleEndian(senderQueuedFrames)
        data.appendLittleEndian(senderLevelMilliPercent)
        data.appendLittleEndian(UInt32(0))

        for sample in samples {
            data.appendLittleEndian(sample.bitPattern)
        }

        return data
    }

    public static func consume(from buffer: inout Data) throws -> AudioPacket? {
        guard buffer.count >= headerSize else { return nil }

        let magic: UInt32 = buffer.readLittleEndian(at: 0)
        guard magic == Self.magic else { throw AudioPacketError.invalidMagic }

        let version: UInt16 = buffer.readLittleEndian(at: 4)
        guard version == PhoneMicAudio.protocolVersion
            || version == PhoneMicAudio.previousProtocolVersion
            || version == PhoneMicAudio.legacyProtocolVersion else {
            throw AudioPacketError.invalidVersion(version)
        }

        let headerSizeValue: UInt16 = buffer.readLittleEndian(at: 6)
        guard Int(headerSizeValue) == headerSize || Int(headerSizeValue) == legacyHeaderSize else {
            throw AudioPacketError.invalidHeaderSize(headerSizeValue)
        }
        guard buffer.count >= Int(headerSizeValue) else { return nil }

        let sequence: UInt64 = buffer.readLittleEndian(at: 8)
        let sampleRate: UInt32 = buffer.readLittleEndian(at: 16)
        let channels: UInt16 = buffer.readLittleEndian(at: 20)
        let frames: UInt16 = buffer.readLittleEndian(at: 22)
        let sentWallClockNanoseconds: UInt64 = buffer.readLittleEndian(at: 24)
        let payloadBytes: UInt32 = buffer.readLittleEndian(at: 32)
        let headerLength = Int(headerSizeValue)

        let sessionID: UInt64
        let flags: UInt16
        let codec: PhoneMicAudioCodec
        let transport: PhoneMicTransportKind
        let senderQueuedFrames: UInt32
        let senderLevelMilliPercent: UInt32

        if headerLength == headerSize {
            sessionID = buffer.readLittleEndian(at: 36)
            flags = buffer.readLittleEndian(at: 44)
            let codecRaw: UInt16 = buffer.readLittleEndian(at: 46)
            codec = PhoneMicAudioCodec(rawValue: codecRaw) ?? .pcmFloat32
            let transportRaw: UInt16 = buffer.readLittleEndian(at: 48)
            transport = PhoneMicTransportKind(wireValue: transportRaw) ?? .tcp
            senderQueuedFrames = buffer.readLittleEndian(at: 52)
            senderLevelMilliPercent = buffer.readLittleEndian(at: 56)
        } else {
            sessionID = 0
            flags = 0
            codec = .pcmFloat32
            transport = .tcp
            senderQueuedFrames = 0
            senderLevelMilliPercent = 0
        }

        guard payloadBytes <= maximumPayloadBytes, payloadBytes % 4 == 0 else {
            throw AudioPacketError.invalidPayloadSize(payloadBytes)
        }

        let packetLength = headerLength + Int(payloadBytes)
        guard buffer.count >= packetLength else { return nil }

        let sampleCount = Int(payloadBytes) / MemoryLayout<Float>.size
        var samples: [Float] = []
        samples.reserveCapacity(sampleCount)
        var offset = headerLength
        for _ in 0..<sampleCount {
            let bitPattern: UInt32 = buffer.readLittleEndian(at: offset)
            samples.append(Float(bitPattern: bitPattern))
            offset += MemoryLayout<Float>.size
        }

        buffer.removeSubrange(0..<packetLength)

        return AudioPacket(
            sequence: sequence,
            sampleRate: sampleRate,
            channels: channels,
            sentWallClockNanoseconds: sentWallClockNanoseconds,
            sessionID: sessionID,
            flags: flags,
            codec: codec,
            transport: transport,
            senderQueuedFrames: senderQueuedFrames,
            senderLevelMilliPercent: senderLevelMilliPercent,
            samples: samples
        ).withFrames(frames)
    }

    private func withFrames(_ frames: UInt16) -> AudioPacket {
        var copy = self
        copy.frames = frames
        return copy
    }
}

private extension PhoneMicTransportKind {
    var wireValue: UInt16 {
        switch self {
        case .tcp:
            return 1
        case .wifi:
            return 4
        case .usb:
            return 5
        case .udpReserved:
            return 2
        case .quicReserved:
            return 3
        }
    }

    init?(wireValue: UInt16) {
        switch wireValue {
        case 1:
            self = .tcp
        case 2:
            self = .udpReserved
        case 3:
            self = .quicReserved
        case 4:
            self = .wifi
        case 5:
            self = .usb
        default:
            return nil
        }
    }
}

private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var littleEndianValue = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndianValue) { bytes in
            append(contentsOf: bytes)
        }
    }

    func readLittleEndian<T: FixedWidthInteger>(at offset: Int) -> T {
        withUnsafeBytes { rawBuffer in
            rawBuffer.loadUnaligned(fromByteOffset: offset, as: T.self).littleEndian
        }
    }
}
