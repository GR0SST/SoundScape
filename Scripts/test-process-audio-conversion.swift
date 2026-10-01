import AVFAudio
import Foundation

// swiftc Sources/SoundScape/ProcessAudioTap.swift Scripts/test-process-audio-conversion.swift -o /tmp/soundscape-tap-test
@main
struct TapConversionTests {
    static func main() {
        for rate in [44_100.0, 48_000.0, 96_000.0] {
            for interleaved in [true, false] {
                let sourceFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 2, interleaved: interleaved)!
                let destinationFormat = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
                var receivedFrames = 0
                var peak: Float = 0
                let converter = TapPCMConverter(inputFormat: sourceFormat, outputFormat: destinationFormat) { data, frames in
                    let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: data))
                    precondition(buffers.count == 2, "Graph expects planar stereo")
                    receivedFrames += Int(frames)
                    for buffer in buffers {
                        let samples = buffer.mData!.assumingMemoryBound(to: Float.self)
                        for frame in 0..<Int(frames) { peak = max(peak, abs(samples[frame])) }
                    }
                }!
                let input = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: 512)!
                input.frameLength = 512
                for buffer in UnsafeMutableAudioBufferListPointer(input.mutableAudioBufferList) {
                    let samples = buffer.mData!.assumingMemoryBound(to: Float.self)
                    for i in 0..<(Int(buffer.mDataByteSize) / 4) { samples[i] = 0.25 }
                }
                for _ in 0..<30 { converter.consume(input.audioBufferList) }
                let expected = 30.0 * 512 * 48_000 / rate
                precondition(abs(Double(receivedFrames) - expected) < 200, "Wrong resampling rate: \(rate), got \(receivedFrames)")
                precondition(peak > 0.2 && peak < 0.35, "Audio lost or incorrectly decoded")
            }
        }
        print("Process tap PCM checks passed: interleaved/planar stereo at 44.1, 48 and 96 kHz")
    }
}
