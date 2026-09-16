public enum PhoneMicConnectionMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case automatic
    case wireless
    case wired

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .automatic:
            return "自动"
        case .wireless:
            return "无线"
        case .wired:
            return "有线"
        }
    }

    public func preferredTransport(isIPhoneUSBConnected: Bool) -> PhoneMicTransportKind {
        switch self {
        case .automatic:
            return isIPhoneUSBConnected ? .usb : .wifi
        case .wireless:
            return .wifi
        case .wired:
            return .usb
        }
    }
}
