import Foundation
import NaturalLanguage

#if canImport(FoundationModels)
import FoundationModels
#endif

// Thin wrapper around Apple's on-device Foundation Models framework
// (iOS 26+). Used by the walkthrough for dynamic follow-up generation
// (M6) and by the implicit-todo extractor (M8). Both call sites tolerate
// `.unavailable` and fall back to deterministic templates / regex paths.
//
// We deliberately keep the public surface narrow so swapping in MLX Swift
// + Gemma 4 E4B (the documented fallback if Apple FM disappoints) is a
// single-file change.

public actor AppleFoundationLLM {
    public static let shared = AppleFoundationLLM()

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

    public init() {}

    /// Returns true when the on-device Foundation Models system model is
    /// reachable on the current device. False on simulators or older
    /// hardware where Apple Intelligence isn't enabled.
    public var isAvailable: Bool {
        #if canImport(FoundationModels)
        return SystemLanguageModel.default.isAvailable
        #else
        return false
        #endif
    }

    /// Generate a single conversational follow-up question (per SPEC
    /// §11.4). The caller passes the event the user just reflected on
    /// plus whatever transcript is available. Empty transcript is OK —
    /// the model still produces a generic "anything else?" prompt.
    public func generateFollowUp(
        eventTitle: String,
        attendees: [String],
        userTranscript: String,
        language: String
    ) async throws -> String {
        #if canImport(FoundationModels)
        guard SystemLanguageModel.default.isAvailable else {
            throw LLMError.unavailable("system_model_not_ready")
        }
        let isGerman = language.hasPrefix("de")
        let session = LanguageModelSession(
            model: SystemLanguageModel.default,
            instructions: Self.systemInstructions(german: isGerman)
        )
        let prompt = makeFollowUpPrompt(
            eventTitle: eventTitle,
            attendees: attendees,
            userTranscript: userTranscript,
            german: isGerman
        )
        do {
            let response = try await session.respond(to: prompt)
            let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { throw LLMError.empty }
            let cleaned = cleanForSpeech(text)
            // Validate language so a stray English answer doesn't end up
            // being read aloud by the German Piper voice (M6 dogfood:
            // every other follow-up came back in English even with a
            // German prompt). Throwing `.unavailable` makes the caller
            // fall back to the deterministic German rotation template.
            try Self.assertLanguage(cleaned, expectedGerman: isGerman)
            return cleaned
        } catch let error as LLMError {
            throw error
        } catch {
            throw LLMError.underlying(error)
        }
        #else
        throw LLMError.unavailable("FoundationModels_not_compiled_in")
        #endif
    }

    /// Scan a free-form segment transcript for *implicit* todos —
    /// commitments / next-actions the user spoke without an explicit
    /// trigger phrase ("ich rufe morgen Stephan an", "wir machen das
    /// nochmal"). Explicit todos are already captured by
    /// `TodoExtractor.extractExplicit`; this pass surfaces the rest.
    ///
    /// SPEC §8: returns at most 5 candidates, one short sentence each,
    /// always in the user's language. The caller dedupes against
    /// already-detected explicit todos and confirms each via the
    /// CLOSING confirmation flow before they reach the manifest.
    public func extractImplicit(
        transcript: String,
        language: String
    ) async throws -> [String] {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 20 else { return [] }
        #if canImport(FoundationModels)
        guard SystemLanguageModel.default.isAvailable else {
            throw LLMError.unavailable("system_model_not_ready")
        }
        let isGerman = language.hasPrefix("de")
        let session = LanguageModelSession(
            model: SystemLanguageModel.default,
            instructions: Self.implicitInstructions(german: isGerman)
        )
        let prompt = Self.implicitPrompt(transcript: trimmed, german: isGerman)
        do {
            let response = try await session.respond(to: prompt)
            let raw = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            return Self.parseImplicitList(raw)
        } catch {
            throw LLMError.underlying(error)
        }
        #else
        throw LLMError.unavailable("FoundationModels_not_compiled_in")
        #endif
    }

    private static func implicitInstructions(german: Bool) -> String {
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
            maximal 5 Einträgen zurück, jede Zeile beginnt mit "- ", jede
            Zeile ist EIN kurzer Satz im Imperativ ("Stephan anrufen",
            "Deck an Carsten schicken"). Wenn nichts Konkretes drin ist,
            antworte mit dem einzigen Wort "KEINE".
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

            Reply ONLY in English. Return a list of at most 5 items,
            each line starting with "- ", each line ONE short imperative
            sentence ("Call Stephan", "Send the deck to Carsten"). If
            nothing concrete is present, reply with the single word
            "NONE".
            """
        }
    }

    private static func implicitPrompt(transcript: String, german: Bool) -> String {
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

    /// Parse the model's bulleted list (or "KEINE" / "NONE") into an
    /// array of plain task strings. Tolerates "* item", "- item",
    /// "1. item", numbered lists, etc.
    private static func parseImplicitList(_ raw: String) -> [String] {
        let normalised = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalised.isEmpty { return [] }
        let upper = normalised.uppercased()
        if upper == "KEINE" || upper == "NONE" || upper == "—" { return [] }

        var items: [String] = []
        for rawLine in normalised.split(separator: "\n") {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            // Strip bullets and numbering.
            while let first = line.first, "-•*0123456789.):".contains(first) {
                line.removeFirst()
                line = line.trimmingCharacters(in: .whitespaces)
            }
            // Drop trailing punctuation.
            while let last = line.last, ".,;".contains(last) {
                line.removeLast()
            }
            let cleaned = line.trimmingCharacters(in: .whitespaces)
            guard cleaned.count >= 4 else { continue }
            // Reject obvious non-todos.
            if cleaned.uppercased() == "KEINE" || cleaned.uppercased() == "NONE" {
                continue
            }
            items.append(cleaned)
            if items.count >= 5 { break }
        }
        return items
    }

    private static func systemInstructions(german: Bool) -> String {
        if german {
            return """
            Du bist die Stimme einer persönlichen Tagebuch-Assistenz. Du
            stellst eine einzige, kurze, gesprochene Folgefrage, die zum
            Vertiefen einlädt. Antworte AUSSCHLIESSLICH auf Deutsch.
            Gib NUR die Frage zurück — keine Einleitung, keine Erklärung,
            maximal 12 Wörter. Wiederhole niemals die Worte der nutzenden
            Person wörtlich.
            """
        } else {
            return """
            You are the voice of a personal diary assistant. You ask one
            short, spoken follow-up question that invites the user to go
            deeper. Reply ONLY in English. Output ONLY the question — no
            preamble, no explanation, maximum 12 words. Never repeat the
            user's own words verbatim.
            """
        }
    }

    private func makeFollowUpPrompt(
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

    /// Throws `.unavailable` if the response is in the wrong language.
    /// `NLLanguageRecognizer` is fast (microseconds for short strings)
    /// and effectively zero-cost vs the LLM call.
    private static func assertLanguage(_ text: String, expectedGerman: Bool) throws {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let detected = recognizer.dominantLanguage else { return }
        let isGerman = detected == .german
        let isEnglish = detected == .english
        if expectedGerman, !isGerman {
            // Allow English if German wasn't recognised but the text is
            // very short (1–3 words like "Was war schwer?") — recogniser
            // can mis-flag short phrases. Otherwise reject.
            if isEnglish || text.split(separator: " ").count > 3 {
                throw LLMError.unavailable("language_mismatch_expected_de_got_\(detected.rawValue)")
            }
        } else if !expectedGerman, !isEnglish {
            if isGerman || text.split(separator: " ").count > 3 {
                throw LLMError.unavailable("language_mismatch_expected_en_got_\(detected.rawValue)")
            }
        }
    }

    private func cleanForSpeech(_ text: String) -> String {
        // The model occasionally returns the prompt prefix or wraps the
        // question in quotes. Strip those.
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
}
