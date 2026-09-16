public enum PhoneMicAutomaticConnectionSwitch {
    public static func preferredTransport(isIPhoneUSBConnected: Bool) -> PhoneMicTransportKind {
        PhoneMicConnectionMode.automatic.preferredTransport(isIPhoneUSBConnected: isIPhoneUSBConnected)
    }

    public static func shouldReapply(previousTransport: PhoneMicTransportKind, isIPhoneUSBConnected: Bool) -> Bool {
        preferredTransport(isIPhoneUSBConnected: isIPhoneUSBConnected) != previousTransport
    }
}
