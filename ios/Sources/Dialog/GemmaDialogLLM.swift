import Foundation

#if canImport(MLXLLM) && canImport(MLXLMCommon)
import MLXLLM
import MLXLMCommon
#endif

// `DialogLLM` backend that runs Gemma 4 E4B (4-bit) on-device via MLX
// Swift. CLAUDE.md calls this out as the documented escape hatch for
// when Apple FM's German capability runs out — see SPEC §11 + the memory
// note at `dialog-llm-german-ceiling-and-gemma-fallback`.
//
// Model: `mlx-community/gemma-4-e4b-it-4bit` (~2-5 GB on disk).
// First call triggers download via MLX's HuggingFace cache;
// subsequent calls reuse the loaded `ModelContainer` for the lifetime
// of the actor.
//
// Memory: the loaded model stays resident. On a 12 GB iPhone 17 Pro
// with Parakeet + Piper + Voxtral fallback also in memory this is
// tight; the resolver therefore only routes here when the user
// explicitly opts in.
//
// Thread safety: `ChatSession` is documented as not thread-safe — but
// this actor serialises all access, and we build a fresh `ChatSession`
// per generation call so two interleaved methods never share state.

public actor GemmaDialogLLM: DialogLLM {
    public static let shared = GemmaDialogLLM()

    /// Canonical mlx-community 4-bit instruction-tuned weights. If the
    /// user later wants OptiQ / lmstudio-community variants this is the
    /// single string to swap.
    private static let modelID = "mlx-community/gemma-4-e4b-it-4bit"

    #if canImport(MLXLLM) && canImport(MLXLMCommon)
    private var container: ModelContainer?
    private var loadTask: Task<ModelContainer, Error>?
    #endif

    public init() {}

    public var isAvailable: Bool {
        #if canImport(MLXLLM) && canImport(MLXLMCommon)
        return container != nil
        #else
        return false
        #endif
    }

    /// Trigger model load explicitly so the resolver / Settings screen
    /// can warm the cache outside an opener critical path. Safe to call
    /// repeatedly — concurrent calls share one load task.
    public func preload() async throws {
        _ = try await ensureLoaded()
    }

    // MARK: - DialogLLM

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
            }
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
            }
        )
    }

    public func generateEventOpener(
        context ctx: EventOpenerContext,
        language: String
    ) async throws -> String {
        try await runShortGeneration(
            language: language,
            instructions: { LLMHelpers.openerInstructions(german: $0) },
            prompt: { LLMHelpers.openerPrompt(ctx: ctx, german: $0) },
            postProcess: { line in
                if LLMHelpers.containsDigitalClock(line) {
                    throw LLMError.unavailable("clock_time_leak")
                }
            }
        )
    }

    public func summarizeNote(
        transcript: String,
        language: String
    ) async throws -> String {
        try await runShortGeneration(
            language: language,
            instructions: { LLMHelpers.summaryInstructions(german: $0) },
            prompt: { LLMHelpers.summaryPrompt(transcript: transcript, german: $0) }
        )
    }

    public func extractImplicit(
        transcript: String,
        language: String
    ) async throws -> [ImplicitCandidate] {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 20 else { return [] }
        #if canImport(MLXLLM) && canImport(MLXLMCommon)
        let model = try await ensureLoaded()
        let isGerman = language.hasPrefix("de")
        let session = ChatSession(
            model,
            instructions: LLMHelpers.implicitInstructions(german: isGerman)
        )
        do {
            let response = try await session.respond(
                to: LLMHelpers.implicitPrompt(transcript: trimmed, german: isGerman)
            )
            let raw = response.trimmingCharacters(in: .whitespacesAndNewlines)
            return LLMHelpers.parseImplicitList(raw, transcript: trimmed)
        } catch {
            throw LLMError.underlying(error)
        }
        #else
        throw LLMError.unavailable("MLX_not_compiled_in")
        #endif
    }

    // MARK: - Shared short-generation pipeline (mirrors AppleFoundationLLM)

    private func runShortGeneration(
        language: String,
        instructions buildInstructions: (Bool) -> String,
        prompt buildPrompt: (Bool) -> String,
        postProcess: ((String) throws -> Void)? = nil
    ) async throws -> String {
        #if canImport(MLXLLM) && canImport(MLXLMCommon)
        let model = try await ensureLoaded()
        let isGerman = language.hasPrefix("de")
        let session = ChatSession(
            model,
            instructions: buildInstructions(isGerman)
        )
        do {
            let response = try await session.respond(to: buildPrompt(isGerman))
            let text = response.trimmingCharacters(in: .whitespacesAndNewlines)
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
        throw LLMError.unavailable("MLX_not_compiled_in")
        #endif
    }

    // MARK: - Model loading

    #if canImport(MLXLLM) && canImport(MLXLMCommon)
    /// Returns a loaded `ModelContainer`, kicking off a download on the
    /// first call. Concurrent callers share one load task so we never
    /// double-download. Throws `.unavailable` on any load failure so the
    /// resolver falls through to Apple FM cleanly.
    ///
    /// TODO (follow-up commit): wire the real loader. `mlx-swift-lm`'s
    /// `loadModelContainer(from:using:configuration:)` needs concrete
    /// `Downloader` + `TokenizerLoader` instances. The canonical path is
    /// the `#huggingFaceLoadModelContainer` macro from `MLXHuggingFace`,
    /// which requires adding three more SwiftPM packages:
    ///   - `MLXHuggingFace` (product, already in mlx-swift-lm)
    ///   - `https://github.com/huggingface/swift-huggingface` (HubClient)
    ///   - `https://github.com/huggingface/swift-transformers` (Tokenizers)
    /// …plus accepting the package macros' trust prompt on first build.
    /// Doing it here would have ballooned this PR — splitting it out
    /// keeps the abstraction landable and reviewable on its own. Until
    /// then this stub throws `.unavailable`, so `ChainDialogLLM` simply
    /// falls back to Apple FM and the walkthrough keeps working.
    private func ensureLoaded() async throws -> ModelContainer {
        if let container { return container }
        throw LLMError.unavailable("gemma_loader_not_yet_wired")
    }
    #endif
}
