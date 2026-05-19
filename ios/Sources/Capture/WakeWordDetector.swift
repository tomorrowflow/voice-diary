import Foundation
import os

// Phrase-list matcher driven by a streaming ASR's partial transcripts.
// Two responsibilities:
//
//   1. Hold a per-language phrase list and match incoming partials
//      with Levenshtein ≤ 2 tolerance. Levenshtein costs are tiny on
//      the short word counts we look at (≤ 4 chars in the partial's
//      tail) so the cost is fine to run on the streaming callback
//      thread.
//
//   2. De-duplicate matches inside one window. The streaming Parakeet
//      keeps emitting refined partials — without a "fired" gate we'd
//      call advance() multiple times per command word.
//
// The matcher is intentionally state-light: it doesn't manage the
// recogniser or the listen window. The coordinator owns those and
// just hands `partial` strings into `consume(partial:)`.

public final class WakeWordDetector: @unchecked Sendable {
    public struct Phrase: Sendable, Hashable {
        public let canonical: String     // lowercase, ascii-folded
        public let action: Action
        public init(_ canonical: String, action: Action) {
            self.canonical = canonical
            self.action = action
        }
    }

    public enum Action: String, Sendable, Hashable {
        case advance        // "weiter" / "next" / "continue"
        // End the current section (calendar block, general section, or
        // drive-by). Coordinator advances to the next plan step rather
        // than ingesting the whole walkthrough — saying "fertig" inside
        // meeting 2 of 5 should move you to meeting 3, not finish
        // everything. The X button is still the full-cancel path.
        case finishSection  // "fertig" / "Abschluss" / "done" / "finish section"
    }

    /// Default phrase tables per language. The coordinator picks one
    /// based on the active walkthrough language. "Abschluss" is the
    /// less ambiguous German trigger — "fertig" sometimes lands
    /// mid-reflection ("...das war fertig zum Ende der Woche…") and
    /// gets caught by the Levenshtein gate even when the user didn't
    /// intend a command. Both are kept so muscle memory still works.
    public static let german: [Phrase] = [
        Phrase("weiter",    action: .advance),
        Phrase("nächstes",  action: .advance),
        Phrase("fertig",    action: .finishSection),
        Phrase("abschluss", action: .finishSection),
    ]
    public static let english: [Phrase] = [
        Phrase("next",      action: .advance),
        Phrase("continue",  action: .advance),
        Phrase("done",      action: .finishSection),
        Phrase("finish",    action: .finishSection),
    ]

    public static func phrases(for language: String) -> [Phrase] {
        switch language.prefix(2).lowercased() {
        case "en": return english
        default:   return german
        }
    }

    private let phrases: [Phrase]
    private let onMatch: @Sendable (Action, String) -> Void
    private var fired: Set<Action> = []

    public init(
        phrases: [Phrase],
        onMatch: @escaping @Sendable (Action, String) -> Void
    ) {
        self.phrases = phrases
        self.onMatch = onMatch
    }

    /// Reset the "already fired" gate. Call this when the coordinator
    /// opens a fresh listen window — the same physical session might
    /// have fired `advance` 5 minutes ago and we want it to fire again
    /// now.
    public func resetForNewWindow() {
        fired.removeAll()
    }

    /// Feed one streaming partial. The matcher checks the *last 1-3
    /// tokens* against the phrase list (Levenshtein ≤ 2) — we don't
    /// care if "weiter" appeared 30 words ago in the rolling
    /// transcript, only if the user just said it.
    public func consume(partial: String) {
        let folded = Self.fold(partial)
        // Tail-match the last 3 whitespace-separated tokens. Streaming
        // recognisers tend to refine the most recent word, so a 3-word
        // window catches "ähm weiter" / "okay next bitte" without
        // matching false positives buried earlier in the transcript.
        let tokens = folded.split(separator: " ").suffix(3).map(String.init)
        guard !tokens.isEmpty else { return }

        for phrase in phrases where !fired.contains(phrase.action) {
            for token in tokens {
                let dist = Self.levenshtein(token, phrase.canonical)
                if dist <= 2 {
                    Diag.log("WakeWordDetector MATCH token='\(token)' canonical='\(phrase.canonical)' lev=\(dist) → action=\(phrase.action.rawValue)")
                    fired.insert(phrase.action)
                    onMatch(phrase.action, phrase.canonical)
                    return
                }
            }
        }
    }

    // MARK: - Helpers

    /// Lowercase + strip punctuation so the matcher sees plain words.
    /// Streaming recognisers often emit comma + period mid-utterance
    /// (e.g. `"weiter,"`), and we don't want a punctuation difference
    /// to cost us a Levenshtein point.
    static func fold(_ input: String) -> String {
        let lowered = input.lowercased(with: Locale(identifier: "en_US_POSIX"))
        let scalars = lowered.unicodeScalars.filter { scalar in
            CharacterSet.letters.contains(scalar)
                || CharacterSet.whitespacesAndNewlines.contains(scalar)
        }
        return String(String.UnicodeScalarView(scalars))
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Standard two-row Levenshtein. Plenty fast for the ≤ 12-char
    /// strings we're comparing — runs on the streaming callback thread
    /// without measurable overhead.
    static func levenshtein(_ a: String, _ b: String) -> Int {
        if a == b { return 0 }
        let aChars = Array(a)
        let bChars = Array(b)
        if aChars.isEmpty { return bChars.count }
        if bChars.isEmpty { return aChars.count }
        var prev = Array(0...bChars.count)
        var curr = Array(repeating: 0, count: bChars.count + 1)
        for i in 1...aChars.count {
            curr[0] = i
            for j in 1...bChars.count {
                let cost = (aChars[i - 1] == bChars[j - 1]) ? 0 : 1
                curr[j] = min(
                    curr[j - 1] + 1,
                    prev[j] + 1,
                    prev[j - 1] + cost
                )
            }
            swap(&prev, &curr)
        }
        return prev[bChars.count]
    }
}
