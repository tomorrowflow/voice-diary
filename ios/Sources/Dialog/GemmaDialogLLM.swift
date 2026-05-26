import Foundation

#if canImport(MLXLLM) && canImport(MLXLMCommon)
import MLXLLM
import MLXLMCommon
#endif
#if canImport(MLXHuggingFace) && canImport(HuggingFace) && canImport(Tokenizers)
import MLXHuggingFace
import HuggingFace
import Tokenizers
#endif

// `DialogLLM` backend that runs Gemma 4 E4B (4-bit) on-device via MLX
// Swift. CLAUDE.md calls this out as the documented escape hatch for
// when Apple FM's German capability runs out — see SPEC §11 + the memory
// note at `dialog-llm-german-ceiling-and-gemma-fallback`.
//
// Model: `mlx-community/gemma-4-e4b-it-4bit` (~2-5 GB on disk).
// Loading goes through `#huggingFaceLoadModelContainer` from the
// `MLXHuggingFace` package, which wraps `HuggingFace.HubClient` as a
// `Downloader` and `Tokenizers.AutoTokenizer` as a `TokenizerLoader`.
// First call downloads to the system HuggingFace cache; subsequent
// calls reuse the loaded `ModelContainer` for the lifetime of the
// actor. Settings → Mehr → Dialog-Modell exposes a "Modell laden"
// button so the user can pre-warm on Wi-Fi instead of waiting on the
// first opener.
//
// Build note: the `MLXHuggingFaceMacros` plugin requires trust on
// first build. In Xcode UI the user accepts once via the trust prompt;
// for `xcodebuild` builds pass `-skipMacroValidation`.
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
    ///
    /// `progressHandler` fires from MLX's downloader thread; callers
    /// that update SwiftUI state should hop to the MainActor inside
    /// the closure. The `Progress.fractionCompleted` is in [0, 1] (or
    /// NaN until the total is known).
    public func preload(
        progressHandler: (@Sendable (Progress) -> Void)? = nil
    ) async throws {
        _ = try await ensureLoaded(progressHandler: progressHandler)
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

    #if canImport(MLXLLM) && canImport(MLXLMCommon) && canImport(MLXHuggingFace) && canImport(HuggingFace) && canImport(Tokenizers)
    /// Returns a loaded `ModelContainer`, kicking off a download on the
    /// first call. Concurrent callers share one load task so we never
    /// double-download. Throws `.unavailable` on any load failure so the
    /// resolver falls through to Apple FM cleanly.
    ///
    /// The macro `#huggingFaceLoadModelContainer` expands to wrap
    /// `HuggingFace.HubClient` as a `MLXLMCommon.Downloader` and
    /// `Tokenizers.AutoTokenizer` as a `MLXLMCommon.TokenizerLoader`,
    /// then calls `loadModelContainer(from:using:configuration:)`.
    /// First call downloads ~5 GB of weights to the HuggingFace cache
    /// under `Library/Caches/huggingface/`; later calls reuse it.
    private func ensureLoaded(
        progressHandler: (@Sendable (Progress) -> Void)? = nil
    ) async throws -> ModelContainer {
        if let container { return container }
        if let task = loadTask {
            do { return try await task.value }
            catch { throw LLMError.unavailable("gemma_load_in_flight_failed") }
        }
        // Hand `progressHandler` to the task closure as a local let so
        // the @Sendable capture is explicit; the macro picks the
        // matching variant at compile time.
        let progress = progressHandler
        let task = Task<ModelContainer, Error> {
            let configuration = ModelConfiguration(id: Self.modelID)
            if let progress {
                return try await #huggingFaceLoadModelContainer(
                    configuration: configuration,
                    progressHandler: progress
                )
            } else {
                return try await #huggingFaceLoadModelContainer(
                    configuration: configuration
                )
            }
        }
        loadTask = task
        do {
            let loaded = try await task.value
            container = loaded
            loadTask = nil
            return loaded
        } catch {
            loadTask = nil
            throw LLMError.unavailable("gemma_load_failed: \(error)")
        }
    }
    #else
    /// MLX + HuggingFace deps not linked into this build — stub keeps
    /// the type protocol-conformant so `DialogLLMResolver` compiles.
    private func ensureLoaded(
        progressHandler: (@Sendable (Progress) -> Void)? = nil
    ) async throws -> Never {
        throw LLMError.unavailable("gemma_mlx_not_compiled_in")
    }
    #endif
}
