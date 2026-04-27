import AVFoundation
import Foundation

// AVAudioEngine wrapper with two sinks:
//   1. Parakeet streaming  (PCM Float32 buffers, downsampled to 16 kHz mono)
//   2. M4A file writer     (AAC-LC at 16 kHz, mono, 64 kbps)
//
// One engine instance is shared. The murmur reference uses the same
// pattern. Don't open two engines.
//
// Parakeet wiring is deferred to M2's full integration; for now the
// streaming sink is a no-op closure. The M4A writer is real and
// produces files compatible with QuickTime Player and Whisper.

public actor AudioEngine {
    public enum EngineError: Error {
        case alreadyRunning
        case notRunning
        case sessionConfigFailed(String)
    }

    private let engine = AVAudioEngine()
    private let writer = M4AWriter()
    private var isRunning = false
    private var streamingSink: (@Sendable (AVAudioPCMBuffer) -> Void)?

    public init() {}

    /// Start capturing into `outputURL` (M4A AAC-LC 16 kHz mono).
    /// `streaming` is invoked on the audio thread for each PCM buffer if
    /// supplied — wire up Parakeet here once the SDK is bundled.
    public func start(
        outputURL: URL,
        streaming: (@Sendable (AVAudioPCMBuffer) -> Void)? = nil
    ) async throws {
        guard !isRunning else { throw EngineError.alreadyRunning }

        try await configureSession()

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: M4AWriter.sampleRate,
            channels: M4AWriter.channels,
            interleaved: false
        ) else {
            throw EngineError.sessionConfigFailed("could not build target format")
        }
        let converter = AVAudioConverter(from: inputFormat, to: targetFormat)

        try writer.open(at: outputURL)
        streamingSink = streaming

        input.removeTap(onBus: 0)
        input.installTap(
            onBus: 0,
            bufferSize: 4096,
            format: inputFormat
        ) { [writer, streamingSink] buffer, _ in
            // Convert input → 16 kHz mono float32 once, fan out to both sinks.
            let frameCapacity = AVAudioFrameCount(
                Double(buffer.frameLength) * targetFormat.sampleRate / inputFormat.sampleRate
            ) + 1024
            guard let outBuf = AVAudioPCMBuffer(
                pcmFormat: targetFormat,
                frameCapacity: frameCapacity
            ) else { return }

            var error: NSError?
            let status = converter?.convert(to: outBuf, error: &error) { _, outStatus in
                outStatus.pointee = .haveData
                return buffer
            }
            guard status == .haveData || status == .inputRanDry else { return }

            do {
                try writer.write(buffer: outBuf)
            } catch {
                print("AudioEngine: writer error: \(error)")
            }
            streamingSink?(outBuf)
        }

        engine.prepare()
        try engine.start()
        isRunning = true
    }

    public func stop() async throws -> URL? {
        guard isRunning else { throw EngineError.notRunning }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        let final = try writer.close()
        streamingSink = nil
        isRunning = false
        return final
    }

    private func configureSession() async throws {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(
                .playAndRecord,
                mode: .measurement,
                options: [.defaultToSpeaker, .allowBluetooth, .duckOthers]
            )
            try session.setPreferredSampleRate(M4AWriter.sampleRate)
            try session.setActive(true, options: [])
        } catch {
            throw EngineError.sessionConfigFailed("\(error)")
        }
    }
}
