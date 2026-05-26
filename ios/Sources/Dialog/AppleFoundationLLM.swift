import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

// `DialogLLM` backend that runs against Apple's on-device Foundation
// Models system model (iOS 26+). The default backend — always available
// on a supported device, fast, no setup. German output is the weak
// point: the model is ~3B distilled and English-first, so the resolver
// can route to `GemmaDialogLLM` (Gemma 4 E4B via MLX) when the user
// opts in and the weights are downloaded.
//
// All prompt assembly, language-guard, and speech sanitisation lives in
// `LLMHelpers` so this backend and the Gemma backend stay word-for-word
// equivalent on tone and validation.

public actor AppleFoundationLLM: DialogLLM {
    public static let shared = AppleFoundationLLM()

    public init() {}

    public var isAvailable: Bool {
        #if canImport(FoundationModels)
        return SystemLanguageModel.default.isAvailable
        #else
        return false
        #endif
    }

    // MARK: - Follow-ups

    public func generateFollowUp(
        eventTitle: String,
        attendees: [String],
        userTranscript: String,
        language: String
    ) async throws -> String {
        try await runShortGeneration(
            language: language,
            instructions: { LLMHelpers.followUpInstructions(german: $0) },
            prompt: { german in
                LLMHelpers.followUpPrompt(
                    eventTitle: eventTitle,
                    attendees: attendees,
                    userTranscript: userTranscript,
                    german: german
                )
            },
            maxTokens: 80
        )
    }

    public func generateGeneralFollowUp(
        sectionTitle: String,
        sectionIntro: String,
        userTranscript: String,
        language: String
    ) async throws -> String {
        try await runShortGeneration(
            language: language,
            instructions: { LLMHelpers.followUpInstructions(german: $0) },
            prompt: { german in
                LLMHelpers.generalFollowUpPrompt(
                    sectionTitle: sectionTitle,
                    sectionIntro: sectionIntro,
                    userTranscript: userTranscript,
                    german: german
                )
            },
            maxTokens: 80
        )
    }

    // MARK: - Opener (LLM-prepared, SPEC §11)

    public func generateEventOpener(
        context ctx: EventOpenerContext,
        language: String
    ) async throws -> String {
        try await runShortGeneration(
            language: language,
            instructions: { LLMHelpers.openerInstructions(german: $0) },
            prompt: { LLMHelpers.openerPrompt(ctx: ctx, german: $0) },
            maxTokens: 80,
            postProcess: { line in
                if LLMHelpers.containsDigitalClock(line) {
                    throw LLMError.unavailable("clock_time_leak")
                }
            }
        )
    }

    // MARK: - Note summary

    public func summarizeNote(
        transcript: String,
        language: String
    ) async throws -> String {
        try await runShortGeneration(
            language: language,
            instructions: { LLMHelpers.summaryInstructions(german: $0) },
            prompt: { LLMHelpers.summaryPrompt(transcript: transcript, german: $0) },
            maxTokens: 160
        )
    }

    // MARK: - Implicit todos

    public func extractImplicit(
        transcript: String,
        language: String
    ) async throws -> [ImplicitCandidate] {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 20 else { return [] }
        #if canImport(FoundationModels)
        guard SystemLanguageModel.default.isAvailable else {
            throw LLMError.unavailable("system_model_not_ready")
        }
        let isGerman = language.hasPrefix("de")
        let session = LanguageModelSession(
            model: SystemLanguageModel.default,
            instructions: LLMHelpers.implicitInstructions(german: isGerman)
        )
        let prompt = LLMHelpers.implicitPrompt(transcript: trimmed, german: isGerman)
        // 200 tokens covers a short bulleted list of implicit todos
        // without giving the model room to ramble into commentary.
        let options = GenerationOptions(maximumResponseTokens: 200)
        do {
            let response = try await session.respond(to: prompt, options: options)
            let raw = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            return LLMHelpers.parseImplicitList(raw, transcript: trimmed)
        } catch {
            throw LLMError.underlying(error)
        }
        #else
        throw LLMError.unavailable("FoundationModels_not_compiled_in")
        #endif
    }

    // MARK: - Shared short-generation pipeline
    //
    // Every public method except `extractImplicit` is "build prompt →
    // respond → language-check → clean → optional post-process". This
    // helper folds that into one place; per-method extras (the
    // digital-clock check for openers) plug in via `postProcess`.

    private func runShortGeneration(
        language: String,
        instructions buildInstructions: (Bool) -> String,
        prompt buildPrompt: (Bool) -> String,
        maxTokens: Int = 120,
        postProcess: ((String) throws -> Void)? = nil
    ) async throws -> String {
        #if canImport(FoundationModels)
        guard SystemLanguageModel.default.isAvailable else {
            throw LLMError.unavailable("system_model_not_ready")
        }
        let isGerman = language.hasPrefix("de")
        let session = LanguageModelSession(
            model: SystemLanguageModel.default,
            instructions: buildInstructions(isGerman)
        )
        // Cap response length so a runaway generation can't produce a
        // 585-char "opener" that then has to be TTS'd in full. Apple's
        // docs warn that strict caps can yield clipped output, but for
        // these prompts (1-2 sentence openers, single follow-up
        // questions) the worst case is acceptable and the upside is a
        // hard ceiling on per-call cost — memory, time, audio size.
        let options = GenerationOptions(maximumResponseTokens: maxTokens)
        do {
            let response = try await session.respond(
                to: buildPrompt(isGerman),
                options: options
            )
            let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { throw LLMError.empty }
            let cleaned = LLMHelpers.cleanForSpeech(text)
            try LLMHelpers.assertLanguage(cleaned, expectedGerman: isGerman)
            try postProcess?(cleaned)
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
}
