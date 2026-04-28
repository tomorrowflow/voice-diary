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
