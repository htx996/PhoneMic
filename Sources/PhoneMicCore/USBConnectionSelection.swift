import Foundation

public struct PhoneMicUSBDeviceCandidate: Equatable, Sendable {
    public var id: UInt32
    public var connectionType: String?

    public init(id: UInt32, connectionType: String?) {
        self.id = id
        self.connectionType = connectionType
    }

    public var isUSBConnected: Bool {
        connectionType?.localizedCaseInsensitiveCompare("USB") == .orderedSame
    }
}

public enum PhoneMicUSBConnectionSelection {
    public static func preferredUSBDevice(from candidates: [PhoneMicUSBDeviceCandidate]) -> PhoneMicUSBDeviceCandidate? {
        candidates.first(where: \.isUSBConnected)
    }
}
