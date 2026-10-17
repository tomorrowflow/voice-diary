import Foundation

// Pre-synthesises the walkthrough's next opener while the user is still
// reflecting on the current one, and owns the four caches behind that:
//
//   • `ready`      — synthesised scripts, keyed by segment ID
//   • `inFlight`   — synths that haven't finished yet
//   • `textCache`  — composed opener *text* (LLM-prepared, SPEC §11)
//   • `textTasks`  — in-flight text generations
//
// The hot win is Piper: synthesising a 60-character opener is ~400–800 ms
// of VITS work, and running it during the reflection silence leaves only
// AVAudioPlayer startup after "Weiter". Apple voices inherit a no-op
// `prefetch` and stay on the live `speak()` path.
//
// Semantics the coordinator relies on:
//   • Dedup — a second `prefetch` for a segment that is ready or in flight
//     is a no-op; concurrent `composedSpans` callers share one generation.
//   • Cache before clear — composed text lands in `textCache` before its
//     task is dropped, so a caller arriving in between finds one or the other.
//   • Consume once — `consume` hands a script to exactly one caller, awaiting
//     a half-finished synth so its head start isn't thrown away.
//   • Cancellation — `cancelAll` cancels in-flight work, deletes cached
//     audio and forgets everything; a cancelled run that finishes late is
//     discarded instead of resurrected, even if the segment was re-queued.

actor OpenerPrefetcher {
    typealias Prefetched = PrefetchedScript
    typealias SpanProvider = @Sendable () async -> [SpokenSpan]

    private struct InFlight {
        let token: Int
        let task: Task<Prefetched?, Never>
    }

    private let engineFor: @Sendable (String) -> any TTSEngine
    private var ready: [String: Prefetched] = [:]
    private var inFlight: [String: InFlight] = [:]
    private var textCache: [String: [SpokenSpan]] = [:]
    private var textTasks: [String: Task<[SpokenSpan], Never>] = [:]
    private var nextToken = 0
    /// Tokens whose result a `consume` call took over while the synth was
    /// still running; the completion handler must not discard those.
    private var claimed: Set<Int> = []

    init(engineFor: @escaping @Sendable (String) -> any TTSEngine = { VoiceRegistry.engine(for: $0) }) {
        self.engineFor = engineFor
    }

    // MARK: - Audio prefetch

    /// Start resolving and synthesising the opener for `segmentID`. No-op
    /// when a prefetch (in flight or completed) already exists. `spans` runs
    /// inside the background task, so it may await the LLM; same-language
    /// neighbours coalesce so the synth runs once per language bucket.
    func prefetch(segmentID: String, spans: @escaping SpanProvider) {
        guard ready[segmentID] == nil, inFlight[segmentID] == nil else { return }
        Diag.log("prefetchOpener: queued \(segmentID)")
        let token = nextToken
        nextToken += 1
        let engineFor = engineFor
        // `finish` runs inside the task, so anyone awaiting `task.value`
        // (`consume`, `waitUntilSettled`) resumes after the bookkeeping.
        let task = Task { [weak self] in
            let result = await Self.synthesize(
                segmentID: segmentID, spans: spans, engineFor: engineFor
            )
            await self?.finish(segmentID: segmentID, token: token, result: result)
            return result
        }
        inFlight[segmentID] = InFlight(token: token, task: task)
    }

    /// Resolve the prefetched script for `segmentID`, awaiting the in-flight
    /// synth if it hasn't completed yet. Removes the entry, so each script
    /// is delivered exactly once.
    func consume(segmentID: String) async -> Prefetched? {
        if let cached = ready.removeValue(forKey: segmentID) {
            return cached
        }
        guard let pending = inFlight.removeValue(forKey: segmentID) else { return nil }
        claimed.insert(pending.token)
        return await pending.task.value
    }

    /// Cancel in-flight work, delete cached audio and forget every cache —
    /// including the composed opener text, since a restarted session
    /// re-fetches the calendar and must regenerate openers from scratch.
    /// Safe to call repeatedly.
    func cancelAll() {
        for pending in inFlight.values { pending.task.cancel() }
        inFlight.removeAll()
        for script in ready.values { discard(script) }
        ready.removeAll()
        for task in textTasks.values { task.cancel() }
        textTasks.removeAll()
        textCache.removeAll()
    }

    /// Return once the prefetch for `segmentID` is no longer running. Does
    /// not consume it; used to hold back the second tier of prefetches so
    /// the first opener gets the CPU to itself.
    func waitUntilSettled(segmentID: String) async {
        if ready[segmentID] != nil { return }
        if let pending = inFlight[segmentID] {
            _ = await pending.task.value
        }
    }

    // MARK: - Opener text

    /// Composed opener text for `segmentID`, generated once and cached so
    /// the prefetch synth and the live record path use byte-identical text.
    /// Concurrent callers for the same segment await one `generate` call.
    func composedSpans(segmentID: String, generate: @escaping SpanProvider) async -> [SpokenSpan] {
        if let cached = textCache[segmentID] { return cached }
        if let task = textTasks[segmentID] { return await task.value }
        let task = Task { await generate() }
        textTasks[segmentID] = task
        let spans = await task.value
        // A `cancelAll` while generating dropped (or replaced) this task;
        // its result must not seed the cache of the restarted session.
        guard textTasks[segmentID] == task else { return spans }
        // Cache and drop the task in one non-suspending step, cache first,
        // so a caller arriving at any point finds either the task or the cache.
        textCache[segmentID] = spans
        textTasks.removeValue(forKey: segmentID)
        return spans
    }

    // MARK: - Internals

    private static func synthesize(
        segmentID: String,
        spans: SpanProvider,
        engineFor: @Sendable (String) -> any TTSEngine
    ) async -> Prefetched? {
        let coalesced = (await spans()).coalesced()
        if coalesced.isEmpty || Task.isCancelled { return nil }
        var utterances: [PrefetchedUtterance] = []
        for span in coalesced {
            if Task.isCancelled { break }
            let utterance = await engineFor(span.language)
                .prefetch(span.text, language: span.language)
            utterances.append(utterance)
        }
        let script = Prefetched(segmentID: segmentID, utterances: utterances)
        if Task.isCancelled {
            // Nobody will play this; don't leave its audio behind.
            for utterance in utterances { engineFor(utterance.language).discard(utterance) }
            return nil
        }
        return script
    }

    /// Stash a finished synth, unless the session was cancelled or restarted
    /// while it ran — then the slot is gone (or belongs to a newer task) and
    /// the result is discarded rather than resurrected.
    private func finish(segmentID: String, token: Int, result: Prefetched?) {
        if claimed.remove(token) != nil { return }
        guard inFlight[segmentID]?.token == token else {
            if let result { discard(result) }
            return
        }
        inFlight.removeValue(forKey: segmentID)
        if let result {
            ready[segmentID] = result
            Diag.log("prefetchOpener: ready \(segmentID)")
        } else {
            Diag.log("prefetchOpener: cancelled \(segmentID)")
        }
    }

    private func discard(_ script: Prefetched) {
        for utterance in script.utterances {
            engineFor(utterance.language).discard(utterance)
        }
    }
}
