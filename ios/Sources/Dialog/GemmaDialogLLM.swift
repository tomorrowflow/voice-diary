import Foundation

#if canImport(MLXLLM) && canImport(MLXLMCommon)
import MLXLLM
import MLXLMCommon
#endif
#if canImport(MLX)
import MLX
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

    /// True while the app is backgrounded. Set by `suspend()` /
    /// `resume()` from the scenePhase hook. When suspended, `ensureLoaded`
    /// refuses to start a new load — letting the `ChainDialogLLM`
    /// fall back to Apple Foundation Models instead of trying to lift
    /// 5 GB of MLX weights past the much-tighter background memory
    /// ceiling (which would either OOM-kill us or fail in MLX's
    /// background-restricted Metal context).
    private var loadingSuspended: Bool = false

    /// Fan-out for HuggingFace download progress. The MLX downloader
    /// hands us one progress closure; the broadcaster lets multiple
    /// subscribers latch onto the same in-flight load and immediately
    /// catch up to the latest snapshot when they register. Critical
    /// for the case where the Settings view is dismantled mid-download
    /// (user navigates away and comes back) — without this the second
    /// view instance saw nothing until the load completed.
    private nonisolated let downloadBroadcaster = GemmaDownloadProgressBroadcaster()

    public init() {}

    public var isAvailable: Bool {
        #if canImport(MLXLLM) && canImport(MLXLMCommon)
        return container != nil
        #else
        return false
        #endif
    }

    /// True if a load is currently in flight (i.e. an earlier
    /// `preload()` or generator call is mid-download or mid-load).
    /// Reading from the SwiftUI Settings view lets it detect that the
    /// model is loading even though *this* instance of the view never
    /// initiated the load — typical when the user pops back to
    /// Dialog-Modell mid-download.
    public var isLoading: Bool {
        #if canImport(MLXLLM) && canImport(MLXLMCommon)
        return loadTask != nil
        #else
        return false
        #endif
    }

    /// Trigger model load explicitly so the resolver / Settings screen
    /// can warm the cache outside an opener critical path. Safe to call
    /// repeatedly — concurrent calls share one load task. A late caller
    /// that arrives while a load is already in flight gets its
    /// `progressHandler` wired into the broadcaster so it receives
    /// every subsequent tick — *and* an immediate replay of the last
    /// known progress so the UI bar doesn't briefly snap to zero
    /// before the next 100 ms HubClient sampling tick lands.
    ///
    /// `progressHandler` fires from MLX's downloader thread; callers
    /// that update SwiftUI state should hop to the MainActor inside
    /// the closure. The `Progress.fractionCompleted` is in [0, 1] (or
    /// NaN until the total is known).
    public func preload(
        progressHandler: (@Sendable (Progress) -> Void)? = nil
    ) async throws {
        let listenerID = UUID()
        if let progressHandler {
            downloadBroadcaster.register(listenerID, progressHandler)
        }
        defer {
            if progressHandler != nil {
                downloadBroadcaster.unregister(listenerID)
            }
        }
        _ = try await ensureLoaded { [broadcaster = downloadBroadcaster] p in
            broadcaster.broadcast(p)
        }
    }

    /// Release the resident model so iOS can reclaim ~5 GB. Called from
    /// scenePhase `.background` because iOS background memory limits
    /// are far tighter than the increased-memory-limit foreground cap
    /// — without this the app gets jetsam'd a few minutes after going
    /// dark. The next opener triggers a re-load from the on-disk
    /// HuggingFace cache (no network), which takes ~10-30 s on iPhone
    /// 17 Pro depending on storage IO.
    ///
    /// Dropping the `ModelContainer` reference is necessary but not
    /// sufficient — MLX keeps recycled Metal buffers in a pool that
    /// can hold multiple GB even after every `MLXArray` is released
    /// (see MLX-Swift `running-on-ios.md`). `MLX.Memory.clearCache()`
    /// is the call that actually returns those buffers to the system.
    ///
    /// In-flight loads are left alone deliberately: backgrounding
    /// during a fresh download isn't user-initiated cancellation, and
    /// `URLSession` already pauses itself when the app suspends.
    public func unload() {
        #if canImport(MLXLLM) && canImport(MLXLMCommon)
        guard container != nil else { return }
        container = nil
        #if canImport(MLX)
        MLX.Memory.clearCache()
        #endif
        Diag.log("Gemma: unloaded")
        #endif
    }

    /// Mark the loader as backgrounded: drop the resident weights so
    /// the OS doesn't jetsam us, and refuse any new load attempt until
    /// `resume()` is called. While suspended, calls to the generator
    /// methods throw `LLMError.unavailable`, which `ChainDialogLLM`
    /// catches and routes to its Apple FM fallback. This is what keeps
    /// the walkthrough functional when the user pockets the phone:
    /// recording continues in background-audio mode, the next opener
    /// still gets generated (by Apple FM, locally), and we never
    /// attempt the catastrophic re-load of 5 GB of MLX weights inside
    /// a backgrounded process.
    public func suspend() {
        loadingSuspended = true
        unload()
        Diag.log("Gemma: suspended (background)")
    }

    /// Re-enable loading. Does not eagerly re-load — the next opener
    /// or the user-tapped "Modell laden" button does that. Reload
    /// from the on-disk HuggingFace cache takes ~10-30 s and only
    /// happens once per foreground stretch.
    public func resume() {
        guard loadingSuspended else { return }
        loadingSuspended = false
        Diag.log("Gemma: resumed (foreground)")
    }

    /// Cancel an in-flight load and clear the broadcaster's replay
    /// state. Called by the Dialog-Modell view's "Stalled — tap to
    /// retry" button: without this, a retry just re-awaits the same
    /// stalled `Task<ModelContainer, Error>` (because `ensureLoaded`
    /// short-circuits when `loadTask != nil`) and the UI's "32.4 MB"
    /// bar position never moves because the broadcaster keeps
    /// replaying the same snapshot.
    ///
    /// Already-downloaded chunks survive because they live in
    /// HuggingFace's on-disk `HubCache`, not in the in-process task.
    public func cancelLoad() {
        #if canImport(MLXLLM) && canImport(MLXLMCommon)
        if let task = loadTask {
            task.cancel()
            loadTask = nil
            Diag.log("Gemma: load cancelled")
        }
        downloadBroadcaster.reset()
        #endif
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
        maxTokens: Int = 120,
        postProcess: ((String) throws -> Void)? = nil
    ) async throws -> String {
        #if canImport(MLXLLM) && canImport(MLXLMCommon)
        let model = try await ensureLoaded()
        let isGerman = language.hasPrefix("de")
        // Mirror AppleFoundationLLM: cap the response length so we
        // can't generate a 500-char opener that explodes memory + TTS
        // time. `GenerateParameters` is the MLX-side equivalent of
        // Apple's `GenerationOptions.maximumResponseTokens`.
        let parameters = GenerateParameters(maxTokens: maxTokens)
        let session = ChatSession(
            model,
            instructions: buildInstructions(isGerman),
            generateParameters: parameters
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
        // Refuse to start a new load while backgrounded. Loading 5 GB
        // of MLX weights inside a backgrounded iOS process is one of
        // (a) jetsam-killed by the much tighter background memory cap
        // (b) outright failed because Metal access is restricted for
        // backgrounded apps. Throwing `.unavailable` here lets
        // `ChainDialogLLM` transparently route the call to Apple FM,
        // which is system-managed and works fine in background.
        if loadingSuspended {
            throw LLMError.unavailable("gemma_backgrounded")
        }
        if let task = loadTask {
            do { return try await task.value }
            catch { throw LLMError.unavailable("gemma_load_in_flight_failed") }
        }
        // Wrap the caller's progress handler so we can also emit a
        // single "totals known" diagnostic the moment the repo's file
        // list resolves. The initial `HubClient.listFiles` phase fires
        // no progress callbacks at all, so without this the developer
        // console looks identical between "still listing" and "hung".
        let userHandler = progressHandler
        let firstTotalLogger = GemmaFirstTotalLogger()
        let progress: @Sendable (Progress) -> Void = { p in
            firstTotalLogger.logIfFirst(p)
            userHandler?(p)
        }
        // Cap MLX's Metal buffer pool. Per MLX-Swift's iOS guide, the
        // pool defaults to `recommendedMaxWorkingSetSize` (multiple GB
        // on iPhone 17 Pro), and intermediate-buffer accumulation
        // during an LLM inference run can push it well past what
        // jetsam tolerates — particularly once the app moves to the
        // background. 32 MB matches Apple's own LLM examples and is a
        // negligible perf cost vs. the OOM risk.
        #if canImport(MLX)
        MLX.Memory.cacheLimit = 32 * 1024 * 1024
        #endif
        Diag.log("Gemma: starting load of \(Self.modelID)")
        let task = Task<ModelContainer, Error> {
            let configuration = ModelConfiguration(id: Self.modelID)
            return try await Self.loadWithRetry(
                configuration: configuration,
                progress: progress
            )
        }
        loadTask = task
        do {
            let loaded = try await task.value
            container = loaded
            loadTask = nil
            Diag.log("Gemma: load complete")
            return loaded
        } catch {
            loadTask = nil
            Diag.log("Gemma: load failed: \(error)")
            throw LLMError.unavailable("gemma_load_failed: \(error)")
        }
    }

    /// Auto-retry wrapper for the HuggingFace load.
    ///
    /// Two real-world failure modes drove this design:
    ///
    ///   * **`NSURLErrorNetworkConnectionLost` (-1005)** when iOS suspends
    ///     us out from under an in-flight `session.data(for:)` /
    ///     `session.bytes(for:)`. Mitigation: retry with a fresh session;
    ///     HuggingFace's on-disk `HubCache` keeps completed files so
    ///     each retry resumes at the next file boundary.
    ///
    ///   * **Foreground deterministic stall at exactly 32.4 MB** —
    ///     reproduces consistently on `mlx-community/gemma-4-e4b-it-4bit`
    ///     even with the screen awake. The 32.4 MB matches the
    ///     cumulative size of every file in the repo *except*
    ///     `model.safetensors`. So all small files complete fine, then
    ///     the lone 5.2 GB safetensors download starts and never
    ///     reports a single byte to its `URLSessionDownloadDelegate`.
    ///     Apple's WWDC23 talk on resumable transfers documents this
    ///     as a known weakness of `URLSession.download(for:delegate:)`
    ///     for very large foreground transfers, especially with
    ///     concurrent connections to the same host. Mitigation in
    ///     `TunedHubDownloader` below: serialise file downloads
    ///     (`maxConcurrent: 1`) so the safetensors gets the entire
    ///     network pipe, and use an ephemeral session so iOS's
    ///     `URLCache` can't interfere with multi-GB transfers.
    ///
    /// We can't switch to a `URLSessionConfiguration.background(...)`
    /// because HuggingFace's library uses the async sequence API which
    /// isn't supported on background sessions. Forking the library is
    /// the only path to true background downloads; not done.
    ///
    /// The retry budget is intentionally generous (8 attempts, 3 s
    /// backoff between each) because each retry typically only makes
    /// it past one file before the user backgrounds again. Total
    /// wall-clock cap: ~24 s of sleep on top of however long the
    /// downloads themselves take.
    private static func loadWithRetry(
        configuration: ModelConfiguration,
        progress: @escaping @Sendable (Progress) -> Void,
        maxAttempts: Int = 8
    ) async throws -> ModelContainer {
        var attempt = 0
        var lastError: (any Error)?
        while attempt < maxAttempts {
            attempt += 1
            let session = Self.makeTunedSession()
            let hub = HuggingFace.HubClient(session: session)
            let downloader = TunedHubDownloader(client: hub)
            do {
                Diag.log("Gemma download: attempt \(attempt)/\(maxAttempts) starting")
                return try await loadModelContainer(
                    from: downloader,
                    using: #huggingFaceTokenizerLoader(),
                    configuration: configuration,
                    progressHandler: progress
                )
            } catch {
                lastError = error
                session.invalidateAndCancel()
                guard Self.isTransient(error), attempt < maxAttempts else {
                    throw error
                }
                let code = (error as NSError).code
                Diag.log(
                    "Gemma download: transient error code=\(code) attempt=\(attempt)/\(maxAttempts), retrying in 3s"
                )
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if Task.isCancelled { throw CancellationError() }
            }
        }
        throw lastError ?? LLMError.unavailable("gemma_retry_exhausted")
    }

    /// Build the URLSession we hand to `HubClient`. Ephemeral so iOS's
    /// shared `URLCache` is bypassed entirely — that cache has been
    /// observed to mis-handle the multi-GB safetensors transfer (it
    /// thinks the response is cacheable, buffers in the cache layer
    /// instead of streaming to disk, and the download delegate sees
    /// no progress). Connection limits and timeouts tuned for one
    /// huge file rather than many small ones.
    private static func makeTunedSession() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.waitsForConnectivity = true
        cfg.timeoutIntervalForResource = 7200   // 2 h ceiling on total transfer
        cfg.timeoutIntervalForRequest = 180     // 3 min per-request idle timeout
        cfg.httpMaximumConnectionsPerHost = 2   // model.safetensors is one file; 2 leaves room for the metadata HEAD
        cfg.httpShouldUsePipelining = false
        cfg.allowsCellularAccess = true
        cfg.allowsExpensiveNetworkAccess = true
        cfg.allowsConstrainedNetworkAccess = true
        cfg.networkServiceType = .responsiveData
        // No URLCache. Ephemeral already has nil, but be explicit.
        cfg.urlCache = nil
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: cfg)
    }

    /// Recognised transient network errors that warrant an auto-retry.
    /// Anything else (HTTP 4xx, decode failures, missing tokenizer
    /// files, etc.) bubbles up so the resolver falls through to
    /// Apple FM with a real diagnosis.
    private static func isTransient(_ error: any Error) -> Bool {
        let ns = error as NSError
        guard ns.domain == NSURLErrorDomain else { return false }
        switch ns.code {
        case NSURLErrorNetworkConnectionLost,        // -1005, app suspended
             NSURLErrorNotConnectedToInternet,        // -1009
             NSURLErrorTimedOut,                      // -1001
             NSURLErrorCannotConnectToHost,           // -1004
             NSURLErrorCannotFindHost,                // -1003
             NSURLErrorDNSLookupFailed,               // -1006
             NSURLErrorBackgroundSessionWasDisconnected,  // -997
             NSURLErrorBackgroundSessionInUseByAnotherProcess,  // -996
             NSURLErrorBackgroundSessionRequiresSharedContainer,  // -995
             NSURLErrorDataNotAllowed:                // -1020 (cellular off)
            return true
        default:
            return false
        }
    }

    /// Drop-in replacement for `#hubDownloader(hub)` that lets us
    /// override the per-snapshot concurrency. The macro hard-codes the
    /// default `maxConcurrentDownloads = 8`, which is the wrong value
    /// for a repo whose total size is dominated by a single 5.2 GB
    /// `model.safetensors`. Serial downloads give that one file the
    /// entire network pipe + connection pool, which empirically fixes
    /// the foreground stall.
    private struct TunedHubDownloader: MLXLMCommon.Downloader {
        let client: HuggingFace.HubClient

        func download(
            id: String,
            revision: String?,
            matching patterns: [String],
            useLatest _: Bool,
            progressHandler: @Sendable @escaping (Foundation.Progress) -> Void
        ) async throws -> URL {
            guard let repoID = HuggingFace.Repo.ID(rawValue: id) else {
                throw HuggingFaceDownloaderError.invalidRepositoryID(id)
            }
            // Wrap the caller's progress handler to add per-50-MB +
            // every-30-s Diag lines so the next stall lands a clean
            // breadcrumb in the Diagnostics view (instead of just the
            // watchdog blasting one line at 60 s with no context).
            let logger = ProgressLogger()
            let combined: @Sendable @MainActor (Foundation.Progress) -> Void = { p in
                logger.log(p)
                progressHandler(p)
            }
            return try await client.downloadSnapshot(
                of: repoID,
                revision: revision ?? "main",
                matching: patterns,
                // Serial: see the comment above the struct. The MLX
                // snapshot is one huge weight file plus a handful of
                // small JSONs; the small ones download in milliseconds
                // either way, so we trade ~negligible wall-clock for
                // the foreground stall fix.
                maxConcurrentDownloads: 1,
                progressHandler: combined
            )
        }
    }

    /// Emit a Diag entry every 50 MB *or* every 30 s — whichever fires
    /// first. Provides a clear progress trace in the Diagnostics view
    /// when the user hits another stall, so we can see whether the
    /// download is moving slowly, has hit a specific byte boundary,
    /// or has gone silent on a particular file.
    private final class ProgressLogger: @unchecked Sendable {
        private let lock = NSLock()
        private var lastLoggedBytes: Int64 = 0
        private var lastLoggedAt: Date = .distantPast
        private static let byteStep: Int64 = 50 * 1024 * 1024
        private static let timeStep: TimeInterval = 30

        func log(_ p: Foundation.Progress) {
            let now = Date()
            let completed = p.completedUnitCount
            let total = p.totalUnitCount
            lock.lock()
            let bytesAdvanced = completed - lastLoggedBytes >= Self.byteStep
            let timeAdvanced = now.timeIntervalSince(lastLoggedAt) >= Self.timeStep
            let shouldLog = bytesAdvanced || timeAdvanced
            if shouldLog {
                lastLoggedBytes = completed
                lastLoggedAt = now
            }
            lock.unlock()
            guard shouldLog else { return }
            let mb = Double(completed) / (1024 * 1024)
            let totalMB = Double(total) / (1024 * 1024)
            Diag.log(String(format: "Gemma progress: %.1f / %.1f MB", mb, totalMB))
        }
    }

    /// One-shot diagnostic for the first progress callback that has a
    /// known `totalUnitCount` — i.e. the moment HuggingFace finishes
    /// listing files and the parent `Progress` knows what's coming.
    /// Class + lock because the @Sendable handler is called from the
    /// HubClient's downloader thread, not the loading actor.
    private final class GemmaFirstTotalLogger: @unchecked Sendable {
        private let lock = NSLock()
        private var didLog = false

        func logIfFirst(_ progress: Progress) {
            let total = progress.totalUnitCount
            guard total > 1 else { return }
            lock.lock()
            let firing = !didLog
            if firing { didLog = true }
            lock.unlock()
            guard firing else { return }
            Diag.log("Gemma: file list resolved, \(total) bytes to download")
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
/// Fan-out for the single MLX download progress callback into a list of
/// SwiftUI subscribers. Lives outside the `GemmaDialogLLM` actor so the
/// downloader-thread callback can call `broadcast(_:)` without an actor
/// hop. Internal NSLock keeps the listener map thread-safe.
///
/// `register(_:_:)` immediately replays the last known progress to a
/// newly-attached listener — this is the bit that makes a re-opened
/// Dialog-Modell view show the correct bar position instead of zero
/// until the next HubClient sampling tick (~100 ms, but functionally
/// invisible because the next tick may not change the byte count
/// meaningfully).
private final class GemmaDownloadProgressBroadcaster: @unchecked Sendable {
    private let lock = NSLock()
    private var listeners: [UUID: @Sendable (Progress) -> Void] = [:]
    private var lastCompletedBytes: Int64 = 0
    private var lastTotalBytes: Int64 = 0

    func register(
        _ id: UUID,
        _ handler: @Sendable @escaping (Progress) -> Void
    ) {
        lock.lock()
        listeners[id] = handler
        let completed = lastCompletedBytes
        let total = lastTotalBytes
        lock.unlock()
        // Replay the last known progress so the new listener catches
        // up to the current bar position. Skip when total is 0 (the
        // pre-listing phase) because there's nothing to display yet.
        if total > 0 {
            let snapshot = Progress(totalUnitCount: total)
            snapshot.completedUnitCount = completed
            handler(snapshot)
        }
    }

    func unregister(_ id: UUID) {
        lock.lock()
        _ = listeners.removeValue(forKey: id)
        lock.unlock()
    }

    func broadcast(_ progress: Progress) {
        let completed = progress.completedUnitCount
        let total = progress.totalUnitCount
        lock.lock()
        if total > 0 {
            lastCompletedBytes = completed
            lastTotalBytes = total
        }
        let handlers = Array(listeners.values)
        lock.unlock()
        for handler in handlers {
            handler(progress)
        }
    }

    /// Clear the replay snapshot so a fresh load doesn't immediately
    /// snap the UI back to the previous bar position. Called by
    /// `GemmaDialogLLM.cancelLoad()` when the user retries a stalled
    /// download.
    func reset() {
        lock.lock()
        lastCompletedBytes = 0
        lastTotalBytes = 0
        lock.unlock()
    }
}

