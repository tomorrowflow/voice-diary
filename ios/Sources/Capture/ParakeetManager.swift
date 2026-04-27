import AVFoundation
import Foundation

// Streaming STT via FluidInference/FluidAudio (Parakeet v3 multilingual).
//
// Status: SDK is wired in `Package.swift`, but the model load + streaming
// inference is parked behind a feature flag for the M3 dogfooding cycle.
// The synthetic-upload flow does not depend on a working transcript on
// device — the server's Whisper sidecar re-transcribes anyway. Once the
// FluidAudio model files are bundled (M2 final cut) this stub turns into
// a real call.
//
// Reference patterns: see `~/Documents/GitHub/murmur/SharedSources/`.

public actor ParakeetManager {
    public static let shared = ParakeetManager()

    public enum State: Sendable, Equatable {
        case idle
        case streaming(partial: String)
        case finalized(text: String, language: String)
    }

    public private(set) var state: State = .idle

    public init() {}

    public func reset() {
        state = .idle
    }

    /// Call from `AudioEngine`'s streaming sink when Parakeet is wired.
    /// Right now this is a no-op so the rest of the pipeline can be tested
    /// independently of the model bundle.
    public func feed(buffer: AVAudioPCMBuffer) {
        // FluidAudio pipeline goes here.
    }

    /// Returns the final transcript + detected language. While the SDK is
    /// stubbed we return placeholder text so downstream code can be
    /// exercised end-to-end against the server.
    public func finalize() -> (text: String, language: String) {
        let placeholder = "(transcript wird auf dem Server erzeugt)"
        state = .finalized(text: placeholder, language: "de")
        return (placeholder, "de")
    }
}
