import AVFoundation
import Foundation

// Writes AAC-LC audio to disk in an M4A container at the Voice Diary
// audio constants: 16 kHz mono 64 kbps CBR. Atomic write — buffers go to
// `*.tmp`, on close we rename to the final URL.

public final class M4AWriter {
    public static let sampleRate: Double = 16_000
    public static let bitrate: Int = 64_000
    public static let channels: AVAudioChannelCount = 1

    public enum WriterError: Error {
        case alreadyOpen
        case notOpen
    }

    private var file: AVAudioFile?
    private var tempURL: URL?
    private var finalURL: URL?

    public init() {}

    public func open(at finalURL: URL) throws {
        guard file == nil else { throw WriterError.alreadyOpen }
        let temp = finalURL.appendingPathExtension("tmp")
        try? FileManager.default.removeItem(at: temp)

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: M4AWriter.sampleRate,
            AVNumberOfChannelsKey: M4AWriter.channels,
            AVEncoderBitRateKey: M4AWriter.bitrate,
            AVEncoderBitRateStrategyKey: AVAudioBitRateStrategy_Constant,
        ]
        self.file = try AVAudioFile(
            forWriting: temp,
            settings: settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        self.tempURL = temp
        self.finalURL = finalURL
    }

    public func write(buffer: AVAudioPCMBuffer) throws {
        guard let file else { throw WriterError.notOpen }
        try file.write(from: buffer)
    }

    @discardableResult
    public func close() throws -> URL? {
        guard file != nil, let temp = tempURL, let final = finalURL else { return nil }
        // Releasing the file forces the AAC encoder to flush.
        self.file = nil
        try FileManager.default.moveItem(at: temp, to: final)
        self.tempURL = nil
        self.finalURL = nil
        return final
    }
}
