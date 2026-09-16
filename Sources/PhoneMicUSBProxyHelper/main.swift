import Darwin
import Foundation
import PhoneMicCore

private enum ExitCode {
    static let ok: Int32 = 0
    static let usage: Int32 = 64
    static let unavailable: Int32 = 69
    static let software: Int32 = 70
}

private struct Options {
    var checkOnly = false
    var localPort = Int(PhoneMicAudio.audioPort)
    var devicePort = Int(PhoneMicAudio.audioPort)
    var controlPort = Int(PhoneMicAudio.controlPort)
}

private enum HelperError: LocalizedError {
    case invalidArgument(String)
    case usbmuxUnavailable(String)
    case noDevice
    case protocolError(String)
    case launchFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidArgument(let argument):
            return "无效参数：\(argument)"
        case .usbmuxUnavailable(let message):
            return "USB 转发不可用：\(message)"
        case .noDevice:
            return "未检测到已通过 USB 连接的 iPhone。请确认数据线已连接，并在 iPhone 上点过“信任”。"
        case .protocolError(let message):
            return "USB 转发协议错误：\(message)"
        case .launchFailed(let message):
            return "USB 转发启动失败：\(message)"
        }
    }
}

private func parseOptions(_ arguments: [String]) throws -> Options {
    var options = Options()
    var index = 1

    while index < arguments.count {
        let argument = arguments[index]
        switch argument {
        case "--check":
            options.checkOnly = true
            index += 1
        case "--local-port":
            guard index + 1 < arguments.count, let value = Int(arguments[index + 1]) else {
                throw HelperError.invalidArgument(argument)
            }
            options.localPort = value
            index += 2
        case "--device-port":
            guard index + 1 < arguments.count, let value = Int(arguments[index + 1]) else {
                throw HelperError.invalidArgument(argument)
            }
            options.devicePort = value
            index += 2
        case "--control-port":
            guard index + 1 < arguments.count, let value = Int(arguments[index + 1]) else {
                throw HelperError.invalidArgument(argument)
            }
            options.controlPort = value
            index += 2
        case "--help", "-h":
            printUsage()
            exit(ExitCode.ok)
        default:
            throw HelperError.invalidArgument(argument)
        }
    }

    return options
}

private func printUsage() {
    print("""
    usage: phonemic-usbproxy [--check] [--local-port PORT] [--device-port PORT] [--control-port PORT]

    PhoneMic USB proxy helper. It uses macOS usbmuxd directly and does not require
    Homebrew, iproxy, or libimobiledevice.
    """)
}

private enum USBMux {
    private static let socketPath = "/var/run/usbmuxd"
    private static let protocolVersion: UInt32 = 1
    private static let plistMessage: UInt32 = 8
    private static var nextTag: UInt32 = 1

    struct Device {
        var id: UInt32
        var serialNumber: String?
        var connectionType: String?

        var isUSBConnected: Bool {
            connectionType?.localizedCaseInsensitiveCompare("USB") == .orderedSame
        }

        var candidate: PhoneMicUSBDeviceCandidate {
            PhoneMicUSBDeviceCandidate(id: id, connectionType: connectionType)
        }
    }

    static func availableDevices() throws -> [Device] {
        let fd = try openSocket()
        defer { close(fd) }

        let response = try request(
            [
                "MessageType": "ListDevices",
                "ClientVersionString": "PhoneMic",
                "ProgName": "PhoneMic"
            ],
            on: fd
        )

        guard let rawDevices = response["DeviceList"] as? [[String: Any]] else {
            throw HelperError.protocolError("usbmuxd 没有返回设备列表。")
        }

        return rawDevices.compactMap { item in
            guard let deviceID = item["DeviceID"] as? NSNumber else { return nil }
            let properties = item["Properties"] as? [String: Any]
            return Device(
                id: deviceID.uint32Value,
                serialNumber: properties?["SerialNumber"] as? String,
                connectionType: properties?["ConnectionType"] as? String
            )
        }
    }

    static func preferredDevice() throws -> Device {
        let devices = try availableDevices()
        guard let candidate = PhoneMicUSBConnectionSelection.preferredUSBDevice(from: devices.map(\.candidate)),
              let device = devices.first(where: { $0.id == candidate.id }) else {
            throw HelperError.noDevice
        }
        return device
    }

    static func connectToPreferredDevice(port: Int) throws -> Int32 {
        let device = try preferredDevice()
        let fd = try openSocket()
        do {
            let response = try request(
                [
                    "MessageType": "Connect",
                    "ClientVersionString": "PhoneMic",
                    "ProgName": "PhoneMic",
                    "DeviceID": NSNumber(value: device.id),
                    "PortNumber": NSNumber(value: UInt16(port).bigEndian)
                ],
                on: fd
            )

            let result = (response["Number"] as? NSNumber)?.intValue ?? -1
            guard result == 0 else {
                close(fd)
                throw HelperError.protocolError("iPhone 拒绝连接端口 \(port)，错误码 \(result)。")
            }
            return fd
        } catch {
            close(fd)
            throw error
        }
    }

    private static func openSocket() throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw HelperError.usbmuxUnavailable(String(cString: strerror(errno)))
        }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            close(fd)
            throw HelperError.usbmuxUnavailable("usbmuxd 路径过长。")
        }

        let sunPathCapacity = MemoryLayout.size(ofValue: address.sun_path)
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: sunPathCapacity) { buffer in
                for index in 0..<pathBytes.count {
                    buffer[index] = CChar(bitPattern: pathBytes[index])
                }
                buffer[pathBytes.count] = 0
            }
        }

        let length = socklen_t(MemoryLayout<sa_family_t>.size + pathBytes.count + 1)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.connect(fd, socketAddress, length)
            }
        }

        guard result == 0 else {
            let message = String(cString: strerror(errno))
            close(fd)
            throw HelperError.usbmuxUnavailable(message)
        }

        return fd
    }

    private static func request(_ propertyList: [String: Any], on fd: Int32) throws -> [String: Any] {
        let payload = try PropertyListSerialization.data(
            fromPropertyList: propertyList,
            format: .xml,
            options: 0
        )
        let tag = nextTag
        nextTag += 1

        var packet = Data()
        packet.appendUInt32LittleEndian(UInt32(payload.count + 16))
        packet.appendUInt32LittleEndian(protocolVersion)
        packet.appendUInt32LittleEndian(plistMessage)
        packet.appendUInt32LittleEndian(tag)
        packet.append(payload)
        try writeAll(packet, to: fd)

        let header = try readExactly(16, from: fd)
        let length = Int(header.uint32LittleEndian(at: 0))
        let messageType = header.uint32LittleEndian(at: 8)
        guard length >= 16 else {
            throw HelperError.protocolError("usbmuxd 返回了无效长度。")
        }
        guard messageType == plistMessage else {
            throw HelperError.protocolError("usbmuxd 返回了非 plist 消息。")
        }

        let responsePayload = try readExactly(length - 16, from: fd)
        let object = try PropertyListSerialization.propertyList(from: responsePayload, options: [], format: nil)
        guard let response = object as? [String: Any] else {
            throw HelperError.protocolError("usbmuxd 返回内容无法解析。")
        }
        return response
    }
}

private final class PortForwarder {
    private let localPort: Int
    private let devicePort: Int
    private let listenerFD: Int32
    private let queue: DispatchQueue
    private var isStopped = false
    private let lock = NSLock()

    init(localPort: Int, devicePort: Int, label: String) throws {
        self.localPort = localPort
        self.devicePort = devicePort
        queue = DispatchQueue(label: "PhoneMic.USBProxy.\(label)")
        listenerFD = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard listenerFD >= 0 else {
            throw HelperError.launchFailed(String(cString: strerror(errno)))
        }

        var reuse: Int32 = 1
        setsockopt(listenerFD, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(localPort).bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                bind(listenerFD, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        guard bindResult == 0 else {
            let message = String(cString: strerror(errno))
            close(listenerFD)
            throw HelperError.launchFailed("无法监听本地端口 \(localPort)：\(message)")
        }

        guard listen(listenerFD, SOMAXCONN) == 0 else {
            let message = String(cString: strerror(errno))
            close(listenerFD)
            throw HelperError.launchFailed("无法启动本地监听 \(localPort)：\(message)")
        }
    }

    func start() {
        queue.async { [weak self] in
            self?.acceptLoop()
        }
    }

    func stop() {
        lock.lock()
        let shouldClose = !isStopped
        isStopped = true
        lock.unlock()
        if shouldClose {
            shutdown(listenerFD, SHUT_RDWR)
            close(listenerFD)
        }
    }

    private func acceptLoop() {
        while !stopped {
            let clientFD = accept(listenerFD, nil, nil)
            if clientFD < 0 {
                if stopped { return }
                continue
            }

            DispatchQueue.global(qos: .userInitiated).async { [devicePort] in
                do {
                    let deviceFD = try USBMux.connectToPreferredDevice(port: devicePort)
                    ForwardedConnection(clientFD: clientFD, deviceFD: deviceFD).start()
                } catch {
                    fputs(("USB 转发连接失败：\(error.localizedDescription)\n"), stderr)
                    close(clientFD)
                }
            }
        }
    }

    private var stopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isStopped
    }
}

private final class ForwardedConnection {
    private let clientFD: Int32
    private let deviceFD: Int32
    private let lock = NSLock()
    private var isClosed = false

    init(clientFD: Int32, deviceFD: Int32) {
        self.clientFD = clientFD
        self.deviceFD = deviceFD
    }

    func start() {
        DispatchQueue.global(qos: .userInitiated).async {
            self.pump(from: self.clientFD, to: self.deviceFD)
        }
        DispatchQueue.global(qos: .userInitiated).async {
            self.pump(from: self.deviceFD, to: self.clientFD)
        }
    }

    private func pump(from source: Int32, to destination: Int32) {
        guard source >= 0, destination >= 0 else {
            closeBoth()
            return
        }

        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = recv(source, &buffer, buffer.count, 0)
            if count <= 0 {
                closeBoth()
                return
            }

            do {
                try buffer.withUnsafeBytes { rawBuffer in
                    guard let baseAddress = rawBuffer.baseAddress else { return }
                    try writeAll(baseAddress, count: count, to: destination)
                }
            } catch {
                closeBoth()
                return
            }
        }
    }

    private func closeBoth() {
        lock.lock()
        let shouldClose = !isClosed
        isClosed = true
        lock.unlock()

        if shouldClose {
            shutdown(clientFD, SHUT_RDWR)
            shutdown(deviceFD, SHUT_RDWR)
            close(clientFD)
            close(deviceFD)
        }
    }
}

private func readExactly(_ byteCount: Int, from fd: Int32) throws -> Data {
    var data = Data()
    data.reserveCapacity(byteCount)
    var buffer = [UInt8](repeating: 0, count: min(4096, max(byteCount, 1)))

    while data.count < byteCount {
        let remaining = byteCount - data.count
        let count = recv(fd, &buffer, min(buffer.count, remaining), 0)
        guard count > 0 else {
            throw HelperError.protocolError("连接过早关闭。")
        }
        data.append(buffer, count: count)
    }

    return data
}

private func writeAll(_ data: Data, to fd: Int32) throws {
    try data.withUnsafeBytes { rawBuffer in
        guard let baseAddress = rawBuffer.baseAddress else { return }
        try writeAll(baseAddress, count: data.count, to: fd)
    }
}

private func writeAll(_ baseAddress: UnsafeRawPointer, count: Int, to fd: Int32) throws {
    var sent = 0
    while sent < count {
        let result = send(fd, baseAddress.advanced(by: sent), count - sent, 0)
        guard result > 0 else {
            throw HelperError.protocolError(String(cString: strerror(errno)))
        }
        sent += result
    }
}

private extension Data {
    mutating func appendUInt32LittleEndian(_ value: UInt32) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }

    func uint32LittleEndian(at offset: Int) -> UInt32 {
        var value: UInt32 = 0
        _ = Swift.withUnsafeMutableBytes(of: &value) { valueBuffer in
            copyBytes(to: valueBuffer, from: offset..<(offset + 4))
        }
        return UInt32(littleEndian: value)
    }
}

private func run() throws {
    let options = try parseOptions(CommandLine.arguments)
    let device = try USBMux.preferredDevice()

    if options.checkOnly {
        let serial = device.serialNumber.map { "（\($0)）" } ?? ""
        let connectionType = device.connectionType.map { "，连接：\($0)" } ?? ""
        print("USB 转发可用：已检测到 iPhone\(serial)\(connectionType)")
        return
    }

    let audioForwarder = try PortForwarder(
        localPort: options.localPort,
        devicePort: options.devicePort,
        label: "audio"
    )
    let controlForwarder = try PortForwarder(
        localPort: options.controlPort,
        devicePort: options.controlPort,
        label: "control"
    )
    audioForwarder.start()
    controlForwarder.start()

    signal(SIGTERM, SIG_IGN)
    signal(SIGINT, SIG_IGN)

    let terminationSemaphore = DispatchSemaphore(value: 0)
    let signalQueue = DispatchQueue(label: "PhoneMic.USBProxy.Signal")

    let termSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: signalQueue)
    termSource.setEventHandler {
        audioForwarder.stop()
        controlForwarder.stop()
        terminationSemaphore.signal()
    }
    termSource.resume()

    let interruptSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: signalQueue)
    interruptSource.setEventHandler {
        audioForwarder.stop()
        controlForwarder.stop()
        terminationSemaphore.signal()
    }
    interruptSource.resume()

    print("USB 代理运行中：audio 127.0.0.1:\(options.localPort)->iPhone:\(options.devicePort), control 127.0.0.1:\(options.controlPort)->iPhone:\(options.controlPort)")
    terminationSemaphore.wait()
}

do {
    try run()
    exit(ExitCode.ok)
} catch let error as HelperError {
    fputs((error.localizedDescription + "\n"), stderr)
    switch error {
    case .invalidArgument:
        exit(ExitCode.usage)
    case .usbmuxUnavailable, .noDevice:
        exit(ExitCode.unavailable)
    case .protocolError, .launchFailed:
        exit(ExitCode.software)
    }
} catch {
    fputs(("USB helper error: \(error.localizedDescription)\n"), stderr)
    exit(ExitCode.software)
}
