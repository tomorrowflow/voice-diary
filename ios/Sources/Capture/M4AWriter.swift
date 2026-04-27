import AVFoundation
import Foundation

// Writes AAC audio to disk in an M4A container.
//
// The output sample rate **matches the input** — typically 44.1 or 48 kHz
// on an iPhone — because iOS's AAC-LC encoder is reliable there but
// reportedly fails `AudioCodecInitialize` at 16 kHz. The server's
// ffmpeg downsamples to 16 kHz mono before Whisper, so the wire format
// to the ASR pipeline is unchanged.
//
// Atomic write: buffers go to `*.tmp`, on close we rename to the final URL.

public final class M4AWriter {
    public static let bitrate: Int = 64_000
    public static let channels: AVAudioChannelCount = 1

    public enum WriterError: Error {
        case alreadyOpen
        case notOpen
    }

    private var file: AVAudioFile?
    private var tempURL: URL?
    private var finalURL: URL?
    public private(set) var sampleRate: Double = 0
    public private(set) var actualChannels: AVAudioChannelCount = 1

    public init() {}

    /// Open a writer that records mono AAC at `inputSampleRate`. The input
    /// sample rate is taken from the caller's `AVAudioEngine.inputNode`.
    public func open(at finalURL: URL, inputSampleRate: Double) throws {
        guard file == nil else { throw WriterError.alreadyOpen }
        let temp = finalURL.appendingPathExtension("tmp")
        try? FileManager.default.removeItem(at: temp)

        let rate = inputSampleRate > 0 ? inputSampleRate : 44_100
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: M4AWriter.channels,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
            AVEncoderBitRateKey: M4AWriter.bitrate,
        ]
        self.file = try AVAudioFile(
            forWriting: temp,
            settings: settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        self.tempURL = temp
        self.finalURL = finalURL
        self.sampleRate = rate
        self.actualChannels = M4AWriter.channels
    }

    public func write(buffer: AVAudioPCMBuffer) throws {
        guard let file else { throw WriterError.notOpen }
        try file.write(from: buffer)
    }

    @discardableResult
    public func close() throws -> URL? {
        guard file != nil, let temp = tempURL, let final = finalURL else { return nil }
        self.file = nil
        try FileManager.default.moveItem(at: temp, to: final)
        self.tempURL = nil
        self.finalURL = nil
        return final
    }
}
