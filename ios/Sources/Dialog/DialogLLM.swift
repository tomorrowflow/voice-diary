import Foundation
import NaturalLanguage

// Dialog-LLM abstraction (SPEC §11).
//
// One protocol, multiple backends. The walkthrough opener prep, the
// 6 s-lull follow-up, the note summary, and the implicit-todo extractor
// all route through here, so swapping the on-device model is a single
// resolver change instead of a coordinator rewrite.
//
// Current implementations:
//   * `AppleFoundationLLM`  — Apple's iOS 26 system model (~3B distilled).
//                              Always available, weak on free-form German.
//   * `GemmaDialogLLM`       — Gemma 4 E4B 4-bit via MLX Swift. Has to be
//                              downloaded to Application Support first;
//                              far stronger German once present.
//
// Selection lives in `DialogLLMResolver`. The caller never inspects which
// backend it's talking to — failures fall through to the next backend in
// the chain, and finally to the deterministic templates / regex paths.

public protocol DialogLLM: Sendable {

    /// Cheap, fast check used by the resolver to decide whether to even
    /// hand a request to this backend. `false` should be returned without
    /// blocking on long operations — load the model lazily inside the
    /// generation methods, not here.
    var isAvailable: Bool { get async }

    /// One short conversational follow-up question for a calendar event
    /// (SPEC §11.4). Empty `userTranscript` means the user stayed silent.
    func generateFollowUp(
        eventTitle: String,
        attendees: [String],
        userTranscript: String,
        language: String
    ) async throws -> String

    /// Same shape as `generateFollowUp`, seeded from a user-defined
    /// `general` section instead of a calendar event.
    func generateGeneralFollowUp(
        sectionTitle: String,
        sectionIntro: String,
        userTranscript: String,
        language: String
    ) async throws -> String

    /// One varied, day-aware spoken opener for a calendar event
    /// (SPEC §11). The caller keeps the deterministic template as the
    /// fallback when this throws.
    func generateEventOpener(
        context: EventOpenerContext,
        language: String
    ) async throws -> String

    /// Condense a voice-note transcript into one short spoken sentence
    /// for the note-review prompt.
    func summarizeNote(
        transcript: String,
        language: String
    ) async throws -> String

    /// Scan a free-form segment transcript for implicit todos (SPEC §8).
    /// At most 5 candidates; the caller dedupes against explicit todos
    /// and confirms each one at CLOSING before they reach the manifest.
    func extractImplicit(
        transcript: String,
        language: String
    ) async throws -> [ImplicitCandidate]
}

// MARK: - Shared error type

public enum LLMError: Error, CustomStringConvertible {
    case unavailable(String)
    case empty
    case underlying(any Error)

    public var description: String {
        switch self {
        case .unavailable(let s): return "fm_unavailable: \(s)"
        case .empty: return "fm_empty_response"
        case .underlying(let e): return "fm_error: \(e)"
        }
    }
}

// MARK: - Shared value types

/// Metadata the opener generator weaves into a varied, day-aware opening
/// line. All time/duration fields arrive already rendered as Voxtral-safe
/// spoken strings (e.g. `"von 10 bis 11 Uhr"`, `"eine Stunde"`) so the
/// model can reuse them verbatim — it is explicitly told never to invent
/// a digital clock time.
public struct EventOpenerContext: Sendable {
    public var title: String
    public var attendees: [String]
    public var spokenTime: String
    public var spokenTimeRange: String
    public var durationText: String
    public var isRecurring: Bool
    public var isExternal: Bool
    public var agendaPreview: String
    /// "first" | "last" | "middle" — drives tone (kick-off vs wrap-up).
    public var position: String
    /// The deterministic slot (`one_on_one`, `short_meeting`, …) as a
    /// soft steer; the model may ignore it but it nudges the framing.
    public var slot: String

    public init(
        title: String,
        attendees: [String],
        spokenTime: String,
        spokenTimeRange: String,
        durationText: String,
        isRecurring: Bool,
        isExternal: Bool,
        agendaPreview: String,
        position: String,
        slot: String
    ) {
        self.title = title
        self.attendees = attendees
        self.spokenTime = spokenTime
        self.spokenTimeRange = spokenTimeRange
        self.durationText = durationText
        self.isRecurring = isRecurring
        self.isExternal = isExternal
        self.agendaPreview = agendaPreview
        self.position = position
        self.slot = slot
    }
}

/// One implicit-todo candidate produced by the on-device LLM.
/// `text` is the paraphrased imperative ("Stephan anrufen");
/// `sourceQuote` is a short verbatim phrase from the transcript that
/// justified it, when the model returned one. The confirmation UI uses
/// the quote to highlight the originating words inside the surrounding
/// 5-line excerpt; absence is tolerated and the UI falls back to fuzzy
/// match on the candidate text.
public struct ImplicitCandidate: Sendable, Equatable {
    public let text: String
    public let sourceQuote: String?
    public init(text: String, sourceQuote: String? = nil) {
        self.text = text
        self.sourceQuote = sourceQuote
    }
}

// MARK: - Shared prompt builders + validators
//
// Both Apple FM and Gemma run the same prompt shapes against their own
// backends, then apply the same language guard and speech sanitisation.
// Centralising the prompts here keeps the two implementations word-for-
// word equivalent — drift between them would silently change the tone of
// the walkthrough depending on which model is selected.

public enum LLMHelpers {

    // MARK: System instructions

    public static func followUpInstructions(german: Bool) -> String {
        if german {
            return """
            Du bist die Stimme einer persönlichen Tagebuch-Assistenz. Du
            stellst eine einzige, kurze, gesprochene Folgefrage, die zum
            Vertiefen einlädt. Antworte AUSSCHLIESSLICH auf Deutsch.
            Sprich die nutzende Person durchgehend mit "du" an (du, dich,
            dir, dein) — NIEMALS mit "Sie".
            Die Frage bezieht sich auf einen Termin, der heute bereits
            stattgefunden hat — formuliere rückblickend im Präteritum
            oder Perfekt ("war …", "hast du … mitgenommen", "ging es um
            …"). NIEMALS zukunftsgerichtet ("wirst du …", "steht an").
            Gib NUR die Frage zurück — keine Einleitung, keine Erklärung,
            maximal 12 Wörter. Wiederhole niemals die Worte der nutzenden
            Person wörtlich.
            """
        } else {
            return """
            You are the voice of a personal diary assistant. You ask one
            short, spoken follow-up question that invites the user to go
            deeper. Reply ONLY in English. The question is about a meeting
            that already happened earlier today — phrase it retrospectively
            ("was it …", "did you take away …", "what stood out …"). NEVER
            anticipatory ("will you …", "are you going to …"). Output ONLY
            the question — no preamble, no explanation, maximum 12 words.
            Never repeat the user's own words verbatim.
            """
        }
    }

    public static func summaryInstructions(german: Bool) -> String {
        if german {
            return """
            Du fasst eine kurze Sprachnotiz für ein Tagebuch zusammen. Gib
            EINEN kurzen Aussagesatz zurück (maximal 14 Wörter), der den
            Kern der Notiz wiedergibt. Antworte AUSSCHLIESSLICH auf
            Deutsch. Falls die nutzende Person erwähnt wird, immer in der
            Du-Form (du, dich, dir) — NIEMALS in der Sie-Form. Gib NUR
            die Zusammenfassung zurück — keine Einleitung, keine Frage,
            keine Anführungszeichen.
            """
        } else {
            return """
            You summarize a short voice note for a diary. Return ONE short
            statement (max 14 words) capturing the gist of the note. Reply
            ONLY in English. Output ONLY the summary — no preamble, no
            question, no quotation marks.
            """
        }
    }

    public static func openerInstructions(german: Bool) -> String {
        if german {
            return """
            Du bist die Stimme einer persönlichen Tagebuch-Assistenz und
            eröffnest die abendliche Reflexion zu EINEM Kalendertermin.
            Sprich die nutzende Person durchgehend mit "du" an (du, dich,
            dir, dein) — NIEMALS mit "Sie". Formuliere EINEN kurzen,
            natürlich gesprochenen Einstieg (maximal 25 Wörter):
            zuerst ein knapper Bezug auf den Termin, dann GENAU EINE kurze,
            offene Frage, die zum Erzählen einlädt.

            Variiere die Formulierung — klinge nicht jeden Tag gleich.
            Nutze die salientesten Angaben (Titel, Personen, Uhrzeit,
            Wiederholung, Agenda), aber zähle sie nicht mechanisch auf.

            WICHTIG — Zeitform: Wir blicken am Abend auf den Tag zurück.
            Der Termin hat heute bereits stattgefunden. Sprich IMMER
            rückblickend im Präteritum oder Perfekt (z. B. "du hattest",
            "der Termin lief", "die Runde war", "ihr habt … besprochen").
            NIEMALS Präsens oder Futur, NIEMALS zukunftsgerichtete Wörter
            wie "gleich", "demnächst", "wirst du", "steht an".

            Harte Regeln:
            - Antworte AUSSCHLIESSLICH auf Deutsch.
            - Verwende Uhrzeiten NUR in der vorgegebenen gesprochenen Form
              (z. B. "um 10 Uhr", "von 10 bis 11 Uhr"). Schreibe NIEMALS
              Ziffern-Uhrzeiten wie "10:00".
            - Gib NUR den Einstieg zurück — keine Einleitung, keine
              Anführungszeichen, keine Aufzählung.
            """
        } else {
            return """
            You are the voice of a personal diary assistant opening the
            evening reflection on ONE calendar event. Address the user as
            "you". Write ONE short, naturally spoken opener (max 25 words):
            first a brief reference to the event, then EXACTLY ONE short,
            open question that invites the user to talk.

            Vary the phrasing — don't sound the same every day. Use the
            most salient details (title, people, time, recurrence, agenda),
            but don't list them mechanically.

            IMPORTANT — Tense: this is an evening review of the day that
            has already happened. The meeting took place earlier today.
            ALWAYS phrase the opener in the past tense (e.g. "you had",
            "the meeting ran", "the room was", "you went through …").
            NEVER present or future, NEVER anticipatory phrasing like
            "about to", "coming up", "you'll", "is going to".

            Hard rules:
            - Reply ONLY in English.
            - Use times ONLY in the given spoken form (e.g. "at ten",
              "from ten to eleven"). NEVER write a digital clock time like
              "10:00".
            - Output ONLY the opener — no preamble, no quotation marks, no
              bullet list.
            """
        }
    }

    public static func implicitInstructions(german: Bool) -> String {
        if german {
            return """
            Du analysierst die Reflexion einer Person zu einem Termin und
            extrahierst NUR konkrete, in dieser Reflexion ausgesprochene
            Vorhaben oder nächste Schritte (sogenannte implizite Aufgaben).
            Beispiele: "Ich rufe morgen Stephan an", "Wir machen die
            Nachbereitung am Dienstag", "Ich muss noch das Deck schicken".
            Keine bereits erledigten Tätigkeiten. Keine Wünsche oder
            Gefühle. Keine allgemeinen Beobachtungen.

            Antworte AUSSCHLIESSLICH auf Deutsch. Gib eine Liste mit
            maximal 5 Einträgen zurück. Jeder Eintrag besteht aus GENAU
            zwei Zeilen:
              - Erste Zeile beginnt mit "- " und enthält EINEN kurzen
                Satz im Imperativ ("Stephan anrufen",
                "Deck an Carsten schicken").
              - Zweite Zeile beginnt mit ">> " und ist ein WÖRTLICHES
                Zitat aus der Reflexion (10–120 Zeichen), das diese
                Aufgabe begründet. Verwende NUR Worte, die exakt im
                Transkript stehen — keine Umformulierung.

            Wenn nichts Konkretes drin ist, antworte mit dem einzigen
            Wort "KEINE".
            """
        } else {
            return """
            You analyse a user's reflection on one calendar event and
            extract ONLY concrete commitments or next actions the user
            stated within this reflection (so-called implicit todos).
            Examples: "I'll call Stephan tomorrow", "We need to do the
            follow-up on Tuesday", "I still have to send the deck".
            No already-completed actions. No feelings or wishes. No
            generic observations.

            Reply ONLY in English. Return a list of at most 5 items.
            Each item is EXACTLY two lines:
              - First line starts with "- " and contains ONE short
                imperative sentence ("Call Stephan",
                "Send the deck to Carsten").
              - Second line starts with ">> " and is a VERBATIM quote
                from the reflection (10–120 characters) that justifies
                this todo. Use ONLY words that appear exactly in the
                transcript — no paraphrasing.

            If nothing concrete is present, reply with the single word
            "NONE".
            """
        }
    }

    // MARK: Prompt assembly

    public static func followUpPrompt(
        eventTitle: String,
        attendees: [String],
        userTranscript: String,
        german: Bool
    ) -> String {
        let attendeeLine = attendees.isEmpty
            ? (german ? "(keine Teilnehmenden)" : "(no attendees)")
            : attendees.joined(separator: ", ")
        let transcriptLine: String
        if userTranscript.isEmpty {
            transcriptLine = german
                ? "(Transkript nicht verfügbar — stelle eine allgemein vertiefende Frage.)"
                : "(transcript not available — ask a generic deepening question)"
        } else {
            transcriptLine = userTranscript
        }
        if german {
            return """
            Der Nutzer hat gerade über einen Kalendertermin reflektiert.
            Titel: \(eventTitle).
            Teilnehmende: \(attendeeLine).
            Reaktion des Nutzers: \(transcriptLine)
            Stelle EINE kurze Folgefrage (maximal 12 Wörter) AUF DEUTSCH.
            Gib nur die Frage zurück.
            """
        } else {
            return """
            The user just reflected on a calendar event.
            Title: \(eventTitle).
            Attendees: \(attendeeLine).
            User's response: \(transcriptLine)
            Generate ONE short follow-up question (max 12 words) IN ENGLISH.
            Return only the question.
            """
        }
    }

    public static func generalFollowUpPrompt(
        sectionTitle: String,
        sectionIntro: String,
        userTranscript: String,
        german: Bool
    ) -> String {
        let trimmedIntro = sectionIntro.trimmingCharacters(in: .whitespacesAndNewlines)
        let introLine = trimmedIntro.isEmpty
            ? (german ? "(keine Einleitung vorhanden)" : "(no intro provided)")
            : trimmedIntro
        let transcriptLine: String
        if userTranscript.isEmpty {
            transcriptLine = german
                ? "(Transkript nicht verfügbar — stelle eine zur Einleitung passende Vertiefung.)"
                : "(transcript not available — ask a deepening question that fits the intro)"
        } else {
            transcriptLine = userTranscript
        }
        if german {
            return """
            Der Nutzer reflektiert gerade in einem benutzerdefinierten Tagebuch-Abschnitt.
            Abschnittstitel: \(sectionTitle).
            Einleitung des Abschnitts: \(introLine).
            Bisherige Reaktion des Nutzers: \(transcriptLine)
            Stelle EINE kurze Folgefrage (maximal 12 Wörter) AUF DEUTSCH,
            die im Geist der Einleitung weiterführt. Gib nur die Frage zurück.
            """
        } else {
            return """
            The user is reflecting in a user-defined diary section.
            Section title: \(sectionTitle).
            Section intro: \(introLine).
            User's response so far: \(transcriptLine)
            Generate ONE short follow-up question (max 12 words) IN ENGLISH
            that continues in the spirit of the intro. Return only the question.
            """
        }
    }

    public static func summaryPrompt(transcript: String, german: Bool) -> String {
        if german {
            return """
            Fasse diese Sprachnotiz in einem kurzen Satz zusammen:
            \(transcript)
            Gib nur die Zusammenfassung auf Deutsch zurück.
            """
        } else {
            return """
            Summarize this voice note in one short statement:
            \(transcript)
            Return only the summary in English.
            """
        }
    }

    public static func openerPrompt(ctx: EventOpenerContext, german: Bool) -> String {
        let title = ctx.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let agenda = ctx.agendaPreview
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(280)
        let people = ctx.attendees.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        if german {
            var lines: [String] = []
            lines.append("Titel: \(title.isEmpty ? "(ohne Titel)" : title)")
            lines.append(people.isEmpty
                ? "Teilnehmende: (keine)"
                : "Teilnehmende: \(people.joined(separator: ", "))")
            if !ctx.spokenTime.isEmpty { lines.append("Beginn: \(ctx.spokenTime)") }
            if !ctx.spokenTimeRange.isEmpty { lines.append("Zeitraum: \(ctx.spokenTimeRange)") }
            if !ctx.durationText.isEmpty { lines.append("Dauer: \(ctx.durationText)") }
            lines.append("Wiederkehrender Termin: \(ctx.isRecurring ? "ja" : "nein")")
            lines.append("Externe Teilnehmende: \(ctx.isExternal ? "ja" : "nein")")
            lines.append("Position im Tag: \(ctx.position)")
            lines.append("Kategorie: \(ctx.slot)")
            if !agenda.isEmpty { lines.append("Agenda/Notiz: \(agenda)") }
            return """
            Termin-Kontext:
            \(lines.joined(separator: "\n"))

            Schreibe den gesprochenen Einstieg gemäss den Anweisungen.
            """
        } else {
            var lines: [String] = []
            lines.append("Title: \(title.isEmpty ? "(no title)" : title)")
            lines.append(people.isEmpty
                ? "Attendees: (none)"
                : "Attendees: \(people.joined(separator: ", "))")
            if !ctx.spokenTime.isEmpty { lines.append("Start: \(ctx.spokenTime)") }
            if !ctx.spokenTimeRange.isEmpty { lines.append("Time range: \(ctx.spokenTimeRange)") }
            if !ctx.durationText.isEmpty { lines.append("Duration: \(ctx.durationText)") }
            lines.append("Recurring: \(ctx.isRecurring ? "yes" : "no")")
            lines.append("External attendees: \(ctx.isExternal ? "yes" : "no")")
            lines.append("Position in day: \(ctx.position)")
            lines.append("Category: \(ctx.slot)")
            if !agenda.isEmpty { lines.append("Agenda/note: \(agenda)") }
            return """
            Event context:
            \(lines.joined(separator: "\n"))

            Write the spoken opener following the instructions.
            """
        }
    }

    public static func implicitPrompt(transcript: String, german: Bool) -> String {
        if german {
            return """
            Reflexion:
            \(transcript)

            Extrahiere die impliziten Aufgaben gemäss den Anweisungen.
            """
        } else {
            return """
            Reflection:
            \(transcript)

            Extract the implicit todos following the instructions.
            """
        }
    }

    // MARK: Output validation + sanitisation

    /// Throws `.unavailable` if the response is in the wrong language.
    /// Cheap (microseconds) compared to the LLM call itself.
    public static func assertLanguage(_ text: String, expectedGerman: Bool) throws {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let detected = recognizer.dominantLanguage else { return }
        let isGerman = detected == .german
        let isEnglish = detected == .english
        if expectedGerman, !isGerman {
            // Short phrases (1–3 words) can mis-flag; only reject when
            // we have enough text for the verdict to be reliable, or when
            // the recogniser is confident about English specifically.
            if isEnglish || text.split(separator: " ").count > 3 {
                throw LLMError.unavailable("language_mismatch_expected_de_got_\(detected.rawValue)")
            }
        } else if !expectedGerman, !isEnglish {
            if isGerman || text.split(separator: " ").count > 3 {
                throw LLMError.unavailable("language_mismatch_expected_en_got_\(detected.rawValue)")
            }
        }
    }

    /// True if the text contains a digital clock time like "10:00" or
    /// "9:5" — the exact shape that glitches Voxtral. Used to reject an
    /// opener that ignored the pre-spelled spoken time.
    public static func containsDigitalClock(_ text: String) -> Bool {
        guard let re = try? NSRegularExpression(pattern: #"\d{1,2}:\d{2}"#) else {
            return false
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return re.firstMatch(in: text, range: range) != nil
    }

    /// Strip stray markdown, surrounding quotes, and trailing whitespace
    /// that the model sometimes adds around a single-question response.
    public static func cleanForSpeech(_ text: String) -> String {
        var s = text
        s = s.replacingOccurrences(of: "**", with: "")
        s = s.replacingOccurrences(of: "*", with: "")
        if let first = s.first, ["'", "\"", "“", "‘"].contains(first) {
            s.removeFirst()
        }
        if let last = s.last, ["'", "\"", "”", "’"].contains(last) {
            s.removeLast()
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Parse the implicit-todo two-line-per-item format into candidates
    /// with optional verbatim source quotes. Tolerant of single-line
    /// outputs, bullet variants (`*`, `•`, numbered), inline `>>`, and
    /// stray blank lines. The quote is validated against the transcript:
    /// if the model paraphrased instead of quoting verbatim, the quote is
    /// dropped and the UI falls back to fuzzy match on the candidate text.
    public static func parseImplicitList(_ raw: String, transcript: String) -> [ImplicitCandidate] {
        let normalised = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalised.isEmpty { return [] }
        let upper = normalised.uppercased()
        if upper == "KEINE" || upper == "NONE" || upper == "—" { return [] }

        let transcriptLower = transcript.lowercased()

        var items: [ImplicitCandidate] = []
        var pendingText: String? = nil
        var pendingQuote: String? = nil

        func commit() {
            if let text = pendingText {
                let quote: String? = {
                    guard let q = pendingQuote, !q.isEmpty else { return nil }
                    return transcriptLower.contains(q.lowercased()) ? q : nil
                }()
                items.append(ImplicitCandidate(text: text, sourceQuote: quote))
            }
            pendingText = nil
            pendingQuote = nil
        }

        let quoteChars = CharacterSet(charactersIn: " \"'„“”«»")

        for rawLine in normalised.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            if line.hasPrefix(">>") {
                let q = String(line.dropFirst(2)).trimmingCharacters(in: quoteChars)
                if pendingText != nil { pendingQuote = q.isEmpty ? nil : q }
                continue
            }

            var inlineQuote: String? = nil
            if let r = line.range(of: ">>") {
                let after = line[r.upperBound...]
                    .trimmingCharacters(in: quoteChars)
                inlineQuote = after.isEmpty ? nil : after
                line = String(line[..<r.lowerBound])
                    .trimmingCharacters(in: .whitespaces)
            }

            commit()

            var head = line
            while let first = head.first, "-•*0123456789.):".contains(first) {
                head.removeFirst()
                head = head.trimmingCharacters(in: .whitespaces)
            }
            while let last = head.last, ".,;".contains(last) {
                head.removeLast()
            }
            head = head.trimmingCharacters(in: quoteChars)
            let cleaned = head.trimmingCharacters(in: .whitespaces)
            guard cleaned.count >= 4 else { continue }
            if cleaned.uppercased() == "KEINE" || cleaned.uppercased() == "NONE" {
                continue
            }
            pendingText = cleaned
            if let q = inlineQuote { pendingQuote = q }

            if items.count >= 5 { break }
        }
        commit()
        if items.count > 5 { items = Array(items.prefix(5)) }
        return items
    }
}
