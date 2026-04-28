import AVFoundation
import FluidAudio
import Foundation
import os

// On-device speech recognition via FluidInference/FluidAudio's Parakeet TDT
// v3 (multilingual, 25 European languages — German is first-class).
//
// The model is ~1.2 GB. We download it lazily on first use and cache via
// FluidAudio's default model registry. Subsequent launches load instantly.
//
// For M2 (drive-by capture) we transcribe in **batch** mode: hand the
// finished M4A to `transcribe(audioURL:)` and get text back. Streaming /
// wake-word detection lands in M7 (Parakeet EOU, English-only) on top of
// this baseline.

public actor ParakeetManager {
    public static let shared = ParakeetManager()

    public enum LoadState: Sendable, Equatable {
        case idle
        case loading
        case ready
        case failed(String)
    }

    public struct Transcript: Sendable {
        public let text: String
        public let language: String
        public let confidence: Double
    }

    public enum ManagerError: Error, CustomStringConvertible {
        case notReady(state: String)
        case underlying(any Error)

        public var description: String {
            switch self {
            case .notReady(let s): return "parakeet_not_ready: \(s)"
            case .underlying(let e): return "parakeet_error: \(e)"
            }
        }
    }

    private var manager: AsrManager?
    public private(set) var loadState: LoadState = .idle

    public init() {}

    // --- model lifecycle -------------------------------------------------

    /// Lazily load Parakeet v3 (multilingual). First call downloads from
    /// HuggingFace (~1.2 GB) — subsequent calls are no-ops once `.ready`.
    public func warmUp() async {
        switch loadState {
        case .ready, .loading: return
        case .idle, .failed: break
        }
        loadState = .loading
        Log.audio.info("Parakeet v3: starting download/load…")
        do {
            let models = try await AsrModels.downloadAndLoad(version: .v3)
            let mgr = AsrManager()
            try await mgr.loadModels(models)
            self.manager = mgr
            loadState = .ready
            Log.audio.info("Parakeet v3: ready")
        } catch {
            let msg = String(describing: error)
            loadState = .failed(msg)
            Log.audio.error("Parakeet load failed: \(msg, privacy: .public)")
        }
    }

    public func reset() {
        // Drop the loaded models. Useful for memory-pressure recovery; the
        // next warmUp() will rehydrate from the local cache (no re-download).
        manager = nil
        loadState = .idle
    }

    // --- transcription ---------------------------------------------------

    /// Transcribe a finished audio file. FluidAudio's `AudioConverter`
    /// normalises the input to 16 kHz mono Float32 internally — we don't
    /// need to pre-resample even though our M4A is at the device's native
    /// sample rate.
    public func transcribe(audioURL: URL) async throws -> Transcript {
        if loadState != .ready { await warmUp() }
        guard case .ready = loadState, let manager else {
            throw ManagerError.notReady(state: "\(loadState)")
        }
        do {
            let layers = await manager.decoderLayerCount
            var decoderState = try TdtDecoderState(decoderLayers: layers)
            let result = try await manager.transcribe(audioURL, decoderState: &decoderState)
            return Transcript(
                text: result.text,
                language: detectedLanguage(from: result),
                confidence: Double(result.confidence)
            )
        } catch {
            Log.audio.error("Parakeet transcribe failed: \(String(describing: error), privacy: .public)")
            throw ManagerError.underlying(error)
        }
    }

    /// Transcribe an in-memory PCM buffer (used by the streaming sink in
    /// future milestones). For M2 we go through the file URL path.
    public func transcribe(buffer: AVAudioPCMBuffer) async throws -> Transcript {
        if loadState != .ready { await warmUp() }
        guard case .ready = loadState, let manager else {
            throw ManagerError.notReady(state: "\(loadState)")
        }
        do {
            guard let channelData = buffer.floatChannelData else {
                throw ManagerError.notReady(state: "empty_buffer")
            }
            let frameCount = Int(buffer.frameLength)
            let samples = Array(UnsafeBufferPointer(start: channelData[0], count: frameCount))
            let layers = await manager.decoderLayerCount
            var decoderState = try TdtDecoderState(decoderLayers: layers)
            let result = try await manager.transcribe(samples, decoderState: &decoderState)
            return Transcript(
                text: result.text,
                language: detectedLanguage(from: result),
                confidence: Double(result.confidence)
            )
        } catch {
            throw ManagerError.underlying(error)
        }
    }

    // --- helpers ---------------------------------------------------------

    /// Extract the detected language tag from the ASR result. FluidAudio's
    /// `ASRResult` does not currently expose a per-utterance language code
    /// (as of v0.12.x), so we default to "de" for v1; M9 (multilingual)
    /// will revisit this when the English voice + auto-detect routing
    /// lands. The server's Whisper sidecar still acts as a tiebreaker.
    private func detectedLanguage(from _: ASRResult) -> String {
        return "de"
    }
}
