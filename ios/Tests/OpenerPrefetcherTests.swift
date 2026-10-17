import Foundation
import Testing
@testable import VoiceDiary

@Suite("OpenerPrefetcher")
struct OpenerPrefetcherTests {

    // MARK: - Dedup

    @Test("concurrent prefetch for one in-flight segment resolves the spans and synthesises once")
    func concurrentPrefetchDedup() async {
        let engine = FakeEngine()
        let counter = Counter()
        let gate = Gate()
        let prefetcher = OpenerPrefetcher(engineFor: { _ in engine })
        let provider: OpenerPrefetcher.SpanProvider = {
            await counter.increment()
            await gate.wait()
            return [SpokenSpan(text: "Hallo", language: "de")]
        }

        // The gate keeps the first prefetch in flight, so the later calls
        // can only be deduplicated by the in-flight check.
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask { await prefetcher.prefetch(segmentID: "s01", spans: provider) }
            }
        }
        await gate.open()
        let script = await prefetcher.consume(segmentID: "s01")

        #expect(await counter.value == 1)
        #expect(engine.prefetchedTexts == ["Hallo"])
        #expect(script?.utterances.map(\.text) == ["Hallo"])
    }

    @Test("prefetch for an already-ready segment is a no-op")
    func prefetchReadyIsNoOp() async {
        let engine = FakeEngine()
        let counter = Counter()
        let prefetcher = OpenerPrefetcher(engineFor: { _ in engine })
        let provider: OpenerPrefetcher.SpanProvider = {
            await counter.increment()
            return [SpokenSpan(text: "Hallo", language: "de")]
        }
        await prefetcher.prefetch(segmentID: "s01", spans: provider)
        await prefetcher.waitUntilSettled(segmentID: "s01")

        await prefetcher.prefetch(segmentID: "s01", spans: provider)
        let script = await prefetcher.consume(segmentID: "s01")

        #expect(await counter.value == 1)
        #expect(engine.prefetchedTexts == ["Hallo"])
        #expect(script?.utterances.map(\.text) == ["Hallo"])
    }

    @Test("prefetch coalesces same-language neighbours into one synth per bucket")
    func prefetchCoalescesSpans() async {
        let engine = FakeEngine()
        let prefetcher = OpenerPrefetcher(engineFor: { _ in engine })
        await prefetcher.prefetch(segmentID: "s01") {
            [
                SpokenSpan(text: "Guten", language: "de"),
                SpokenSpan(text: "Abend", language: "de"),
                SpokenSpan(text: "Standup", language: "en")
            ]
        }
        let script = await prefetcher.consume(segmentID: "s01")

        #expect(script?.utterances.map(\.text) == ["Guten Abend", "Standup"])
        #expect(script?.utterances.map(\.language) == ["de", "en"])
    }

    @Test("an empty span list prefetches nothing")
    func emptySpansYieldNothing() async {
        let engine = FakeEngine()
        let prefetcher = OpenerPrefetcher(engineFor: { _ in engine })
        await prefetcher.prefetch(segmentID: "s01") { [] }

        #expect(await prefetcher.consume(segmentID: "s01") == nil)
        #expect(engine.prefetchedTexts.isEmpty)
    }

    @Test("concurrent composedSpans callers share one generation")
    func concurrentComposeDedup() async {
        let counter = Counter()
        let gate = Gate()
        let prefetcher = OpenerPrefetcher(engineFor: { _ in FakeEngine() })
        let generate: OpenerPrefetcher.SpanProvider = {
            await counter.increment()
            await gate.wait()
            return [SpokenSpan(text: "Opener", language: "de")]
        }

        // The first caller parks at the gate; the others join while it is
        // still generating, and a late caller arrives after it settled.
        async let first = prefetcher.composedSpans(segmentID: "e01", generate: generate)
        await gate.waitForWaiter()
        async let second = prefetcher.composedSpans(segmentID: "e01", generate: generate)
        async let third = prefetcher.composedSpans(segmentID: "e01", generate: generate)
        for _ in 0..<20 { await Task.yield() }
        await gate.open()
        let results = await [first, second, third]
        let late = await prefetcher.composedSpans(segmentID: "e01", generate: generate)

        #expect(await counter.value == 1)
        #expect((results + [late]).allSatisfy { $0 == [SpokenSpan(text: "Opener", language: "de")] })
    }

    // MARK: - Cache before clear

    // On an actor the "cache, then drop the task" step cannot be split, so
    // the observable contract is: whenever a caller arrives, it gets the
    // text and never triggers a second generation.
    @Test("composed text is available to callers arriving at any point")
    func composeServesCallersAtAnyPoint() async {
        let counter = Counter()
        let prefetcher = OpenerPrefetcher(engineFor: { _ in FakeEngine() })
        let generate: OpenerPrefetcher.SpanProvider = {
            await counter.increment()
            return [SpokenSpan(text: "Opener", language: "de")]
        }

        let results = await withTaskGroup(of: [SpokenSpan].self) { group in
            for _ in 0..<50 {
                group.addTask { await prefetcher.composedSpans(segmentID: "e01", generate: generate) }
            }
            var all: [[SpokenSpan]] = []
            for await spans in group { all.append(spans) }
            return all
        }
        let late = await prefetcher.composedSpans(segmentID: "e01", generate: generate)

        #expect(await counter.value == 1)
        #expect(results.count == 50)
        #expect(results.allSatisfy { $0 == late })
    }

    @Test("a generation cancelled by cancelAll does not repopulate the text cache")
    func cancelledComposeDoesNotPoisonCache() async {
        let counter = Counter()
        let gate = Gate()
        let prefetcher = OpenerPrefetcher(engineFor: { _ in FakeEngine() })
        let stale: OpenerPrefetcher.SpanProvider = {
            await gate.wait()
            return [SpokenSpan(text: "stale", language: "de")]
        }
        let fresh: OpenerPrefetcher.SpanProvider = {
            await counter.increment()
            return [SpokenSpan(text: "fresh", language: "de")]
        }

        async let staleResult = prefetcher.composedSpans(segmentID: "e01", generate: stale)
        await gate.waitForWaiter()
        await prefetcher.cancelAll()
        await gate.open()
        _ = await staleResult
        let restarted = await prefetcher.composedSpans(segmentID: "e01", generate: fresh)

        #expect(restarted == [SpokenSpan(text: "fresh", language: "de")])
        #expect(await counter.value == 1)
    }

    // MARK: - Consume once

    @Test("a completed prefetch is consumed exactly once")
    func consumeOnce() async {
        let engine = FakeEngine()
        let prefetcher = OpenerPrefetcher(engineFor: { _ in engine })
        await prefetcher.prefetch(segmentID: "s01") { [SpokenSpan(text: "Hallo", language: "de")] }
        await prefetcher.waitUntilSettled(segmentID: "s01")

        let first = await prefetcher.consume(segmentID: "s01")
        let second = await prefetcher.consume(segmentID: "s01")

        #expect(first?.segmentID == "s01")
        #expect(second == nil)
        #expect(engine.discardedTexts.isEmpty)
    }

    @Test("consume awaits an in-flight prefetch and delivers it without discarding it")
    func consumeAwaitsInFlight() async {
        let engine = FakeEngine()
        let gate = Gate()
        let prefetcher = OpenerPrefetcher(engineFor: { _ in engine })
        await prefetcher.prefetch(segmentID: "s01") {
            await gate.wait()
            return [SpokenSpan(text: "Hallo", language: "de")]
        }

        async let consumed = prefetcher.consume(segmentID: "s01")
        await gate.waitForWaiter()
        await gate.open()
        let script = await consumed
        await prefetcher.waitUntilSettled(segmentID: "s01")

        #expect(script?.utterances.map(\.text) == ["Hallo"])
        #expect(engine.discardedTexts.isEmpty)
        #expect(await prefetcher.consume(segmentID: "s01") == nil)
    }

    @Test("consume of an unknown segment is nil")
    func consumeUnknown() async {
        let prefetcher = OpenerPrefetcher(engineFor: { _ in FakeEngine() })
        #expect(await prefetcher.consume(segmentID: "nope") == nil)
    }

    // MARK: - Cancel / restart

    @Test("cancelAll discards ready scripts and forgets them")
    func cancelAllDiscardsReady() async {
        let engine = FakeEngine()
        let prefetcher = OpenerPrefetcher(engineFor: { _ in engine })
        await prefetcher.prefetch(segmentID: "s01") { [SpokenSpan(text: "Hallo", language: "de")] }
        await prefetcher.waitUntilSettled(segmentID: "s01")

        await prefetcher.cancelAll()

        #expect(engine.discardedTexts == ["Hallo"])
        #expect(await prefetcher.consume(segmentID: "s01") == nil)
        await prefetcher.cancelAll()
        #expect(engine.discardedTexts == ["Hallo"])
    }

    @Test("a prefetch cancelled mid-flight never resurrects, and a restart gets fresh work")
    func cancelThenRestart() async {
        let engine = FakeEngine()
        let gate = Gate()
        let prefetcher = OpenerPrefetcher(engineFor: { _ in engine })
        await prefetcher.prefetch(segmentID: "s01") {
            await gate.wait()
            return [SpokenSpan(text: "alt", language: "de")]
        }
        await gate.waitForWaiter()

        await prefetcher.cancelAll()
        await prefetcher.prefetch(segmentID: "s01") { [SpokenSpan(text: "neu", language: "de")] }
        await gate.open()

        let script = await prefetcher.consume(segmentID: "s01")
        #expect(script?.utterances.map(\.text) == ["neu"])
        // The cancelled run finishes late; nothing of it may surface.
        for _ in 0..<20 { await Task.yield() }
        #expect(await prefetcher.consume(segmentID: "s01") == nil)
        #expect(!engine.prefetchedTexts.contains("alt"))
    }

    @Test("a synth cancelled mid-way discards the utterances it already produced")
    func cancelMidSynthDiscardsPartial() async {
        let gate = Gate()
        let engine = FakeEngine(prefetchGate: gate)
        let prefetcher = OpenerPrefetcher(engineFor: { _ in engine })
        await prefetcher.prefetch(segmentID: "s01") { [SpokenSpan(text: "Hallo", language: "de")] }
        await gate.waitForWaiter()

        await prefetcher.cancelAll()
        await gate.open()
        // The cancelled task is no longer tracked, so poll (bounded) for its cleanup.
        for _ in 0..<400 where engine.discardedTexts.isEmpty {
            try? await Task.sleep(for: .milliseconds(5))
        }

        // The engine finished one utterance after the cancel; it must not leak.
        #expect(engine.prefetchedTexts == ["Hallo"])
        #expect(engine.discardedTexts == ["Hallo"])
        #expect(await prefetcher.consume(segmentID: "s01") == nil)
    }

    @Test("cancelAll drops cached opener text so a restarted session regenerates it")
    func cancelAllClearsTextCache() async {
        let counter = Counter()
        let prefetcher = OpenerPrefetcher(engineFor: { _ in FakeEngine() })
        let generate: OpenerPrefetcher.SpanProvider = {
            await counter.increment()
            return [SpokenSpan(text: "Opener", language: "de")]
        }
        _ = await prefetcher.composedSpans(segmentID: "e01", generate: generate)
        _ = await prefetcher.composedSpans(segmentID: "e01", generate: generate)
        #expect(await counter.value == 1)

        await prefetcher.cancelAll()
        _ = await prefetcher.composedSpans(segmentID: "e01", generate: generate)

        #expect(await counter.value == 2)
    }
}

// MARK: - Test doubles

private actor Counter {
    private(set) var value = 0
    func increment() { value += 1 }
}

/// Parks callers of `wait()` until `open()`. `waitForWaiter()` lets a test
/// know a caller has reached the gate without sleeping.
private actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var arrival: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
            arrival.forEach { $0.resume() }
            arrival.removeAll()
        }
    }

    func waitForWaiter() async {
        if !waiters.isEmpty { return }
        await withCheckedContinuation { arrival.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}

/// Records prefetch/discard traffic. Prefetches resolve immediately unless
/// a `prefetchGate` holds them.
private final class FakeEngine: TTSEngine, @unchecked Sendable {
    private let lock = NSLock()
    private let prefetchGate: Gate?
    private var prefetched: [String] = []
    private var discarded: [String] = []

    init(prefetchGate: Gate? = nil) {
        self.prefetchGate = prefetchGate
    }

    var prefetchedTexts: [String] { lock.withLock { prefetched } }
    var discardedTexts: [String] { lock.withLock { discarded } }

    func speak(_ text: String, language: String) async {}
    func cancel() async {}

    func prefetch(_ text: String, language: String) async -> PrefetchedUtterance {
        if let prefetchGate { await prefetchGate.wait() }
        lock.withLock { prefetched.append(text) }
        return PrefetchedUtterance(text: text, language: language, engineKind: .apple, audioURL: nil)
    }

    func discard(_ prefetched: PrefetchedUtterance) {
        lock.withLock { discarded.append(prefetched.text) }
    }
}
