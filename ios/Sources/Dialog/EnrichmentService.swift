import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

// Mid-session enrichment: route a free-form user question to the right
// server endpoint, await the speech-ready summary, hand back to the TTS
// caller.
//
// Phase A (current commit) — text-input entry: the user types the
// question via a modal in the walkthrough UI. Phase B (next commit)
// adds the wake-word + voice-question audio path.

public enum EnrichmentIntent: String, Sendable {
    case email_lookup
    case past_diary
    case calendar_detail
    case unknown
}

public actor EnrichmentService {
    public static let shared = EnrichmentService()

    public struct Result: Sendable {
        public let intent: EnrichmentIntent
        public let summary: String
        public let sourceCount: Int?
    }

    public enum EnrichmentError: Error, CustomStringConvertible {
        case classificationFailed(String)
        case serverFailed(String)
        case empty

        public var description: String {
            switch self {
            case .classificationFailed(let s): return "intent_classification_failed: \(s)"
            case .serverFailed(let s):         return "enrichment_server_failed: \(s)"
            case .empty:                       return "enrichment_empty"
            }
        }
    }

    public init() {}

    /// End-to-end enrichment: classify → call the right endpoint → return
    /// a TTS-ready summary string.
    public func enrich(
        query: String,
        responseLanguage: String = "de"
    ) async throws -> Result {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw EnrichmentError.empty }

        let intent = await classify(query: trimmed)
        Log.app.info("enrichment intent: \(intent.rawValue, privacy: .public) for query: \(trimmed, privacy: .public)")

        switch intent {
        case .email_lookup:
            let r = try await ServerClient.shared.emailSearch(
                query: trimmed,
                responseLanguage: responseLanguage
            )
            return Result(intent: intent, summary: r.summary, sourceCount: r.source_count)
        case .past_diary:
            let r = try await ServerClient.shared.lightragQuery(
                query: trimmed,
                responseLanguage: responseLanguage
            )
            return Result(intent: intent, summary: r.summary, sourceCount: r.source_count)
        case .calendar_detail:
            // Without a graph_event_id the calendar_detail intent has no
            // single endpoint to hit, so we fall through to LightRAG —
            // the diary likely has the event the user is asking about.
            let r = try await ServerClient.shared.lightragQuery(
                query: trimmed,
                responseLanguage: responseLanguage
            )
            return Result(intent: intent, summary: r.summary, sourceCount: r.source_count)
        case .unknown:
            // Best general-purpose endpoint is LightRAG hybrid.
            let r = try await ServerClient.shared.lightragQuery(
                query: trimmed,
                responseLanguage: responseLanguage
            )
            return Result(intent: intent, summary: r.summary, sourceCount: r.source_count)
        }
    }

    // MARK: - Intent classification

    private func classify(query: String) async -> EnrichmentIntent {
        #if canImport(FoundationModels)
        guard SystemLanguageModel.default.isAvailable else {
            return classifyHeuristic(query: query)
        }
        let session = LanguageModelSession(
            model: SystemLanguageModel.default,
            instructions: """
            Classify the user's enrichment request into exactly one of
            these labels: email_lookup, past_diary, calendar_detail,
            unknown. Output ONLY the label — no explanation, no
            punctuation. Pick `email_lookup` when the user asks about a
            received message or what someone wrote. Pick `past_diary`
            when the user asks about previous days, decisions, themes, or
            people history. Pick `calendar_detail` when the user asks for
            details of a specific meeting today. Pick `unknown` only if
            none clearly fits.
            """
        )
        do {
            let response = try await session.respond(to: "Request: \(query)")
            let raw = response.content
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            if let parsed = EnrichmentIntent(rawValue: raw) {
                return parsed
            }
            // Sometimes the model returns the label wrapped or with
            // quotes. Try a substring match.
            for candidate in [
                EnrichmentIntent.email_lookup,
                .past_diary,
                .calendar_detail,
                .unknown,
            ] where raw.contains(candidate.rawValue) {
                return candidate
            }
            return classifyHeuristic(query: query)
        } catch {
            Log.app.warning(
                "FoundationModels classification failed: \(String(describing: error), privacy: .public)"
            )
            return classifyHeuristic(query: query)
        }
        #else
        return classifyHeuristic(query: query)
        #endif
    }

    /// Fallback used when Apple FM isn't available or the call fails.
    /// Cheap keyword check; deliberately conservative — `.unknown` is
    /// fine and routes to LightRAG-hybrid which handles everything.
    private func classifyHeuristic(query: String) -> EnrichmentIntent {
        let q = query.lowercased()
        let emailHits = ["mail", "e-mail", "email", "geschrieben", "schickt", "wrote", "sent", "inbox"]
        let calendarHits = ["meeting", "termin", "treffen", "kalender", "calendar", "wann", "uhrzeit"]
        if emailHits.contains(where: { q.contains($0) }) { return .email_lookup }
        if calendarHits.contains(where: { q.contains($0) }) { return .calendar_detail }
        return .past_diary
    }
}
