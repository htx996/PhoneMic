import Foundation
import PhoneMicCore

enum SelfTestFailure: Error, CustomStringConvertible {
    case message(String)

    var description: String {
        switch self {
        case .message(let value):
            return value
        }
    }
}

func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() {
        throw SelfTestFailure.message(message)
    }
}

func testPacketRoundTrip() throws {
    let packet = AudioPacket(
        sequence: 42,
        sentWallClockNanoseconds: 123_456_789,
        sessionID: 99,
        flags: 7,
        transport: .tcp,
        senderQueuedFrames: 480,
        senderLevelMilliPercent: 321,
        samples: [0, 0.25, -0.5, 1]
    )

    var data = packet.encoded()
    guard let decoded = try AudioPacket.consume(from: &data) else {
        throw SelfTestFailure.message("expected a decoded packet")
    }

    try expect(decoded.sequence == 42, "packet sequence did not round-trip")
    try expect(decoded.sampleRate == 48_000, "sample rate did not round-trip")
    try expect(decoded.channels == 1, "channel count did not round-trip")
    try expect(decoded.frames == 4, "frame count did not round-trip")
    try expect(decoded.sentWallClockNanoseconds == 123_456_789, "timestamp did not round-trip")
    try expect(decoded.sessionID == 99, "session id did not round-trip")
    try expect(decoded.flags == 7, "flags did not round-trip")
    try expect(decoded.senderQueuedFrames == 480, "queued frame count did not round-trip")
    try expect(decoded.senderLevelMilliPercent == 321, "sender level did not round-trip")
    try expect(decoded.samples == [0, 0.25, -0.5, 1], "samples did not round-trip")
    try expect(data.isEmpty, "decoder did not consume the packet")
}

func testControlMessageRoundTrip() throws {
    let message = PhoneMicControlMessage(
        kind: .streamHello,
        macID: "mac-1",
        macName: "Studio Mac",
        nonce: "nonce",
        authentication: "auth"
    )

    let encoded = try message.encodedLine()
    try expect(encoded.last == 0x0A, "control message should be newline framed")
    let decoded = try PhoneMicControlMessage.decodeLine(Data(encoded.dropLast()))
    try expect(decoded == message, "control message should round-trip")
}

func testStatusMessageRoundTrip() throws {
    let status = PhoneMicDeviceStatus(
        deviceID: "phone-1",
        deviceName: "Hanfu's iPhone",
        phase: .sending,
        isCapturing: true,
        isSendingAudio: true,
        inputName: "内置麦克风",
        connectedMacName: "Hanfu's Mac mini",
        packetCount: 128,
        transport: .usb,
        isInBackground: false,
        errorSummary: nil
    )
    let message = PhoneMicControlMessage(
        kind: .statusUpdate,
        transport: .usb,
        deviceID: status.deviceID,
        status: status
    )

    let decoded = try PhoneMicControlMessage.decodeLine(Data(try message.encodedLine().dropLast()))
    try expect(decoded.kind == .statusUpdate, "status message kind should round-trip")
    try expect(decoded.transport == .usb, "status transport should round-trip")
    try expect(decoded.status == status, "device status should round-trip")
}

func testSourceHandshakeMessageRoundTrip() throws {
    let message = PhoneMicControlMessage(
        kind: .sourceHello,
        transport: .wifi,
        macID: "mac-1",
        deviceID: "phone-1",
        deviceName: "Hanfu's iPhone",
        nonce: "nonce",
        authentication: "auth"
    )

    let decoded = try PhoneMicControlMessage.decodeLine(Data(try message.encodedLine().dropLast()))
    try expect(decoded.kind == .sourceHello, "source hello kind should round-trip")
    try expect(decoded.deviceName == "Hanfu's iPhone", "source hello device name should round-trip")
    try expect(decoded.macID == "mac-1", "source hello mac id should round-trip")
}

func testIPhoneInitiatedPairingModelRoundTrip() throws {
    let request = PhoneMicPendingPairing(
        role: .iPhoneInitiated,
        macID: "mac-1",
        macName: "Studio Mac",
        deviceID: "phone-1",
        deviceName: "Hanfu's iPhone",
        pairingCode: "123456",
        sharedSecret: "secret"
    )

    let encoded = try JSONEncoder().encode(request)
    let decoded = try JSONDecoder().decode(PhoneMicPendingPairing.self, from: encoded)
    try expect(decoded == request, "iPhone initiated pairing should round-trip")
}

func testAuthenticationCode() throws {
    let secret = PhoneMicSecurity.randomSecret()
    let nonce = PhoneMicSecurity.randomNonce()
    let code = PhoneMicSecurity.authenticationCode(secret: secret, nonce: nonce)

    try expect(PhoneMicSecurity.verifyAuthentication(secret: secret, nonce: nonce, authentication: code), "auth code should verify")
    try expect(!PhoneMicSecurity.verifyAuthentication(secret: secret, nonce: "wrong", authentication: code), "wrong nonce should fail")
}

func testPartialPacketWaits() throws {
    let packet = AudioPacket(sequence: 1, samples: [0.1, 0.2, 0.3])
    let encoded = packet.encoded()
    var partial = encoded.prefix(AudioPacket.headerSize + 2)

    let decoded = try AudioPacket.consume(from: &partial)
    try expect(decoded == nil, "partial packet should not decode")
    try expect(partial.count == AudioPacket.headerSize + 2, "partial packet should stay buffered")
}

func testRingBufferDropsOldestFramesWhenFull() throws {
    let ring = PCMFloatRingBuffer(capacityFrames: 3)
    ring.push([1, 2, 3, 4])

    try expect(ring.availableFrames == 3, "ring buffer should report full capacity")
    try expect(ring.droppedFrames == 1, "ring buffer should drop one old frame")
    try expect(ring.read(frameCount: 3) == [2, 3, 4], "ring buffer should retain newest frames")
}

func testJitterBufferPrebuffersBeforePlayback() throws {
    let jitter = JitterBuffer(capacityFrames: 10, prebufferFrames: 4)
    jitter.push(packet: AudioPacket(sequence: 1, samples: [1, 2, 3]))

    try expect(jitter.readForPlayback(frameCount: 2) == [0, 0], "jitter buffer should prebuffer")

    jitter.push(packet: AudioPacket(sequence: 2, samples: [4]))
    try expect(jitter.readForPlayback(frameCount: 2) == [1, 2], "jitter buffer should play after priming")
}

func testJitterBufferReturnsSilenceOnUnderrun() throws {
    let jitter = JitterBuffer(capacityFrames: 10, prebufferFrames: 2)
    jitter.push(packet: AudioPacket(sequence: 1, samples: [1, 2]))

    try expect(jitter.readForPlayback(frameCount: 2) == [1, 2], "primed jitter buffer should read audio")
    try expect(jitter.readForPlayback(frameCount: 2) == [0, 0], "underrun should produce silence")
    try expect(jitter.snapshot().underruns == 1, "underrun count should increment")
}

func testJitterBufferPlaysPartialAudioOnUnderrun() throws {
    let jitter = JitterBuffer(capacityFrames: 10, prebufferFrames: 2)
    jitter.push(packet: AudioPacket(sequence: 1, samples: [1, 2, 3]))

    try expect(jitter.readForPlayback(frameCount: 2) == [1, 2], "primed jitter buffer should read full audio")
    try expect(jitter.readForPlayback(frameCount: 2) == [3, 0], "partial underrun should keep available audio")
    try expect(jitter.snapshot().underruns == 1, "partial underrun should increment count")

    jitter.push(packet: AudioPacket(sequence: 2, samples: [4]))
    try expect(jitter.readForPlayback(frameCount: 2) == [4, 0], "jitter buffer should resume without re-prebuffering")
}

func testJitterBufferReadsPlaybackIntoReusableBuffer() throws {
    let jitter = JitterBuffer(capacityFrames: 10, prebufferFrames: 4)
    var output = Array(repeating: Float(9), count: 2)

    jitter.push(packet: AudioPacket(sequence: 1, samples: [1, 2, 3]))
    try expect(!jitter.readForPlayback(into: &output, frameCount: 2), "jitter buffer should report silence while prebuffering")
    try expect(output == [0, 0], "prebuffering should overwrite reusable buffer with silence")

    jitter.push(packet: AudioPacket(sequence: 2, samples: [4]))
    output = Array(repeating: Float(9), count: 2)
    try expect(jitter.readForPlayback(into: &output, frameCount: 2), "jitter buffer should report audio after priming")
    try expect(output == [1, 2], "primed reusable buffer should receive audio samples")

    output = Array(repeating: Float(9), count: 2)
    try expect(jitter.readForPlayback(into: &output, frameCount: 2), "remaining buffered audio should play")
    try expect(output == [3, 4], "reusable buffer should receive remaining samples")

    output = Array(repeating: Float(9), count: 2)
    try expect(!jitter.readForPlayback(into: &output, frameCount: 2), "underrun should report silence")
    try expect(output == [0, 0], "underrun should overwrite reusable buffer with silence")
}

func testAutomaticConnectionModeUsesUSBOnlyWhenIPhoneUSBIsDetected() throws {
    try expect(
        PhoneMicConnectionMode.automatic.preferredTransport(isIPhoneUSBConnected: true) == .usb,
        "automatic mode should prefer USB when an iPhone USB connection is detected"
    )
    try expect(
        PhoneMicConnectionMode.automatic.preferredTransport(isIPhoneUSBConnected: false) == .wifi,
        "automatic mode should fall back to Wi-Fi when no iPhone USB connection is detected"
    )
    try expect(
        PhoneMicConnectionMode.wired.preferredTransport(isIPhoneUSBConnected: false) == .usb,
        "manual wired mode should remain USB-only"
    )
    try expect(
        PhoneMicConnectionMode.wireless.preferredTransport(isIPhoneUSBConnected: true) == .wifi,
        "manual wireless mode should ignore USB detection"
    )
}

func testUSBSelectionRejectsNetworkOnlyIPhoneDevices() throws {
    let networkOnlyDevice = PhoneMicUSBDeviceCandidate(id: 1, connectionType: "Network")

    try expect(
        PhoneMicUSBConnectionSelection.preferredUSBDevice(from: [networkOnlyDevice]) == nil,
        "USB selection should not treat network-only iPhone devices as wired USB"
    )
}

func testUSBSelectionPrefersUSBConnectedIPhoneDevice() throws {
    let networkDevice = PhoneMicUSBDeviceCandidate(id: 1, connectionType: "Network")
    let usbDevice = PhoneMicUSBDeviceCandidate(id: 2, connectionType: "USB")

    try expect(
        PhoneMicUSBConnectionSelection.preferredUSBDevice(from: [networkDevice, usbDevice]) == usbDevice,
        "USB selection should choose the USB-connected iPhone device"
    )
}

func testAutomaticModeReappliesWhenUSBIsUnplugged() throws {
    try expect(
        PhoneMicAutomaticConnectionSwitch.shouldReapply(previousTransport: .usb, isIPhoneUSBConnected: false),
        "automatic mode should reapply when the previous USB transport is no longer available"
    )
    try expect(
        PhoneMicAutomaticConnectionSwitch.preferredTransport(isIPhoneUSBConnected: false) == .wifi,
        "automatic mode should fall back to Wi-Fi after USB is unplugged"
    )
}

func testConnectionResolutionSwitchesBothDirectionsInAutomaticMode() throws {
    let pluggedIn = PhoneMicConnectionResolution(
        mode: .automatic,
        currentTransport: .wifi,
        isIPhoneUSBConnected: true
    )
    try expect(pluggedIn.targetTransport == .usb, "automatic mode should switch from Wi-Fi to USB when iPhone USB appears")
    try expect(pluggedIn.shouldSwitchTransport, "automatic mode should reconfigure when USB appears")

    let unplugged = PhoneMicConnectionResolution(
        mode: .automatic,
        currentTransport: .usb,
        isIPhoneUSBConnected: false
    )
    try expect(unplugged.targetTransport == .wifi, "automatic mode should switch from USB to Wi-Fi when iPhone USB disappears")
    try expect(unplugged.shouldSwitchTransport, "automatic mode should reconfigure when USB disappears")
}

func testManualConnectionModesDoNotAutoFallback() throws {
    let wired = PhoneMicConnectionResolution(
        mode: .wired,
        currentTransport: .usb,
        isIPhoneUSBConnected: false
    )
    try expect(wired.targetTransport == .usb, "manual wired mode should stay USB-only even after unplug")
    try expect(!wired.shouldSwitchTransport, "manual wired mode should not switch itself to Wi-Fi")

    let wireless = PhoneMicConnectionResolution(
        mode: .wireless,
        currentTransport: .wifi,
        isIPhoneUSBConnected: true
    )
    try expect(wireless.targetTransport == .wifi, "manual wireless mode should stay Wi-Fi even when USB appears")
    try expect(!wireless.shouldSwitchTransport, "manual wireless mode should not switch itself to USB")
}

let tests: [(String, () throws -> Void)] = [
    ("packet round-trip", testPacketRoundTrip),
    ("control message round-trip", testControlMessageRoundTrip),
    ("status message round-trip", testStatusMessageRoundTrip),
    ("source handshake message round-trip", testSourceHandshakeMessageRoundTrip),
    ("iPhone initiated pairing model round-trip", testIPhoneInitiatedPairingModelRoundTrip),
    ("authentication code", testAuthenticationCode),
    ("partial packet buffering", testPartialPacketWaits),
    ("ring buffer overflow", testRingBufferDropsOldestFramesWhenFull),
    ("jitter prebuffer", testJitterBufferPrebuffersBeforePlayback),
    ("jitter underrun", testJitterBufferReturnsSilenceOnUnderrun),
    ("jitter partial underrun", testJitterBufferPlaysPartialAudioOnUnderrun),
    ("jitter reusable playback buffer", testJitterBufferReadsPlaybackIntoReusableBuffer),
    ("automatic connection mode transport selection", testAutomaticConnectionModeUsesUSBOnlyWhenIPhoneUSBIsDetected),
    ("USB selection rejects network-only iPhone devices", testUSBSelectionRejectsNetworkOnlyIPhoneDevices),
    ("USB selection prefers USB-connected iPhone devices", testUSBSelectionPrefersUSBConnectedIPhoneDevice),
    ("automatic mode reapplies when USB is unplugged", testAutomaticModeReappliesWhenUSBIsUnplugged),
    ("connection resolution switches both directions in automatic mode", testConnectionResolutionSwitchesBothDirectionsInAutomaticMode),
    ("manual connection modes do not auto fallback", testManualConnectionModesDoNotAutoFallback)
]

do {
    for (name, test) in tests {
        try test()
        print("PASS \(name)")
    }
    print("PhoneMicSelfTest passed \(tests.count) checks.")
} catch {
    fputs("FAIL \(error)\n", stderr)
    exit(1)
}
