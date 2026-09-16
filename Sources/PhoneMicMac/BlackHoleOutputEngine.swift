import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation
import PhoneMicCore

final class BlackHoleOutputEngine: MicrophoneOutputEngine {
    private static let outputFramesPerBuffer = 480
    private static let blackHoleQueueBufferCount = 4
    private static let maximumBlackHoleBuffersInFlight = 8
    private static let blackHoleRestartCooldownSeconds: TimeInterval = 1.5
    private let jitterBuffer: JitterBuffer
    private let monitorEngine = AVAudioEngine()
    private let monitorPlayer = AVAudioPlayerNode()
    private let renderQueue = DispatchQueue(label: "PhoneMic.BlackHoleOutputEngine")
    private let gainLock = NSLock()
    private let statsLock = NSLock()
    private let audioQueueLock = NSLock()
    private var previousHighPassInput: Float = 0
    private var previousHighPassOutput: Float = 0
    private var smoothedVoiceGain: Float = 1
    private var smoothedNoiseGateGain: Float = 1
    private var storedProcessingSnapshot = AudioProcessingSnapshot()
    private var timer: DispatchSourceTimer?
    private var format: AVAudioFormat?
    private var selectedDeviceName = "Default Output"
    private var selectedMonitorName = "Mac 扬声器"
    private var storedGainDecibels: Float = 10
    private var storedProcessingMode: AudioProcessingMode = .voice
    private var storedTuningSettings = AudioTuningSettings()
    private var storedMonitoringEnabled = true
    private var didConfigureMonitorEngine = false
    private var blackHoleQueue: AudioQueueRef?
    private var blackHoleDeviceID: AudioDeviceID?
    private var blackHoleBuffersInFlight = 0
    private var blackHoleConsecutiveEnqueueFailures = 0
    private var lastBlackHoleRestartAt = Date.distantPast
    private var lastBlackHoleEnqueueAt = Date.distantPast
    private var lastBlackHoleCallbackAt = Date.distantPast
    private var reusableBlackHoleBuffers: [AudioQueueBufferRef] = []
    private var renderInputSamples = Array(repeating: Float(0), count: outputFramesPerBuffer)
    private var renderVoiceSamples = Array(repeating: Float(0), count: outputFramesPerBuffer)
    private var renderOutputSamplesBuffer = Array(repeating: Float(0), count: outputFramesPerBuffer)

    var outputName: String {
        selectedDeviceName
    }

    var monitorName: String {
        selectedMonitorName
    }

    var gainDecibels: Float {
        get {
            gainLock.withLock { storedGainDecibels }
        }
        set {
            gainLock.withLock {
                storedGainDecibels = min(max(newValue, 0), 12)
            }
        }
    }

    var processingMode: AudioProcessingMode {
        get {
            gainLock.withLock { storedProcessingMode }
        }
        set {
            gainLock.withLock {
                storedProcessingMode = newValue
                previousHighPassInput = 0
                previousHighPassOutput = 0
                smoothedVoiceGain = 1
                smoothedNoiseGateGain = 1
            }
        }
    }

    var tuningSettings: AudioTuningSettings {
        get {
            gainLock.withLock { storedTuningSettings }
        }
        set {
            gainLock.withLock {
                storedTuningSettings = newValue.clamped()
            }
        }
    }

    var processingSnapshot: AudioProcessingSnapshot {
        statsLock.withLock { storedProcessingSnapshot }
    }

    var monitoringEnabled: Bool {
        get {
            gainLock.withLock { storedMonitoringEnabled }
        }
        set {
            gainLock.withLock {
                storedMonitoringEnabled = newValue
            }
        }
    }

    init(jitterBuffer: JitterBuffer) {
        self.jitterBuffer = jitterBuffer
    }

    func start() throws {
        let audioFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: PhoneMicAudio.sampleRate,
            channels: AVAudioChannelCount(PhoneMicAudio.channels),
            interleaved: false
        )!
        format = audioFormat

        guard let blackHole = try AudioDeviceFinder.findOutputDevice(containing: "BlackHole") else {
            selectedDeviceName = "未安装 BlackHole 2ch"
            throw BlackHoleOutputError.blackHoleNotInstalled
        }

        selectedDeviceName = blackHole.name
        try startBlackHoleQueue(deviceID: blackHole.id)

        startMonitoringIfPossible(format: audioFormat)
        startHealthMonitoring()
    }

    func stop() {
        timer?.cancel()
        timer = nil
        stopBlackHoleQueue()
        monitorPlayer.stop()
        monitorEngine.stop()
    }

    private func startBlackHoleQueue(deviceID: AudioDeviceID) throws {
        stopBlackHoleQueue()

        var streamDescription = AudioStreamBasicDescription(
            mSampleRate: PhoneMicAudio.sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(2 * MemoryLayout<Float>.size),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(2 * MemoryLayout<Float>.size),
            mChannelsPerFrame: 2,
            mBitsPerChannel: 32,
            mReserved: 0
        )

        var queue: AudioQueueRef?
        var status = AudioQueueNewOutput(
            &streamDescription,
            blackHoleAudioQueueCallback,
            Unmanaged.passUnretained(self).toOpaque(),
            nil,
            nil,
            0,
            &queue
        )
        guard status == noErr, let queue else {
            throw BlackHoleOutputError.cannotCreateAudioQueue(status)
        }

        var uid = try AudioDeviceFinder.deviceUID(deviceID)
        status = withUnsafePointer(to: &uid) {
            AudioQueueSetProperty(
                queue,
                kAudioQueueProperty_CurrentDevice,
                $0,
                UInt32(MemoryLayout<CFString>.size)
            )
        }
        guard status == noErr else {
            AudioQueueDispose(queue, true)
            throw BlackHoleOutputError.cannotSelectDevice(status)
        }

        audioQueueLock.withLock {
            blackHoleQueue = queue
            blackHoleDeviceID = deviceID
            blackHoleBuffersInFlight = 0
            blackHoleConsecutiveEnqueueFailures = 0
            let now = Date()
            lastBlackHoleEnqueueAt = now
            lastBlackHoleCallbackAt = now
            reusableBlackHoleBuffers.removeAll()
        }

        let bufferByteCount = UInt32(Self.outputFramesPerBuffer * 2 * MemoryLayout<Float>.size)
        for _ in 0..<Self.blackHoleQueueBufferCount {
            var buffer: AudioQueueBufferRef?
            status = AudioQueueAllocateBuffer(queue, bufferByteCount, &buffer)
            guard status == noErr, let buffer else {
                AudioQueueDispose(queue, true)
                throw BlackHoleOutputError.cannotCreateAudioQueue(status)
            }
            fillAndEnqueueBlackHoleBuffer(buffer)
        }

        status = AudioQueueStart(queue, nil)
        guard status == noErr else {
            AudioQueueDispose(queue, true)
            throw BlackHoleOutputError.cannotStartAudioQueue(status)
        }
    }

    private func stopBlackHoleQueue() {
        let queue = audioQueueLock.withLock { () -> AudioQueueRef? in
            let queue = blackHoleQueue
            blackHoleQueue = nil
            blackHoleDeviceID = nil
            blackHoleBuffersInFlight = 0
            blackHoleConsecutiveEnqueueFailures = 0
            reusableBlackHoleBuffers.removeAll()
            return queue
        }

        if let queue {
            AudioQueueStop(queue, true)
            AudioQueueDispose(queue, true)
        }
    }

    fileprivate func handleBlackHoleBufferCompleted(queue callbackQueue: AudioQueueRef, buffer: AudioQueueBufferRef) {
        renderQueue.async { [weak self] in
            guard let self else { return }
            let shouldRefill = self.audioQueueLock.withLock { () -> Bool in
                guard self.blackHoleQueue == callbackQueue else { return false }
                if self.blackHoleBuffersInFlight > 0 {
                    self.blackHoleBuffersInFlight -= 1
                }
                self.lastBlackHoleCallbackAt = Date()
                return true
            }
            guard shouldRefill else { return }
            self.fillAndEnqueueBlackHoleBuffer(buffer)
        }
    }

    private func restartBlackHoleQueue(reason: String) {
        let now = Date()
        let canRestart = audioQueueLock.withLock { () -> Bool in
            guard now.timeIntervalSince(lastBlackHoleRestartAt) >= Self.blackHoleRestartCooldownSeconds else {
                return false
            }
            lastBlackHoleRestartAt = now
            return true
        }
        guard canRestart else { return }

        do {
            let deviceID: AudioDeviceID
            if let currentDeviceID = audioQueueLock.withLock({ blackHoleDeviceID }) {
                deviceID = currentDeviceID
            } else if let blackHole = try AudioDeviceFinder.findOutputDevice(containing: "BlackHole") {
                deviceID = blackHole.id
                selectedDeviceName = blackHole.name
            } else {
                NSLog("PhoneMic output: cannot restart BlackHole queue; device missing after \(reason)")
                return
            }

            try startBlackHoleQueue(deviceID: deviceID)
            NSLog("PhoneMic output: restarted BlackHole queue after \(reason)")
        } catch {
            NSLog("PhoneMic output: failed to restart BlackHole queue after \(reason): \(error.localizedDescription)")
        }
    }

    private func startMonitoringIfPossible(format audioFormat: AVAudioFormat) {
        if !didConfigureMonitorEngine {
            monitorEngine.attach(monitorPlayer)
            monitorEngine.connect(monitorPlayer, to: monitorEngine.mainMixerNode, format: audioFormat)
            didConfigureMonitorEngine = true
        }

        do {
            try monitorEngine.start()
            if !monitorPlayer.isPlaying {
                monitorPlayer.play()
            }
            selectedMonitorName = "Mac 扬声器"
        } catch {
            selectedMonitorName = "监听不可用"
            NSLog("PhoneMic monitor output failed: \(error.localizedDescription)")
        }
    }

    private func startHealthMonitoring() {
        let timer = DispatchSource.makeTimerSource(queue: renderQueue)
        timer.schedule(deadline: .now() + .milliseconds(500), repeating: .milliseconds(500), leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in
            guard let self, let restartReason = self.blackHoleRestartReason() else { return }
            self.restartBlackHoleQueue(reason: restartReason)
        }
        self.timer = timer
        timer.resume()
    }

    private struct AudioRenderSettingsSnapshot {
        var gainMultiplier: Float
        var processingMode: AudioProcessingMode
        var tuningSettings: AudioTuningSettings
        var monitoringEnabled: Bool
        var blackHoleOutputBoostMultiplier: Float
        var finalLimiterCeiling: Float
    }

    private func renderOutputSamples(frameCount: Int, settings: AudioRenderSettingsSnapshot) -> Bool {
        ensureRenderBuffers(frameCount: frameCount)
        let hasBufferedAudio = jitterBuffer.readForPlayback(into: &renderInputSamples, frameCount: frameCount)
        guard hasBufferedAudio else {
            fillRenderOutputWithSilence(frameCount: frameCount)
            updateProcessingSnapshot(inputRMS: 0, outputPeak: 0, automaticGain: 1, limiterHits: 0)
            return false
        }

        var rawPeak: Float = 0
        for index in 0..<frameCount {
            rawPeak = max(rawPeak, abs(renderInputSamples[index]))
        }
        guard rawPeak > 0.000_001 else {
            previousHighPassInput = 0
            previousHighPassOutput = 0
            fillRenderOutputWithSilence(frameCount: frameCount)
            updateProcessingSnapshot(inputRMS: 0, outputPeak: 0, automaticGain: 1, limiterHits: 0)
            return false
        }

        let gain = settings.gainMultiplier
        let tuningSettings = settings.tuningSettings
        var inputSquares: Float = 0
        var outputPeak: Float = 0
        var limiterHits: UInt64 = 0
        var appliedAutomaticGain: Float = 1

        switch settings.processingMode {
        case .voice:
            var filteredPeak: Float = 0
            var activeSquares: Float = 0
            var activeCount = 0
            for index in 0..<frameCount {
                let filteredSample = highPass(renderInputSamples[index])
                renderVoiceSamples[index] = filteredSample
                inputSquares += filteredSample * filteredSample
                let magnitude = abs(filteredSample)
                filteredPeak = max(filteredPeak, magnitude)
                if magnitude > 0.0010 {
                    activeSquares += filteredSample * filteredSample
                    activeCount += 1
                }
            }

            let filteredRMS = sqrt(inputSquares / Float(max(frameCount, 1)))
            let gateGain = noiseGateGain(forRMS: filteredRMS, peak: filteredPeak, settings: tuningSettings)
            let automaticGain = automaticVoiceGain(
                inputRMS: filteredRMS,
                inputPeak: filteredPeak,
                gateGain: gateGain,
                activeRMS: activeCount > 0 ? sqrt(activeSquares / Float(activeCount)) : nil,
                settings: tuningSettings
            )
            appliedAutomaticGain = automaticGain
            inputSquares = 0
            for index in 0..<frameCount {
                let gatedSample = renderVoiceSamples[index] * gateGain
                inputSquares += gatedSample * gatedSample
                let amplified = gatedSample * gain * automaticGain
                if abs(amplified) > 0.72 {
                    limiterHits += 1
                }
                let limited = Self.cleanVoiceLimited(amplified, ceiling: tuningSettings.limiterCeiling)
                let outputSample = Self.blackHoleOutputSample(limited, settings: settings)
                outputPeak = max(outputPeak, abs(outputSample))
                renderOutputSamplesBuffer[index] = outputSample
            }
        case .raw:
            for index in 0..<frameCount {
                let inputSample = renderInputSamples[index]
                inputSquares += inputSample * inputSample
                let amplified = inputSample * gain
                if abs(amplified) > 0.82 {
                    limiterHits += 1
                }
                let limited = Self.softLimited(amplified, ceiling: tuningSettings.limiterCeiling)
                let outputSample = Self.blackHoleOutputSample(limited, settings: settings)
                outputPeak = max(outputPeak, abs(outputSample))
                renderOutputSamplesBuffer[index] = outputSample
            }
        }

        updateProcessingSnapshot(
            inputRMS: sqrt(inputSquares / Float(max(frameCount, 1))),
            outputPeak: outputPeak,
            automaticGain: appliedAutomaticGain,
            limiterHits: limiterHits
        )
        return outputPeak > 0.000_001
    }

    private func fillAndEnqueueBlackHoleBuffer(_ buffer: AudioQueueBufferRef) {
        guard let format else { return }

        let settings = currentRenderSettings()
        let hasAudio = renderOutputSamples(frameCount: Self.outputFramesPerBuffer, settings: settings)
        let channelCount = 2
        let requiredBytes = UInt32(Self.outputFramesPerBuffer * channelCount * MemoryLayout<Float>.size)
        guard requiredBytes > 0 else { return }

        if let restartReason = blackHoleRestartReason() {
            restartBlackHoleQueue(reason: restartReason)
        }

        let queue = audioQueueLock.withLock { () -> AudioQueueRef? in
            guard let queue = blackHoleQueue else { return nil }

            guard blackHoleBuffersInFlight < Self.maximumBlackHoleBuffersInFlight else {
                return nil
            }

            blackHoleBuffersInFlight += 1
            lastBlackHoleEnqueueAt = Date()
            return queue
        }

        guard let queue else {
            restartBlackHoleQueue(reason: "unable to enqueue callback buffer")
            return
        }
        let output = buffer.pointee.mAudioData.bindMemory(to: Float.self, capacity: Self.outputFramesPerBuffer * channelCount)
        for index in 0..<Self.outputFramesPerBuffer {
            let sample = renderOutputSamplesBuffer[index]
            output[index * 2] = sample
            output[index * 2 + 1] = sample
        }
        buffer.pointee.mAudioDataByteSize = requiredBytes

        let status = AudioQueueEnqueueBuffer(queue, buffer, 0, nil)
        if status != noErr {
            NSLog("PhoneMic output: AudioQueueEnqueueBuffer failed \(status)")
            let shouldRestart = audioQueueLock.withLock { () -> Bool in
                if blackHoleBuffersInFlight > 0 {
                    blackHoleBuffersInFlight -= 1
                }
                blackHoleConsecutiveEnqueueFailures += 1
                return blackHoleConsecutiveEnqueueFailures >= 2
            }
            if shouldRestart {
                restartBlackHoleQueue(reason: "enqueue failed \(status)")
            }
        } else {
            audioQueueLock.withLock {
                blackHoleConsecutiveEnqueueFailures = 0
            }
        }

        if settings.monitoringEnabled, hasAudio {
            let monitorSamples = renderOutputSamplesBuffer
            let monitorGain = settings.tuningSettings.monitorOutputVolume
            if !monitorPlayer.isPlaying {
                monitorPlayer.play()
            }
            scheduleToMonitor(samples: monitorSamples, format: format, gain: monitorGain)
        }
    }

    private func blackHoleRestartReason() -> String? {
        let now = Date()
        return audioQueueLock.withLock {
            guard blackHoleQueue != nil else { return nil }

            if blackHoleBuffersInFlight >= Self.maximumBlackHoleBuffersInFlight {
                return "queued buffers stalled (\(blackHoleBuffersInFlight) pending)"
            }

            let secondsSinceCallback = now.timeIntervalSince(lastBlackHoleCallbackAt)
            let secondsSinceEnqueue = now.timeIntervalSince(lastBlackHoleEnqueueAt)
            if blackHoleBuffersInFlight > 0,
               secondsSinceCallback > 1.5,
               secondsSinceEnqueue > 0.2 {
                return String(format: "no AudioQueue callback for %.1f seconds", secondsSinceCallback)
            }

            return nil
        }
    }

    private func scheduleToMonitor(
        samples: [Float],
        format: AVAudioFormat,
        gain: Float
    ) {
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(samples.count)
        ) else {
            return
        }

        buffer.frameLength = AVAudioFrameCount(samples.count)
        guard let channel = buffer.floatChannelData?[0] else { return }
        for index in samples.indices {
            channel[index] = samples[index] * gain
        }
        monitorPlayer.scheduleBuffer(buffer, completionHandler: nil)
    }

    private func updateProcessingSnapshot(
        inputRMS: Float,
        outputPeak: Float,
        automaticGain: Float,
        limiterHits: UInt64
    ) {
        statsLock.withLock {
            storedProcessingSnapshot = AudioProcessingSnapshot(
                inputRMS: 0.85 * storedProcessingSnapshot.inputRMS + 0.15 * inputRMS,
                outputPeak: max(0.85 * storedProcessingSnapshot.outputPeak, outputPeak),
                automaticGain: automaticGain,
                limiterHits: storedProcessingSnapshot.limiterHits + limiterHits
            )
        }
    }

    private func currentRenderSettings() -> AudioRenderSettingsSnapshot {
        gainLock.withLock {
            AudioRenderSettingsSnapshot(
                gainMultiplier: Float(pow(10, Double(storedGainDecibels) / 20)),
                processingMode: storedProcessingMode,
                tuningSettings: storedTuningSettings,
                monitoringEnabled: storedMonitoringEnabled,
                blackHoleOutputBoostMultiplier: Float(pow(10, Double(storedTuningSettings.blackHoleOutputBoostDecibels) / 20)),
                finalLimiterCeiling: min(max(storedTuningSettings.finalLimiterCeiling, 0.60), 0.90)
            )
        }
    }

    private static func cleanVoiceLimited(_ sample: Float, ceiling: Float) -> Float {
        let threshold: Float = 0.62
        let ceiling = min(max(ceiling, threshold), 0.92)
        let ratio: Float = 5.0
        let magnitude = abs(sample)
        guard magnitude > threshold else { return sample }

        let compressedMagnitude = threshold + (magnitude - threshold) / ratio
        return copysign(min(compressedMagnitude, ceiling), sample)
    }

    private static func softLimited(_ sample: Float, ceiling: Float) -> Float {
        let threshold: Float = 0.72
        let ceiling = min(max(ceiling, threshold), 0.98)
        let magnitude = abs(sample)
        guard magnitude > threshold else { return sample }

        let excess = magnitude - threshold
        let limitedMagnitude = threshold + (1 - exp(-excess * 4)) * (ceiling - threshold)
        return copysign(min(limitedMagnitude, ceiling), sample)
    }

    private static func blackHoleOutputSample(_ sample: Float, settings: AudioTuningSettings) -> Float {
        let boostedSample = sample * Float(pow(10, Double(settings.blackHoleOutputBoostDecibels) / 20))
        let threshold: Float = 0.60
        let ceiling = min(max(settings.finalLimiterCeiling, threshold), 0.90)
        let magnitude = abs(boostedSample)
        guard magnitude > threshold else { return boostedSample }

        let excess = magnitude - threshold
        let limitedMagnitude = threshold + (1 - exp(-excess * 1.8)) * (ceiling - threshold)
        return copysign(min(limitedMagnitude, ceiling), boostedSample)
    }

    private static func blackHoleOutputSample(_ sample: Float, settings: AudioRenderSettingsSnapshot) -> Float {
        let boostedSample = sample * settings.blackHoleOutputBoostMultiplier
        let threshold: Float = 0.60
        let magnitude = abs(boostedSample)
        guard magnitude > threshold else { return boostedSample }

        let excess = magnitude - threshold
        let limitedMagnitude = threshold + (1 - exp(-excess * 1.8)) * (settings.finalLimiterCeiling - threshold)
        return copysign(min(limitedMagnitude, settings.finalLimiterCeiling), boostedSample)
    }

    private func noiseGateGain(forRMS rms: Float, peak: Float, settings: AudioTuningSettings) -> Float {
        let voicePresence = Self.voicePresence(forRMS: rms, peak: peak)
        let floorGain = settings.noiseGateFloor
        let targetGateGain = floorGain + (1 - floorGain) * voicePresence
        let smoothing: Float = targetGateGain > smoothedNoiseGateGain ? 0.58 : 0.025
        smoothedNoiseGateGain += smoothing * (targetGateGain - smoothedNoiseGateGain)
        return smoothedNoiseGateGain
    }

    private func automaticVoiceGain(
        inputRMS: Float,
        inputPeak: Float,
        gateGain: Float,
        activeRMS: Float?,
        settings: AudioTuningSettings
    ) -> Float {
        let voicePresence = Self.voicePresence(forRMS: inputRMS, peak: inputPeak)
        guard voicePresence > 0.22, gateGain > 0.16 else {
            smoothedVoiceGain = 0.94 * smoothedVoiceGain + 0.06
            return smoothedVoiceGain
        }

        guard let rms = activeRMS else {
            smoothedVoiceGain = 0.94 * smoothedVoiceGain + 0.06
            return smoothedVoiceGain
        }

        let targetRMS = settings.voiceTargetRMS
        let peakGuard = inputPeak > 0.08 ? max(0.75, 0.08 / inputPeak) : Float(1)
        let desiredGain = min(max(targetRMS / max(rms, 0.0015), 0.75), settings.automaticGainLimit, peakGuard)

        // WeChat begins recording immediately and may drop very low-level
        // syllables as silence. Give speech onsets a fast, bounded lift, then
        // settle with a slower release so phrases stay even instead of pumping.
        if voicePresence > 0.62, desiredGain > smoothedVoiceGain {
            smoothedVoiceGain = max(smoothedVoiceGain, min(desiredGain, 1.35))
        }
        let smoothing: Float = desiredGain > smoothedVoiceGain ? 0.16 : 0.22
        smoothedVoiceGain = smoothedVoiceGain + smoothing * (desiredGain - smoothedVoiceGain)
        return smoothedVoiceGain
    }

    private func highPass(_ sample: Float) -> Float {
        let coefficient: Float = 0.988
        let output = coefficient * (previousHighPassOutput + sample - previousHighPassInput)
        previousHighPassInput = sample
        previousHighPassOutput = output
        return output
    }

    private static func voicePresence(forRMS rms: Float, peak: Float) -> Float {
        max(
            smoothStep(edge0: 0.00028, edge1: 0.0017, value: rms),
            smoothStep(edge0: 0.0024, edge1: 0.011, value: peak)
        )
    }

    private static func smoothStep(edge0: Float, edge1: Float, value: Float) -> Float {
        let normalized = min(max((value - edge0) / (edge1 - edge0), 0), 1)
        return normalized * normalized * (3 - 2 * normalized)
    }

    private func ensureRenderBuffers(frameCount: Int) {
        if renderInputSamples.count < frameCount {
            renderInputSamples = Array(repeating: 0, count: frameCount)
        }
        if renderVoiceSamples.count < frameCount {
            renderVoiceSamples = Array(repeating: 0, count: frameCount)
        }
        if renderOutputSamplesBuffer.count < frameCount {
            renderOutputSamplesBuffer = Array(repeating: 0, count: frameCount)
        }
    }

    private func fillRenderOutputWithSilence(frameCount: Int) {
        ensureRenderBuffers(frameCount: frameCount)
        for index in 0..<frameCount {
            renderOutputSamplesBuffer[index] = 0
        }
    }
}

enum BlackHoleOutputError: LocalizedError {
    case blackHoleNotInstalled
    case cannotCreateAudioQueue(OSStatus)
    case cannotSelectDevice(OSStatus)
    case cannotStartAudioQueue(OSStatus)

    var errorDescription: String? {
        switch self {
        case .blackHoleNotInstalled:
            return "未安装 BlackHole 2ch。请先安装 BlackHole 2ch，重启 PhoneMic，然后在微信或系统设置 > 声音 > 输入中选择 BlackHole 2ch。"
        case .cannotCreateAudioQueue(let status):
            return "无法创建 BlackHole 输出队列。CoreAudio 状态：\(status)。"
        case .cannotSelectDevice(let status):
            return "无法将音频路由到 BlackHole。CoreAudio 状态：\(status)。"
        case .cannotStartAudioQueue(let status):
            return "无法启动 BlackHole 输出队列。CoreAudio 状态：\(status)。"
        }
    }
}

private let blackHoleAudioQueueCallback: AudioQueueOutputCallback = { userData, queue, buffer in
    guard let userData else { return }
    let output = Unmanaged<BlackHoleOutputEngine>.fromOpaque(userData).takeUnretainedValue()
    output.handleBlackHoleBufferCompleted(queue: queue, buffer: buffer)
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
