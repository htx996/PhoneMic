import CoreAudio
import Foundation

enum AudioDeviceFinder {
    static func findOutputDevice(containing nameFragment: String) throws -> (id: AudioDeviceID, name: String)? {
        try allOutputDevices().first {
            $0.name.localizedCaseInsensitiveContains(nameFragment)
        }
    }

    static func findInputDevice(containing nameFragment: String) throws -> (id: AudioDeviceID, name: String)? {
        try allInputDevices().first {
            $0.name.localizedCaseInsensitiveContains(nameFragment)
        }
    }

    static func allOutputDevices() throws -> [(id: AudioDeviceID, name: String)] {
        try allDevices(scope: kAudioDevicePropertyScopeOutput)
    }

    static func allInputDevices() throws -> [(id: AudioDeviceID, name: String)] {
        try allDevices(scope: kAudioDevicePropertyScopeInput)
    }

    static func deviceUID(_ deviceID: AudioDeviceID) throws -> CFString {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var uid: CFString = "" as CFString
        var dataSize = UInt32(MemoryLayout<CFString>.size)
        let status = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &dataSize,
            &uid
        )

        guard status == noErr else { throw AudioDeviceFinderError.coreAudio(status) }
        return uid
    }

    static func defaultInputDeviceName() throws -> String? {
        guard let deviceID = try defaultInputDeviceID() else { return nil }
        return try deviceName(deviceID)
    }

    static func defaultInputDeviceID() throws -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var deviceID = AudioDeviceID(0)
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize,
            &deviceID
        )

        guard status == noErr else { throw AudioDeviceFinderError.coreAudio(status) }
        guard deviceID != 0 else { return nil }
        return deviceID
    }

    static func setDefaultInputDevice(_ deviceID: AudioDeviceID) throws {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var mutableDeviceID = deviceID
        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            UInt32(MemoryLayout<AudioDeviceID>.size),
            &mutableDeviceID
        )
        guard status == noErr else { throw AudioDeviceFinderError.coreAudio(status) }
    }

    static func selectBlackHoleAsDefaultInput() -> String {
        do {
            guard let blackHole = try findInputDevice(containing: "BlackHole") else {
                return "未安装 BlackHole"
            }

            let defaultInputName = try defaultInputDeviceName()
            if defaultInputName?.localizedCaseInsensitiveContains("BlackHole") == true {
                return "已选择 \(blackHole.name)"
            }

            try setDefaultInputDevice(blackHole.id)
            return "已选择 \(blackHole.name)"
        } catch {
            return "CoreAudio 切换失败"
        }
    }

    static func restoreDefaultInputDevice(_ deviceID: AudioDeviceID?) -> String {
        guard let deviceID else { return "没有可恢复的输入" }
        do {
            try setDefaultInputDevice(deviceID)
            return "已恢复 \(try deviceName(deviceID))"
        } catch {
            return "CoreAudio 恢复失败"
        }
    }

    static func blackHoleInputStatus() -> String {
        do {
            guard let blackHole = try findInputDevice(containing: "BlackHole") else {
                return "未安装 BlackHole"
            }

            let defaultInputName = try defaultInputDeviceName()
            if defaultInputName?.localizedCaseInsensitiveContains("BlackHole") == true {
                return "已选择 \(blackHole.name)"
            }

            if let defaultInputName, !defaultInputName.isEmpty {
                return "已安装，当前输入为 \(defaultInputName)"
            }

            return "已安装 \(blackHole.name)"
        } catch {
            return "CoreAudio 查询失败"
        }
    }

    private static func allDevices(scope: AudioObjectPropertyScope) throws -> [(id: AudioDeviceID, name: String)] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize
        )
        guard status == noErr else { throw AudioDeviceFinderError.coreAudio(status) }

        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var devices = Array(repeating: AudioDeviceID(0), count: deviceCount)

        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize,
            &devices
        )
        guard status == noErr else { throw AudioDeviceFinderError.coreAudio(status) }

        return devices.compactMap { deviceID in
            guard (try? hasStreams(deviceID, scope: scope)) == true else { return nil }
            let name = (try? deviceName(deviceID)) ?? "Audio Device \(deviceID)"
            return (id: deviceID, name: name)
        }
    }

    private static func hasStreams(_ deviceID: AudioDeviceID, scope: AudioObjectPropertyScope) throws -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(
            deviceID,
            &address,
            0,
            nil,
            &dataSize
        )
        guard status == noErr else { throw AudioDeviceFinderError.coreAudio(status) }

        return dataSize > 0
    }

    private static func deviceName(_ deviceID: AudioDeviceID) throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var name: CFString = "" as CFString
        var dataSize = UInt32(MemoryLayout<CFString>.size)
        let status = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &dataSize,
            &name
        )

        guard status == noErr else { throw AudioDeviceFinderError.coreAudio(status) }
        return name as String
    }
}

enum AudioDeviceFinderError: LocalizedError {
    case coreAudio(OSStatus)

    var errorDescription: String? {
        switch self {
        case .coreAudio(let status):
            return "CoreAudio device query failed with status \(status)."
        }
    }
}
