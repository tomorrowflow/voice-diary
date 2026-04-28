import Foundation

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
        let session = LanguageModelSession(
            model: SystemLanguageModel.default,
            instructions: """
            You are the voice of a personal diary assistant. You ask one
            short, conversational follow-up question that invites the user
            to go deeper. Output ONLY the question — no preamble, no
            explanation, max 12 words. Never repeat the user's own words.
            """
        )
        let prompt = makeFollowUpPrompt(
            eventTitle: eventTitle,
            attendees: attendees,
            userTranscript: userTranscript,
            language: language
        )
        do {
            let response = try await session.respond(to: prompt)
            let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { throw LLMError.empty }
            return cleanForSpeech(text)
        } catch let error as LLMError {
            throw error
        } catch {
            throw LLMError.underlying(error)
        }
        #else
        throw LLMError.unavailable("FoundationModels_not_compiled_in")
        #endif
    }

    private func makeFollowUpPrompt(
        eventTitle: String,
        attendees: [String],
        userTranscript: String,
        language: String
    ) -> String {
        let lang = language.hasPrefix("de") ? "German" : "English"
        let attendeeLine = attendees.isEmpty ? "(no attendees)" : attendees.joined(separator: ", ")
        let transcriptLine = userTranscript.isEmpty
            ? "(transcript not available — ask a generic deepening question)"
            : userTranscript
        return """
        The user just reflected on a calendar event titled: \(eventTitle).
        Attendees: \(attendeeLine).
        User's response: \(transcriptLine)
        Language: \(lang).
        Generate one short follow-up question (max 12 words).
        Return only the question.
        """
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
