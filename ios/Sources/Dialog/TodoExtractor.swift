import Foundation

// Detect explicit ToDo items inside a transcript and parse a due date
// when one is mentioned. SPEC §8 specifies the trigger phrases and the
// `Offen` default status; the server's `document_processor.py` converts
// the manifest's `todos_detected` into a German status block in the
// narrative markdown ingested into LightRAG.
//
// Implicit detection (via Apple Foundation Models) and the CLOSING
// confirmation pass are M8 phase B — they live behind the same call
// site so the coordinator stays linear.

public enum TodoExtractor {

    // MARK: - Hallucination denylist

    /// Stock phrases Parakeet (and most streaming ASRs trained on
    /// scraped video data) tend to emit on near-silence — "vielen Dank
    /// fürs Zuschauen", "Untertitel von …", "thanks for watching", etc.
    /// Stripping them before todo extraction stops the on-device LLM
    /// from confidently inventing a follow-up todo from a hallucinated
    /// sentence ("Den Kanal abonnieren" turning into "Channel-Abo
    /// erneuern"). The caller — `WalkthroughCoordinator.finalise` —
    /// also bails on todo extraction entirely when the *residual* is
    /// shorter than 20 characters, so a transcript that was nothing
    /// but hallucinations no longer produces any todos at all.
    ///
    /// Patterns are matched case-insensitively, with whitespace
    /// flexibility, and stripped non-destructively (the user-facing
    /// transcript stays intact — we only sanitise the copy fed to the
    /// extractors).
    private static let hallucinationPatterns: [String] = [
        // German YouTube-style filler
        "vielen dank fürs zuschauen",
        "danke fürs zuschauen",
        "vielen dank fürs anschauen",
        "bis zum nächsten mal",
        "bis zum nächsten video",
        "untertitel(?: im auftrag des zdf)?(?: für funk)?",
        "untertitelung(?: des zdf)?",
        "abonniert den kanal",
        "abonniert (?:diesen )?kanal",
        "lasst ein like da",
        "copyright wdr",
        // English equivalents
        "thanks for watching",
        "thank you for watching",
        "subtitles? by",
        "captions? by",
        "like and subscribe",
        "see you next time",
        "see you in the next video",
    ]

    private nonisolated(unsafe) static let hallucinationRegex: Regex<Substring> = {
        let alt = hallucinationPatterns.joined(separator: "|")
        let pattern = #"(?i)\b(?:"# + alt + #")\b[\s.,!?]*"#
        return try! Regex(pattern)
    }()

    /// Strip stock ASR-hallucination phrases from a transcript. Returns
    /// the sanitised text — empty when the transcript was nothing but
    /// hallucinations. Callers can use a length check on the result to
    /// decide whether to skip todo extraction entirely.
    public static func sanitiseForTodos(_ transcript: String) -> String {
        transcript
            .replacing(hallucinationRegex, with: "")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Trigger phrases

    /// Case-insensitive regex matching German + English explicit-todo
    /// trigger phrases. The capture group is the rest of the sentence
    /// (up to the next sentence-ending punctuation or 200 chars).
    public nonisolated(unsafe) static let triggerRegex: Regex = {
        // Order matters — longer phrases first so "ich muss noch" wins
        // over "ich muss".
        let phrases = [
            "ich muss noch",
            "ich sollte noch",
            "wir müssen noch",
            "wir sollten noch",
            "ich muss",
            "ich sollte",
            "wir müssen",
            "wir sollten",
            "aufgabe",
            "to-?do",
            "i need to",
            "i should",
            "we need to",
            "we should",
            "let'?s",
            "action item",
        ]
        let alternation = phrases.joined(separator: "|")
        // (?i) inline case-insensitive; non-capturing trigger group;
        // capture stops at . ! ? or end-of-string.
        let pattern = #"(?i)(?:\b(?:"# + alternation + #")\b)\s*[:,\-]?\s*(.{3,200}?)(?=[.!?]|\Z)"#
        return try! Regex(pattern)
    }()

    // MARK: - Public entry point

    public static func extractExplicit(
        text: String,
        language: String,
        sourceSegmentID: String
    ) -> [Todo] {
        guard !text.isEmpty else { return [] }
        var found: [Todo] = []
        var seen: Set<String> = []
        for match in text.matches(of: triggerRegex) {
            // The capture is at output[1] — match[0] is the whole hit.
            guard match.output.count >= 2 else { continue }
            let raw = String(text[match.output[1].range!]).trimmingCharacters(in: .whitespaces)
            let cleaned = clean(raw)
            guard !cleaned.isEmpty else { continue }
            // De-duplicate (same trigger may match twice in a long monologue).
            let key = cleaned.lowercased()
            if seen.contains(key) { continue }
            seen.insert(key)

            // The verbatim span from the transcript — trigger phrase plus
            // the captured tail. The TodoConfirmationCard highlights this
            // inside a 5-line excerpt, so we want the original wording
            // rather than the cleaned paraphrase.
            let fullSpan = String(text[match.output[0].range!]).trimmingCharacters(in: .whitespaces)
            let due = parseDueDate(in: cleaned, language: language)
            found.append(Todo(
                text: cleaned,
                type: "explicit",
                due: due,
                status: "Offen",
                source_segment_id: sourceSegmentID,
                source_quote: fullSpan.isEmpty ? nil : fullSpan
            ))
        }
        return found
    }

    // MARK: - Cleanup

    private static func clean(_ s: String) -> String {
        var out = s
        // Drop trailing "und ..." continuation noise.
        if let r = out.range(of: #"\b(und|and|sowie)\b\s.*$"#, options: .regularExpression) {
            out.removeSubrange(r)
        }
        out = out.trimmingCharacters(in: CharacterSet(charactersIn: " ,;:-—"))
        // Capitalise first letter for readability.
        if let first = out.first {
            out = first.uppercased() + out.dropFirst()
        }
        return out
    }

    // MARK: - Due-date parsing

    /// Looks for "morgen" / "übermorgen" / "tomorrow" / weekday name /
    /// ISO YYYY-MM-DD inside the captured task text. Returns ISO date
    /// string or nil. SPEC §8: "Don't try to extract every kind of date
    /// format. Start with ISO + named weekdays + 'morgen'/'übermorgen'."
    public static func parseDueDate(in text: String, language: String) -> String? {
        let now = Date()
        let cal = Calendar(identifier: .gregorian)
        let lower = text.lowercased()

        // ISO date
        if let m = lower.firstMatch(of: try! Regex(#"(20\d{2})-(0[1-9]|1[0-2])-(0[1-9]|[12]\d|3[01])"#)),
           m.output.count > 0 {
            return String(lower[m.range])
        }
        // Tomorrow / day after tomorrow.
        if lower.contains("übermorgen") || lower.contains("day after tomorrow") {
            return iso(date: cal.date(byAdding: .day, value: 2, to: now)!)
        }
        if lower.contains("morgen") || lower.contains("tomorrow") {
            return iso(date: cal.date(byAdding: .day, value: 1, to: now)!)
        }
        // Weekday names — pick the next occurrence of the named weekday
        // (today + 1..7 days). German + English.
        let weekdayMap: [String: Int] = [
            // Sunday=1 in Calendar
            "sonntag": 1, "montag": 2, "dienstag": 3, "mittwoch": 4,
            "donnerstag": 5, "freitag": 6, "samstag": 7,
            "sunday": 1, "monday": 2, "tuesday": 3, "wednesday": 4,
            "thursday": 5, "friday": 6, "saturday": 7,
        ]
        for (name, weekday) in weekdayMap where lower.contains(name) {
            if let next = nextDate(weekday: weekday, after: now, calendar: cal) {
                return iso(date: next)
            }
        }
        return nil
    }

    private static func nextDate(weekday: Int, after date: Date, calendar: Calendar) -> Date? {
        var components = DateComponents()
        components.weekday = weekday
        return calendar.nextDate(
            after: date,
            matching: components,
            matchingPolicy: .nextTime,
            direction: .forward
        )
    }

    private static func iso(date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }
}
