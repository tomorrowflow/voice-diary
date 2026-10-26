import Foundation

// Decides whether a speech-recognition error means "the per-language
// dictation asset isn't installed". Pure over the error's domain and code
// so it can be tested without running a recognizer; `SpeechAssetProbe`
// in `WakeWordSettingsView` owns the hardware probe and calls this.

enum SpeechAssetErrorClassifier {
    /// Conservative allowlist of error codes that empirically mean
    /// "the per-language dictation asset isn't installed". Everything
    /// else — including the common `kAFAssistantErrorDomain` 1107 /
    /// 216 "no speech" returned when we submit no audio buffers — is
    /// not missing: the probe reads it as `.installed` because reaching
    /// its callback at all required the recognizer to spin up.
    ///
    /// References:
    ///   * `SFSpeechErrorDomain` with `unsupportedLocale` / -ish codes
    ///     surfaces when the locale's model isn't on disk.
    ///   * `kAFAssistantErrorDomain` 203 has been reported for
    ///     "request was canceled because language isn't available".
    ///
    /// Keep this list short and conservative — false positives here
    /// (treating an installed asset as missing) are exactly the bug
    /// the user just hit. False negatives only mean "Test" claims
    /// installed for one extra error we haven't catalogued; that's
    /// graceful because the wake-word listen window will then fail
    /// gracefully at the actual use site.
    static func indicatesMissingAsset(domain: String, code: Int) -> Bool {
        // SFSpeechErrorDomain (Swift 5.7+/iOS 17). The exact case set
        // depends on the SDK; rather than enum-match (which would
        // tie us to the SDK shape), we compare against the codes
        // Apple uses for "language not supported" / "asset not
        // available". `unsupportedLocale` is the canonical one.
        if domain == "SFSpeechErrorDomain" {
            // Code 7 corresponds to `.unsupportedLocale` on current
            // iOS. We deliberately don't add other SFSpeechError
            // codes because they overwhelmingly mean transient
            // recognition failures, not "asset missing".
            return code == 7
        }
        // kAFAssistantErrorDomain 203 has been observed when the
        // assistant subsystem refuses the request because the
        // language model isn't on disk. The same domain's 1107 / 216
        // are "no speech" / "empty audio" — those are NOT
        // asset-missing and should map to `.installed`.
        if domain == "kAFAssistantErrorDomain" {
            return code == 203
        }
        return false
    }
}
