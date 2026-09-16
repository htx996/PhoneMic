import Foundation
import PhoneMicCore

struct PhoneMicUSBProxyStatus: Equatable {
    var isAvailable: Bool
    var isRunning: Bool
    var isIPhoneConnected: Bool
    var message: String
}

final class PhoneMicUSBProxy {
    private let lock = NSLock()
    private let usbCheckQueue = DispatchQueue(label: "PhoneMic.USBProxy.DeviceCheck", qos: .utility)
    private let usbCheckInterval: TimeInterval = 2.5
    private let processTimeout: TimeInterval = 1.0
    private var process: Process?
    private var lastFailureMessage: String?
    private var lastUSBCheckAt = Date.distantPast
    private var isUSBCheckInFlight = false
    private var cachedIPhoneConnected = false
    var onIPhoneUSBConnectionChanged: ((Bool) -> Void)?

    var status: PhoneMicUSBProxyStatus {
        lock.lock()
        let cachedValue = cachedIPhoneConnected
        lock.unlock()
        return makeStatus(isIPhoneConnected: cachedValue)
    }

    var refreshedStatus: PhoneMicUSBProxyStatus {
        makeStatus(isIPhoneConnected: refreshIPhoneUSBConnectionNow())
    }

    private func makeStatus(isIPhoneConnected: Bool) -> PhoneMicUSBProxyStatus {
        let isRunning: Bool
        let failureMessage: String?

        lock.lock()
        isRunning = process?.isRunning == true
        failureMessage = lastFailureMessage
        lock.unlock()

        if isRunning {
            return PhoneMicUSBProxyStatus(
                isAvailable: true,
                isRunning: true,
                isIPhoneConnected: isIPhoneConnected,
                message: isIPhoneConnected ? "USB 代理运行中" : "USB 代理运行中，等待 iPhone USB"
            )
        }

        if let lastFailureMessage = failureMessage {
            let message = isIPhoneConnected
                ? "已检测到 iPhone USB，但\(lastFailureMessage)"
                : lastFailureMessage
            return PhoneMicUSBProxyStatus(
                isAvailable: false,
                isRunning: false,
                isIPhoneConnected: isIPhoneConnected,
                message: message
            )
        }

        guard bundledHelperURL() != nil else {
            return PhoneMicUSBProxyStatus(
                isAvailable: false,
                isRunning: false,
                isIPhoneConnected: isIPhoneConnected,
                message: "USB 代理未随开发版打包"
            )
        }

        return PhoneMicUSBProxyStatus(
            isAvailable: true,
            isRunning: false,
            isIPhoneConnected: isIPhoneConnected,
            message: isIPhoneConnected ? "已检测到 iPhone USB" : "等待 iPhone USB"
        )
    }

    func startIfAvailable() {
        lock.lock()
        lastFailureMessage = nil
        let alreadyRunning = process?.isRunning == true
        lock.unlock()

        guard !alreadyRunning, let helperURL = bundledHelperURL() else { return }

        let process = Process()
        process.executableURL = helperURL
        process.arguments = [
            "--local-port", "\(PhoneMicAudio.audioPort)",
            "--device-port", "\(PhoneMicAudio.audioPort)",
            "--control-port", "\(PhoneMicAudio.controlPort)"
        ]
        process.standardOutput = Pipe()
        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.terminationHandler = { [weak self, weak errorPipe] process in
            guard process.terminationStatus != 0 else { return }
            let errorData = errorPipe?.fileHandleForReading.readDataToEndOfFile() ?? Data()
            let message = String(data: errorData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let fallback = "USB helper 启动失败（退出码 \(process.terminationStatus)）"
            self?.lock.lock()
            self?.lastFailureMessage = message?.isEmpty == false ? message! : fallback
            self?.process = nil
            self?.lock.unlock()
        }

        do {
            try process.run()
            lock.lock()
            self.process = process
            lock.unlock()
        } catch {
            lock.lock()
            lastFailureMessage = "USB helper 启动失败：\(error.localizedDescription)"
            lock.unlock()
            NSLog("PhoneMic USB proxy: failed to start helper: \(error.localizedDescription)")
        }
    }

    func stop() {
        lock.lock()
        let process = process
        self.process = nil
        lastFailureMessage = nil
        lock.unlock()
        process?.terminate()
    }

    func requestIPhoneUSBRefresh(force: Bool = false) {
        refreshIPhoneUSBConnectionIfNeeded(force: force)
    }

    private func refreshIPhoneUSBConnectionNow() -> Bool {
        let helperURL = bundledHelperURL()
        let detected: Bool
        if let helperURL {
            detected = Self.detectIPhoneUSBConnection(using: helperURL, timeout: processTimeout)
        } else {
            detected = Self.detectIPhoneUSBConnectionFromIORegistry(timeout: processTimeout)
        }

        lock.lock()
        let previousValue = cachedIPhoneConnected
        cachedIPhoneConnected = detected
        isUSBCheckInFlight = false
        lastUSBCheckAt = Date()
        lock.unlock()

        if previousValue != detected {
            DispatchQueue.main.async {
                self.onIPhoneUSBConnectionChanged?(detected)
            }
        }

        return detected
    }

    private func bundledHelperURL() -> URL? {
        Bundle.main.url(forResource: "phonemic-usbproxy", withExtension: nil)
    }

    @discardableResult
    private func refreshIPhoneUSBConnectionIfNeeded(force: Bool = false) -> Bool {
        let now = Date()
        lock.lock()
        let cachedValue = cachedIPhoneConnected
        guard force || now.timeIntervalSince(lastUSBCheckAt) > usbCheckInterval,
              !isUSBCheckInFlight else {
            lock.unlock()
            return cachedValue
        }

        lastUSBCheckAt = now
        isUSBCheckInFlight = true
        lock.unlock()

        let helperURL = bundledHelperURL()
        usbCheckQueue.async { [weak self] in
            guard let self else { return }
            let detected: Bool
            if let helperURL {
                detected = Self.detectIPhoneUSBConnection(using: helperURL, timeout: processTimeout)
            } else {
                detected = Self.detectIPhoneUSBConnectionFromIORegistry(timeout: processTimeout)
            }

            lock.lock()
            let previousValue = cachedIPhoneConnected
            cachedIPhoneConnected = detected
            isUSBCheckInFlight = false
            lock.unlock()

            if previousValue != detected {
                DispatchQueue.main.async {
                    self.onIPhoneUSBConnectionChanged?(detected)
                }
            }
        }

        return cachedValue
    }

    private static func detectIPhoneUSBConnection(using helperURL: URL, timeout: TimeInterval) -> Bool {
        let process = Process()
        process.executableURL = helperURL
        process.arguments = ["--check"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return detectIPhoneUSBConnectionFromIORegistry(timeout: timeout)
        }

        guard waitForExit(process, timeout: timeout) else { return false }

        return process.terminationStatus == 0
    }

    private static func detectIPhoneUSBConnectionFromIORegistry(timeout: TimeInterval) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/ioreg")
        process.arguments = ["-p", "IOUSB", "-l", "-w", "0"]

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return false
        }

        guard waitForExit(process, timeout: timeout) else { return false }
        guard process.terminationStatus == 0 else { return false }
        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return false }
        return output.contains("\"USB Product Name\" = \"iPhone\"")
            || output.contains("\"USB Product Name\" = \"iPad\"")
            || output.contains("\"SupportsIPhoneOS\" = Yes")
    }

    private static func waitForExit(_ process: Process, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        guard process.isRunning else { return true }
        process.terminate()
        let terminateDeadline = Date().addingTimeInterval(0.2)
        while process.isRunning, Date() < terminateDeadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        return !process.isRunning
    }
}
