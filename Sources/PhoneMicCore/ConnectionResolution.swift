public struct PhoneMicConnectionResolution: Equatable, Sendable {
    public var mode: PhoneMicConnectionMode
    public var currentTransport: PhoneMicTransportKind
    public var isIPhoneUSBConnected: Bool
    public var hasTrustedPeer: Bool

    public init(
        mode: PhoneMicConnectionMode,
        currentTransport: PhoneMicTransportKind,
        isIPhoneUSBConnected: Bool,
        hasTrustedPeer: Bool = true
    ) {
        self.mode = mode
        self.currentTransport = currentTransport
        self.isIPhoneUSBConnected = isIPhoneUSBConnected
        self.hasTrustedPeer = hasTrustedPeer
    }

    public var targetTransport: PhoneMicTransportKind {
        if mode == .automatic, isIPhoneUSBConnected, !hasTrustedPeer {
            return .wifi
        }
        return mode.preferredTransport(isIPhoneUSBConnected: isIPhoneUSBConnected)
    }

    public var shouldSwitchTransport: Bool {
        normalized(currentTransport) != normalized(targetTransport)
    }

    private func normalized(_ transport: PhoneMicTransportKind) -> PhoneMicTransportKind {
        switch transport {
        case .tcp, .wifi, .udpReserved, .quicReserved:
            return .wifi
        case .usb:
            return .usb
        }
    }
}
