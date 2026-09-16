import Foundation

public struct JitterBufferSnapshot: Equatable {
    public var availableFrames: Int
    public var capacityFrames: Int
    public var prebufferFrames: Int
    public var underruns: UInt64
    public var droppedFrames: UInt64
    public var isPrimed: Bool
}

public final class PCMFloatRingBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Float]
    private var readIndex = 0
    private var writeIndex = 0
    private var storedFrames = 0
    private var droppedFrameTotal: UInt64 = 0

    public let capacityFrames: Int

    public init(capacityFrames: Int) {
        precondition(capacityFrames > 0, "capacityFrames must be positive")
        self.capacityFrames = capacityFrames
        self.storage = Array(repeating: 0, count: capacityFrames)
    }

    public var availableFrames: Int {
        lock.withLock { storedFrames }
    }

    public var droppedFrames: UInt64 {
        lock.withLock { droppedFrameTotal }
    }

    public func push(_ samples: [Float]) {
        return lock.withLock {
            for sample in samples {
                if storedFrames == capacityFrames {
                    readIndex = (readIndex + 1) % capacityFrames
                    storedFrames -= 1
                    droppedFrameTotal += 1
                }

                storage[writeIndex] = sample
                writeIndex = (writeIndex + 1) % capacityFrames
                storedFrames += 1
            }
        }
    }

    public func read(frameCount: Int) -> [Float] {
        guard frameCount > 0 else { return [] }

        var output = Array(repeating: Float(0), count: frameCount)
        _ = read(into: &output, frameCount: frameCount)
        return output
    }

    @discardableResult
    public func read(into output: inout [Float], frameCount: Int) -> Int {
        guard frameCount > 0 else { return 0 }
        if output.count < frameCount {
            output = Array(repeating: Float(0), count: frameCount)
        }

        return lock.withLock {
            let framesToRead = min(frameCount, storedFrames)
            for index in 0..<framesToRead {
                output[index] = storage[readIndex]
                readIndex = (readIndex + 1) % capacityFrames
            }
            if framesToRead < frameCount {
                for index in framesToRead..<frameCount {
                    output[index] = 0
                }
            }

            storedFrames -= framesToRead
            return framesToRead
        }
    }

    public func clear() {
        return lock.withLock {
            readIndex = 0
            writeIndex = 0
            storedFrames = 0
        }
    }
}

public final class JitterBuffer: @unchecked Sendable {
    private let ringBuffer: PCMFloatRingBuffer
    private var minimumPrebufferFrames: Int
    private let maximumPrebufferFrames: Int
    private let lock = NSLock()
    private var primed = false
    private var currentPrebufferFrames: Int
    private var stableReadCount = 0
    private var underrunTotal: UInt64 = 0

    public init(
        capacityFrames: Int = 48_000 * 2,
        prebufferFrames: Int = 960
    ) {
        self.ringBuffer = PCMFloatRingBuffer(capacityFrames: capacityFrames)
        self.minimumPrebufferFrames = prebufferFrames
        self.maximumPrebufferFrames = min(capacityFrames / 2, max(prebufferFrames, 4_800))
        self.currentPrebufferFrames = prebufferFrames
    }

    public func push(packet: AudioPacket) {
        ringBuffer.push(packet.samples)
    }

    public func setMinimumPrebuffer(milliseconds: Float) {
        let requestedFrames = Int((Double(milliseconds) / 1_000) * PhoneMicAudio.sampleRate)
        setMinimumPrebuffer(frames: requestedFrames)
    }

    public func setMinimumPrebuffer(frames: Int) {
        let clampedFrames = min(max(frames, PhoneMicAudio.framesPerPacket), maximumPrebufferFrames)
        lock.withLock {
            minimumPrebufferFrames = clampedFrames
            if !primed {
                currentPrebufferFrames = clampedFrames
            } else {
                currentPrebufferFrames = min(max(currentPrebufferFrames, clampedFrames), maximumPrebufferFrames)
            }
            stableReadCount = 0
        }
    }

    public func readForPlayback(frameCount: Int) -> [Float] {
        var output = Array(repeating: Float(0), count: frameCount)
        _ = readForPlayback(into: &output, frameCount: frameCount)
        return output
    }

    @discardableResult
    public func readForPlayback(into output: inout [Float], frameCount: Int) -> Bool {
        guard frameCount > 0 else { return false }
        if output.count < frameCount {
            output = Array(repeating: Float(0), count: frameCount)
        }

        return lock.withLock {
            if !primed {
                guard ringBuffer.availableFrames >= currentPrebufferFrames else {
                    output.fillPrefixWithZeros(frameCount)
                    return false
                }
                primed = true
            }

            let availableFrames = ringBuffer.availableFrames
            if availableFrames < frameCount {
                underrunTotal += 1
                stableReadCount = 0
                currentPrebufferFrames = min(maximumPrebufferFrames, currentPrebufferFrames + frameCount)
                let framesRead = ringBuffer.read(into: &output, frameCount: frameCount)
                return framesRead > 0
            }

            ringBuffer.read(into: &output, frameCount: frameCount)
            stableReadCount += 1
            if stableReadCount >= 300, currentPrebufferFrames > minimumPrebufferFrames {
                currentPrebufferFrames = max(minimumPrebufferFrames, currentPrebufferFrames - frameCount)
                stableReadCount = 0
            }
            return true
        }
    }

    public func clear() {
        lock.withLock {
            primed = false
            underrunTotal = 0
            stableReadCount = 0
            currentPrebufferFrames = minimumPrebufferFrames
            ringBuffer.clear()
        }
    }

    public func snapshot() -> JitterBufferSnapshot {
        lock.withLock {
            JitterBufferSnapshot(
                availableFrames: ringBuffer.availableFrames,
                capacityFrames: ringBuffer.capacityFrames,
                prebufferFrames: currentPrebufferFrames,
                underruns: underrunTotal,
                droppedFrames: ringBuffer.droppedFrames,
                isPrimed: primed
            )
        }
    }
}

private extension Array where Element == Float {
    mutating func fillPrefixWithZeros(_ count: Int) {
        guard count > 0 else { return }
        if self.count < count {
            self = Array(repeating: 0, count: count)
            return
        }
        for index in 0..<count {
            self[index] = 0
        }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
