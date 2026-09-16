public struct PhoneMicConnectionResolution: Equatable, Sendable {
    public var mode: PhoneMicConnectionMode
    public var currentTransport: PhoneMicTransportKind
    public var isIPhoneUSBConnected: Bool

    public init(
        mode: PhoneMicConnectionMode,
        currentTransport: PhoneMicTransportKind,
        isIPhoneUSBConnected: Bool
    ) {
        self.mode = mode
        self.currentTransport = currentTransport
        self.isIPhoneUSBConnected = isIPhoneUSBConnected
    }

    public var targetTransport: PhoneMicTransportKind {
        mode.preferredTransport(isIPhoneUSBConnected: isIPhoneUSBConnected)
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
