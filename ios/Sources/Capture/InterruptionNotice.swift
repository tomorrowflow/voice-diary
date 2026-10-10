import Foundation

/// Shared copy + stop-error policy for the "recording was interrupted"
/// notice (UX-1 / #26). `AudioEngine` already finalises the open writer
/// when a phone call / Siri / alarm interrupts capture, so by the time the
/// user taps Stop the engine is no longer `capturing` and `stop()` throws
/// `notRunning` even though the audio on disk is intact.
enum InterruptionNotice {
    static var message: String {
        String(localized: "Recording was interrupted — do you want to continue?")
    }

    /// True when a failed `AudioEngine.stop()` is just the expected
    /// consequence of an interruption — the chunk was already closed, so
    /// the caller must keep it rather than discard the session.
    static func shouldTolerateStopError(_ error: Error, wasInterrupted: Bool) -> Bool {
        guard wasInterrupted,
              let engineError = error as? AudioEngine.EngineError,
              case .notRunning = engineError
        else { return false }
        return true
    }
}
