public struct PhoneMicPairingConnectionResolution: Equatable, Sendable {
    public var currentTransport: PhoneMicTransportKind
    public var discoveredTransport: PhoneMicTransportKind

    public init(
        currentTransport: PhoneMicTransportKind,
        discoveredTransport: PhoneMicTransportKind
    ) {
        self.currentTransport = currentTransport
        self.discoveredTransport = discoveredTransport
    }

    public var shouldForceWiFiPairing: Bool {
        normalized(currentTransport) != .wifi && normalized(discoveredTransport) == .wifi
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
