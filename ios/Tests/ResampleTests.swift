import AVFoundation
import Foundation
import Testing
@testable import VoiceDiary

// IOS-A13 / #9: the writer upsampler and the 16 kHz downsampler in both
// `AudioEngine` tap callbacks share one `resample` helper.

@Suite("Resample")
struct ResampleTests {
    private func format(_ rate: Double) -> AVAudioFormat {
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false
        )!
    }

    private func tone(rate: Double, frames: AVAudioFrameCount) -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(pcmFormat: format(rate), frameCapacity: frames)!
        buffer.frameLength = frames
        for i in 0..<Int(frames) {
            buffer.floatChannelData![0][i] = Float(sin(Double(i) * 0.05))
        }
        return buffer
    }

    @Test("48 kHz to 16 kHz yields about a third of the frames")
    func downsample() throws {
        let input = tone(rate: 48_000, frames: 4096)
        let target = format(16_000)
        let converter = try #require(AVAudioConverter(from: input.format, to: target))
        let out = try #require(resample(buffer: input, using: converter, to: target))
        #expect(out.format.sampleRate == 16_000)
        // At least the converted frames, never more than the capacity
        // (`ratio * frames + 1024`) the helper allocates.
        #expect(Int(out.frameLength) >= 4096 / 3 - 64)
        #expect(out.frameLength <= out.frameCapacity)
    }

    @Test("16 kHz to 48 kHz yields about three times the frames")
    func upsample() throws {
        let input = tone(rate: 16_000, frames: 1024)
        let target = format(48_000)
        let converter = try #require(AVAudioConverter(from: input.format, to: target))
        let out = try #require(resample(buffer: input, using: converter, to: target))
        #expect(out.format.sampleRate == 48_000)
        #expect(Int(out.frameLength) >= 1024 * 3 - 128)
        #expect(out.frameLength <= out.frameCapacity)
    }
}
