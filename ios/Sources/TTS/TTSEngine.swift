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
}
