import AVFoundation
import Foundation

// Common interface for any TTS backend. M5 ships with `AppleSpeechTTS`
// (uses the built-in `AVSpeechSynthesizer`). M9 swaps in Piper via
// sherpa-onnx for higher-quality voices — same protocol, different backend.

public protocol TTSEngine: AnyObject, Sendable {
    /// Speak the given text in the given language. Returns once playback
    /// has finished (or was cancelled). Errors are logged + non-fatal.
    func speak(_ text: String, language: String) async

    /// Cancel any in-flight playback. Safe to call repeatedly.
    func cancel() async

    /// Pre-prepare an utterance. Engines whose synth cost is
    /// significant (Piper) override this to run the synth upfront and
    /// return a handle pointing to the cached WAV. Engines without a
    /// pre-synth path (Apple's `AVSpeechSynthesizer`) inherit a no-op
    /// default that just records the text + language for later
    /// dispatch through `play(_:)`.
    func prefetch(_ text: String, language: String) async -> PrefetchedUtterance

    /// Play a previously prefetched utterance. If the handle's
    /// underlying assets are missing or were produced by a different
    /// engine (user switched voice between prefetch and play), the
    /// implementation falls back to a fresh `speak(_:language:)` so
    /// playback never silently no-ops.
    func play(_ prefetched: PrefetchedUtterance) async

    /// Drop any persistent resources (e.g. Piper's WAV file) without
    /// playing. Safe to call repeatedly. The default removes
    /// `audioURL` if set; engines that hold extra state may override.
    func discard(_ prefetched: PrefetchedUtterance)
}

public extension TTSEngine {
    /// Default prefetch — no real synth, the handle just carries the
    /// text + language for later dispatch through `speak(_:language:)`.
    /// Apple uses this; Piper overrides.
    func prefetch(_ text: String, language: String) async -> PrefetchedUtterance {
        PrefetchedUtterance(
            text: text,
            language: language,
            engineKind: .apple,
            audioURL: nil
        )
    }

    /// Default play — falls back to a fresh `speak(_:language:)`. Piper
    /// overrides this to play the cached WAV via AVAudioPlayer
    /// (skipping the synth pass).
    func play(_ prefetched: PrefetchedUtterance) async {
        await speak(prefetched.text, language: prefetched.language)
    }

    /// Default discard — drops the cached WAV file if present.
    /// Engines holding additional state may override.
    func discard(_ prefetched: PrefetchedUtterance) {
        if let url = prefetched.audioURL {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
