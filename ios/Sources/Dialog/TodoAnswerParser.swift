import Foundation

// Parses the user's spoken answer to a CLOSING todo-confirmation prompt
// ("Stephan anrufen — ja, nein, oder anders?"). Returns one of three
// outcomes:
//
//   .confirm   — user said yes / ja / passt / etc.
//   .reject    — user said no  / nein / weg / etc.
//   .refine(s) — user spoke a refined version of the task; `s` is the
//                trimmed transcript ready to use as the new task text
//
// Pure-logic, no AVFoundation. Tested in `TodoAnswerParserTests`.

public enum TodoAnswerOutcome: Equatable, Sendable {
    case confirm
    case reject
    case refine(String)
    case unknown
}

public enum TodoAnswerParser {

    private static let confirmTokens: Set<String> = [
        // German
        "ja", "jo", "jep", "joa", "stimmt", "klar", "passt",
        "korrekt", "richtig", "genau", "okay", "ok", "übernehmen",
        "übernimm", "speichern", "speicher", "okay so", "ja gerne",
        "ja bitte", "ja genau", "ja klar",
        // English
        "yes", "yeah", "yep", "yup", "correct", "right", "sure",
        "fine", "confirm", "confirmed", "save", "keep", "keep it",
    ]

    private static let rejectTokens: Set<String> = [
        // German
        "nein", "nö", "nee", "weg", "lass weg", "verwerfen", "löschen",
        "lösch", "weglassen", "nicht aufnehmen", "nein danke",
        "nein lass", "doch nicht", "abbrechen",
        // English
        "no", "nope", "nah", "skip", "drop", "remove", "delete",
        "discard", "no thanks", "never mind", "nevermind", "cancel",
    ]

    /// Phrases that mean "I want to type/say a different version" but
    /// the user didn't yet give the refined text. Caller should expose
    /// the refine UI without immediately confirming.
    private static let switchToRefineTokens: Set<String> = [
        "anders", "umformulieren", "ändern", "anders formulieren",
        "different", "rephrase", "edit", "change it",
    ]

    /// Maximum number of words for a phrase to still count as a
    /// keyword-only answer (yes / no / different). Anything longer is
    /// treated as a refinement. Three words covers "ja bitte gerne",
    /// "no thanks please", "lass das weg".
    private static let keywordWordCap = 4

    public static func parse(_ raw: String) -> TodoAnswerOutcome {
        let normalised = normalise(raw)
        guard !normalised.isEmpty else { return .unknown }

        // 1. Exact-match a multi-word keyword phrase.
        if confirmTokens.contains(normalised)        { return .confirm }
        if rejectTokens.contains(normalised)         { return .reject }
        if switchToRefineTokens.contains(normalised) { return .unknown }

        let words = normalised.split(separator: " ").map(String.init)
        let firstWord = words.first ?? ""

        // 2. Short single-leading-keyword form: "ja, klar passt schon",
        //    "nein lass das" — accept if the answer is short and starts
        //    with a confirm/reject token.
        if words.count <= keywordWordCap {
            if confirmTokens.contains(firstWord) { return .confirm }
            if rejectTokens.contains(firstWord)  { return .reject }
            if switchToRefineTokens.contains(firstWord) { return .unknown }
        }

        // 3. Longer phrases — if the answer LEADS with a confirm/reject
        //    keyword we still honour the intent ("ja, das machen wir
        //    morgen früh"). Strip the leading token, keep the rest as
        //    the refined version when the user is qualifying their yes
        //    with extra detail.
        if confirmTokens.contains(firstWord) {
            let rest = words.dropFirst().joined(separator: " ")
            if rest.split(separator: " ").count >= 3 {
                return .refine(prettify(rest))
            }
            return .confirm
        }
        if rejectTokens.contains(firstWord) {
            return .reject
        }

        // 4. Anything else is treated as the refined task text.
        return .refine(prettify(normalised))
    }

    // MARK: - Helpers

    /// Lower-case, strip filler punctuation and "ähm" / "uhm" hesitation
    /// markers, collapse whitespace.
    private static func normalise(_ s: String) -> String {
        var out = s.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip punctuation everywhere — it only confuses the keyword
        // lookup. "ja, bitte" should match "ja bitte" in confirmTokens,
        // and "skip." should match "skip".
        out.removeAll { ",;:!?".contains($0) }
        // Trailing periods only (so abbreviations mid-sentence survive
        // for refined task text — "Mon." stays a recognisable word in
        // the prettified version).
        while let last = out.last, last == "." {
            out.removeLast()
        }
        // Drop hesitation tokens at the start.
        let hesitations = ["äh", "ähm", "ehm", "hmm", "uh", "um", "uhm", "hm", "ja also", "also"]
        var changed = true
        while changed {
            changed = false
            for token in hesitations {
                if out.hasPrefix(token + " ") {
                    out.removeFirst(token.count + 1)
                    changed = true
                    break
                }
            }
            out = out.trimmingCharacters(in: .whitespaces)
        }
        // Collapse double spaces.
        while out.contains("  ") {
            out = out.replacingOccurrences(of: "  ", with: " ")
        }
        return out
    }

    /// Capitalise the first letter so the refined task reads cleanly
    /// ("stephan morgen anrufen" → "Stephan morgen anrufen").
    private static func prettify(_ s: String) -> String {
        guard let first = s.first else { return s }
        return first.uppercased() + s.dropFirst()
    }
}
