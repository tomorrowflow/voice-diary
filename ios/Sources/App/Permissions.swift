import AVFoundation
import Foundation
import Speech

/// Proactive permission requests at app launch.
///
/// The walkthrough relies on **two** privacy-gated capabilities:
///
///   1. Microphone — needed to record any segment.
///   2. Speech Recognition (SFSpeechRecognizer with on-device de-DE) —
///      needed for the German wake-word path so the user can say
///      "weiter" / "nächstes" / "fertig" to advance.
///
/// Without proactive prompts, both are requested lazily:
///   • Microphone fires on the first `AVAudioSession.setActive(true)`
///     in `AudioEngine.prepareSession()`.
///   • Speech Recognition fires on the first 3 s lull when the wake
///     window opens for the first time.
///
/// That's two surprise dialogs scattered across the first walkthrough.
/// Worse, denying Speech Recognition silently disables wake-word
/// listening forever — the user has to dig into Settings to turn it
/// back on. Requesting both at app launch puts the dialogs up-front,
/// in a context where the user understands why they're being asked
/// (the app just opened), and lets us log the outcome.
///
/// Re-installing the app resets all permissions; this helper makes
/// sure the user gets prompted again the first time they open a fresh
/// install.
@MainActor
public enum Permissions {

    /// Fire all permission prompts the user hasn't yet answered. Safe
    /// to call repeatedly — once a permission is granted or denied,
    /// the system caches the answer and subsequent calls are no-ops.
    public static func requestStartupPermissions() async {
        // 1. Microphone. iOS 17+ uses `AVAudioApplication`.
        let micGranted: Bool = await withCheckedContinuation { cont in
            AVAudioApplication.requestRecordPermission { granted in
                cont.resume(returning: granted)
            }
        }
        Log.app.info(
            "permissions: microphone \(micGranted ? "granted" : "denied", privacy: .public)"
        )

        // 2. Speech Recognition (drives the German wake-word window).
        // We reuse the same wrapper the wake-word path uses so the
        // success / failure semantics are identical — only the timing
        // changes (now: at launch; before: at first 3 s lull).
        do {
            try await AppleStreamingRecognizer.requestAuthorization()
            Log.app.info("permissions: speech recognition granted")
        } catch {
            Log.app.warning(
                "permissions: speech recognition denied/unavailable — wake-word path will no-op until granted in Settings → Voice Diary → Speech Recognition (\(String(describing: error), privacy: .public))"
            )
        }
    }
}
