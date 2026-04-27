import AVFoundation
import Foundation
import os

// AVAudioEngine wrapper with two sinks:
//   1. M4A file writer     (AAC at the input's native sample rate, mono)
//   2. Parakeet streaming  (PCM Float32 buffers downsampled to 16 kHz mono — optional)
//
// We deliberately do not downsample on-device for the file write. iOS's
// AAC-LC encoder reliably initialises at 44.1 / 48 kHz but reportedly
// fails (`AudioCodecInitialize`) at 16 kHz. The server's ffmpeg pulls
// audio down to 16 kHz mono before Whisper, so the wire format from the
// pipeline's perspective is unchanged.
//
// One engine instance is shared. Don't open two engines.

public actor AudioEngine {
    public enum EngineError: Error {
        case alreadyRunning
        case notRunning
        case sessionConfigFailed(String)
    }

    public static let parakeetTargetSampleRate: Double = 16_000

    private let engine = AVAudioEngine()
    private let writer = M4AWriter()
    private var isRunning = false
    private var streamingSink: (@Sendable (AVAudioPCMBuffer) -> Void)?

    public init() {}

    /// Sample rate of the most recently written file (0 before any capture).
    public var lastSampleRate: Double { writer.sampleRate }

    /// Start capturing into `outputURL`.
    ///
    /// `streaming` is invoked on the audio thread for each 16 kHz mono buffer
    /// when supplied — wire up Parakeet here once the SDK is bundled.
    public func start(
        outputURL: URL,
        streaming: (@Sendable (AVAudioPCMBuffer) -> Void)? = nil
    ) async throws {
        guard !isRunning else { throw EngineError.alreadyRunning }

        try await configureSession()

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        try writer.open(at: outputURL, inputSampleRate: inputFormat.sampleRate)
        streamingSink = streaming

        // Optional 16 kHz downsampler for the streaming sink only.
        let parakeetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: AudioEngine.parakeetTargetSampleRate,
            channels: M4AWriter.channels,
            interleaved: false
        )
        let downsampler: AVAudioConverter? = (streaming != nil && parakeetFormat != nil)
            ? AVAudioConverter(from: inputFormat, to: parakeetFormat!)
            : nil

        input.removeTap(onBus: 0)
        input.installTap(
            onBus: 0,
            bufferSize: 4096,
            format: inputFormat
        ) { [writer, streamingSink] buffer, _ in
            // 1. File: write the buffer at native rate.
            do {
                try writer.write(buffer: buffer)
            } catch {
                Log.audio.error("writer error: \(String(describing: error), privacy: .public)")
            }

            // 2. Streaming sink (optional): downsample to 16 kHz mono.
            guard let sink = streamingSink,
                  let downsampler,
                  let parakeetFormat else { return }
            let frameCapacity = AVAudioFrameCount(
                Double(buffer.frameLength) * parakeetFormat.sampleRate / inputFormat.sampleRate
            ) + 1024
            guard let outBuf = AVAudioPCMBuffer(
                pcmFormat: parakeetFormat,
                frameCapacity: frameCapacity
            ) else { return }
            var error: NSError?
            let status = downsampler.convert(to: outBuf, error: &error) { _, outStatus in
                outStatus.pointee = .haveData
                return buffer
            }
            guard status == .haveData || status == .inputRanDry else { return }
            sink(outBuf)
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
        // playAndRecord (not record) so we can play TTS back without
        // re-configuring the session each time. Mode `.measurement` keeps
        // EQ off the input, important for downstream ASR. We deliberately
        // don't request `.duckOthers` here — Voice Diary speaks via Piper
        // in a separate playback path that handles ducking itself.
        //
        // Note: we do NOT call setPreferredSampleRate here. Forcing 16 kHz
        // breaks the AAC encoder; instead we accept the device's native
        // rate (typically 44.1 / 48 kHz) and let the server downsample.
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(
                .playAndRecord,
                mode: .measurement,
                options: [.defaultToSpeaker, .allowBluetooth]
            )
            try session.setPreferredIOBufferDuration(0.02)
            try session.setActive(true, options: [])
        } catch {
            throw EngineError.sessionConfigFailed("\(error)")
        }
    }
}
