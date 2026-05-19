import Foundation

// Pure decision module for "what to do when Voxtral fails on one
// utterance." No IO, no async, no engine references — the policy
// inspects the error + language + (injected) preferences and returns a
// `FallbackDecision` that the engine call site applies.
//
// The split keeps the rule itself testable in isolation and makes
// future evolution one-file: per-session circuit breakers, exponential
// cooldowns, or "401 → surface a banner instead of falling back" all
// land here without touching `VoxtralTTS` or the walkthrough.

public enum FallbackDecision: Equatable, Sendable {
    /// Re-dispatch this utterance to PiperTTS with the given stem.
    case usePiper(stem: String)
    /// Re-dispatch this utterance to AppleSpeechTTS — it auto-picks
    /// whichever installed voice for the language.
    case useApple
    /// No engine is available; log the failure and let the utterance
    /// silently drop. The walkthrough proceeds.
    case giveUp
}

public enum TTSFallbackPolicy {
    /// Public decision surface. Production code calls
    /// `decide(error: …, language: …)` and lets `.live` resolve
    /// preferences. Tests pass a fake `Preferences` to drive each
    /// branch deterministically.
    public static func decide(
        error: Error,
        language: String,
        preferences: Preferences = .live
    ) -> FallbackDecision {
        // V1 policy: every Voxtral failure falls back to the user's
        // best-available on-device voice. Piper if its bundled assets
        // are present for this language, otherwise Apple. Apple's
        // AVSpeechSynthesizer auto-picks whichever installed voice
        // matches, so it never genuinely "fails" — `.giveUp` is reserved
        // for hypothetical future rules (e.g. circuit-breaker open).
        _ = error
        if let stem = preferences.preferredPiperStem(language) {
            return .usePiper(stem: stem)
        }
        return .useApple
    }

    /// Injectable read of "which Piper stem should I use for this
    /// language right now?". Production uses `.live` which inspects
    /// `VoicePreferences` and `PiperTTS.assets`; tests pass a closure
    /// returning a fixed stem (or nil) so the policy can be exercised
    /// without bundled Piper assets.
    public struct Preferences: Sendable {
        public let preferredPiperStem: @Sendable (String) -> String?

        public init(preferredPiperStem: @escaping @Sendable (String) -> String?) {
            self.preferredPiperStem = preferredPiperStem
        }

        public static let live = Preferences(preferredPiperStem: { language in
            // Prefer a Piper stem the user has explicitly picked (rare
            // — they more likely picked Voxtral, hence this fallback in
            // the first place). Otherwise fall through to the
            // registered default Piper voice for the language IF its
            // bundled assets are actually present.
            if let stem = VoicePreferences.selectedPiperStem(for: language),
               PiperTTS.assets(forStem: stem) != nil {
                return stem
            }
            if let defaultStem = PiperTTS.defaultStem(for: language),
               PiperTTS.assets(forStem: defaultStem) != nil {
                return defaultStem
            }
            return nil
        })
    }
}
