import Foundation
import NaturalLanguage

// Lightweight language detection for short user-supplied strings —
// specifically calendar event titles and attendee names that get
// spliced into German opener templates. Returns one of the routing
// buckets we ship a voice for ("de" / "en") or nil when the input is
// too short / ambiguous to call.
//
// On-device, no network. NLLanguageRecognizer hypothesises confidently
// over short titles like "Quarterly Sync" or "Standup mit Alex" — we
// only commit to a verdict above a threshold so a one-word German
// title doesn't accidentally route to the English voice.

public enum LanguageDetector {
    /// Languages we have a voice for. Anything else falls back to the
    /// caller's `default`.
    private static let supported: Set<NLLanguage> = [.german, .english]

    /// Returns "de", "en", or nil. The caller decides what nil means
    /// (in practice: keep the surrounding template's language).
    public static func detect(_ text: String, minConfidence: Double = 0.55) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Single short token (≤ 2 chars) or empty: don't guess.
        guard trimmed.count >= 3 else { return nil }

        let recognizer = NLLanguageRecognizer()
        // Constrain to languages we can speak — Apple's recognizer will
        // otherwise return Dutch / Afrikaans for short German strings.
        recognizer.languageConstraints = Array(supported)
        recognizer.processString(trimmed)

        let hypotheses = recognizer.languageHypotheses(withMaximum: 2)
        guard let best = hypotheses.max(by: { $0.value < $1.value }),
              supported.contains(best.key),
              best.value >= minConfidence
        else { return nil }

        return code(for: best.key)
    }

    private static func code(for lang: NLLanguage) -> String? {
        switch lang {
        case .german:  return "de"
        case .english: return "en"
        default:       return nil
        }
    }
}
