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
        /// Max Levenshtein distance a tail token may be from `canonical`
        /// to count as a match. Defaults to 2 (tolerant) for the longer
        /// command words; short answer words like "ja"/"nein" pass 0 so
        /// the loose ≤2 gate can't fire them off unrelated short tokens.
        public let maxDistance: Int
        public init(_ canonical: String, action: Action, maxDistance: Int = 2) {
            self.canonical = canonical
            self.action = action
            self.maxDistance = maxDistance
        }
    }

    public enum Action: String, Sendable, Hashable {
        case advance        // "weiter" / "next" / "continue"
        // End the current section (calendar block, general section, or
        // note). Coordinator advances to the next plan step rather
        // than ingesting the whole walkthrough — saying "fertig" inside
        // meeting 2 of 5 should move you to meeting 3, not finish
        // everything. The X button is still the full-cancel path.
        case finishSection  // "fertig" / "Abschluss" / "done" / "finish section"

        // Note-review-only intents (note recap step). The base
        // phrase tables don't include these — the coordinator hands
        // the extended `*NoteReview` tables to the detector when
        // state == .noteReview so a "später" mid-meeting doesn't get
        // misinterpreted as defer.
        case dropNote       // "verwerfen" / "discard"
        case deferNote      // "später" / "later"     (orphan-only)
        case replayNote     // "nochmal" / "replay"
        case rerecordNote   // "ändern" / "rerecord"
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

    /// Extended phrase tables for the per-note review step. Includes the
    /// base advance / finish triggers plus the note-only intents, plus a
    /// yes/no answer pair so the review reads like the todo confirmation
    /// ("Soll ich sie aufnehmen?" → ja = include via `.advance`, nein =
    /// `.dropNote`). The longer canonicals keep the tolerant ≤ 2 gate;
    /// "ja"/"nein"/"yes"/"no" are short, so they pass `maxDistance: 0`
    /// (exact match only) to avoid firing off unrelated short tokens.
    public static let germanNoteReview: [Phrase] = german + [
        Phrase("ja",          action: .advance,      maxDistance: 0),
        Phrase("nein",        action: .dropNote,     maxDistance: 0),
        Phrase("verwerfen",   action: .dropNote),
        Phrase("weglassen",   action: .dropNote),
        Phrase("später",      action: .deferNote),
        Phrase("aufheben",    action: .deferNote),
        Phrase("nochmal",     action: .replayNote),
        Phrase("wiederholen", action: .replayNote),
        Phrase("ändern",      action: .rerecordNote),
        Phrase("neuaufnahme", action: .rerecordNote),
    ]
    public static let englishNoteReview: [Phrase] = english + [
        Phrase("yes",       action: .advance,    maxDistance: 0),
        Phrase("no",        action: .dropNote,   maxDistance: 0),
        Phrase("discard",   action: .dropNote),
        Phrase("remove",    action: .dropNote),
        Phrase("later",     action: .deferNote),
        Phrase("defer",     action: .deferNote),
        Phrase("replay",    action: .replayNote),
        Phrase("again",     action: .replayNote),
        Phrase("rerecord",  action: .rerecordNote),
        Phrase("change",    action: .rerecordNote),
    ]

    public static func phrases(for language: String) -> [Phrase] {
        switch language.prefix(2).lowercased() {
        case "en": return english
        default:   return german
        }
    }

    /// Note-review variant of `phrases(for:)`. Coordinator calls this
    /// when state == .noteReview so the user can say drop / defer /
    /// replay / rerecord on top of the standard advance triggers.
    public static func noteReviewPhrases(for language: String) -> [Phrase] {
        switch language.prefix(2).lowercased() {
        case "en": return englishNoteReview
        default:   return germanNoteReview
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
                if dist <= phrase.maxDistance {
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
