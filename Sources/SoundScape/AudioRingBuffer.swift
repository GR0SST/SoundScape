import AVFAudio
import Foundation

final class AudioRingBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private let channelCount: Int
    private let capacity: Int
    private var storage: [[Float]]
    private var readIndex = 0
    private var writeIndex = 0
    private var availableFrames = 0

    init(channelCount: Int, capacity: Int = 96_000) {
        self.channelCount = max(channelCount, 1)
        self.capacity = max(capacity, 4_096)
        storage = Array(
            repeating: Array(repeating: 0, count: self.capacity),
            count: self.channelCount
        )
    }

    func write(
        _ inputData: UnsafePointer<AudioBufferList>,
        frameCount: AVAudioFrameCount
    ) {
        let buffers = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: inputData)
        )
        guard !buffers.isEmpty else { return }

        let requestedFrames = Int(frameCount)
        let availableInputFrames = buffers.reduce(requestedFrames) {
            partialResult,
            buffer in
            let channels = max(Int(buffer.mNumberChannels), 1)
            let byteCount = Int(buffer.mDataByteSize)
            let frames = byteCount
                / (MemoryLayout<Float>.stride * channels)
            return min(partialResult, frames)
        }
        let frames = min(requestedFrames, availableInputFrames)
        guard frames > 0 else { return }

        lock.lock()
        defer { lock.unlock() }

        for frame in 0..<frames {
            if availableFrames == capacity {
                readIndex = (readIndex + 1) % capacity
                availableFrames -= 1
            }
            for channel in 0..<channelCount {
                let bufferIndex = buffers.count == 1
                    ? 0
                    : min(channel, buffers.count - 1)
                let buffer = buffers[bufferIndex]
                guard let data = buffer.mData else {
                    storage[channel][writeIndex] = 0
                    continue
                }
                let sourceChannelCount = max(
                    Int(buffer.mNumberChannels),
                    1
                )
                let sourceChannel = buffers.count == 1
                    ? min(channel, sourceChannelCount - 1)
                    : 0
                let sampleIndex =
                    frame * sourceChannelCount + sourceChannel
                storage[channel][writeIndex] =
                    data.assumingMemoryBound(to: Float.self)[sampleIndex]
            }
            writeIndex = (writeIndex + 1) % capacity
            availableFrames += 1
        }
    }

    @discardableResult
    func read(
        into outputData: UnsafeMutablePointer<AudioBufferList>,
        frameCount: AVAudioFrameCount
    ) -> Bool {
        let buffers = UnsafeMutableAudioBufferListPointer(outputData)
        guard !buffers.isEmpty else { return false }

        let requestedFrames = Int(frameCount)
        let writableFrames = buffers.reduce(requestedFrames) {
            partialResult,
            buffer in
            let channels = max(Int(buffer.mNumberChannels), 1)
            let byteCount = Int(buffer.mDataByteSize)
            let frames = byteCount
                / (MemoryLayout<Float>.stride * channels)
            return min(partialResult, frames)
        }
        let frames = min(requestedFrames, writableFrames)
        guard frames > 0 else { return false }

        var renderedAudio = false
        lock.lock()
        defer { lock.unlock() }

        for frame in 0..<frames {
            let hasFrame = availableFrames > 0
            renderedAudio = renderedAudio || hasFrame
            for bufferIndex in buffers.indices {
                let buffer = buffers[bufferIndex]
                guard let data = buffer.mData else { continue }
                let destination = data.assumingMemoryBound(to: Float.self)
                let destinationChannelCount = max(
                    Int(buffer.mNumberChannels),
                    1
                )
                for destinationChannel in 0..<destinationChannelCount {
                    let sourceChannel = buffers.count == 1
                        ? min(destinationChannel, channelCount - 1)
                        : min(bufferIndex, channelCount - 1)
                    let sampleIndex =
                        frame * destinationChannelCount + destinationChannel
                    destination[sampleIndex] = hasFrame
                        ? storage[sourceChannel][readIndex]
                        : 0
                }
            }
            if hasFrame {
                readIndex = (readIndex + 1) % capacity
                availableFrames -= 1
            }
        }
        return renderedAudio
    }
}
