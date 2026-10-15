import Foundation
import Testing
@testable import VoiceDiary

// Pure policy table for the app-driven retry of `pending_analysis`
// sessions (SPEC §10.6.1), plus the once-per-foreground pass that applies it.

private typealias Segment = ServerClient.SessionStatusResponse.SegmentStatus

private func segment(_ status: String, error: String? = nil) -> Segment {
    Segment(segment_id: "s01", status: status, transcript_id: nil, error: error)
}

private let pendingError = "analysis_pending: ollama_unavailable: connection refused"
private let healthy = ["ollama": "ok", "lightrag": "ok", "whisper": "ok", "voxtral": "down"]

@Suite("RetryAnalysisPolicy")
struct RetryAnalysisPolicyTests {
    @Test("triggers for a pending_analysis segment with both upstreams ok")
    func triggers() {
        #expect(RetryAnalysisPolicy.shouldRetry(
            segments: [segment("pending_analysis", error: pendingError)], upstream: healthy))
    }

    @Test("triggers when only some segments are pending")
    func mixedSegments() {
        let segments = [segment("processed"), segment("failed", error: "whisper read timed out"),
                        segment("pending_analysis", error: pendingError)]
        #expect(RetryAnalysisPolicy.shouldRetry(segments: segments, upstream: healthy))
    }

    @Test("does not trigger while Ollama or LightRAG is not ok",
          arguments: ["down", "skipped", "not_bootstrapped", "fixture"])
    func unhealthyUpstream(state: String) {
        let pending = [segment("pending_analysis", error: pendingError)]
        #expect(!RetryAnalysisPolicy.shouldRetry(segments: pending, upstream: healthy.merging(["ollama": state]) { $1 }))
        #expect(!RetryAnalysisPolicy.shouldRetry(segments: pending, upstream: healthy.merging(["lightrag": state]) { $1 }))
    }

    @Test("does not trigger when an upstream is missing from health")
    func missingUpstream() {
        let pending = [segment("pending_analysis", error: pendingError)]
        #expect(!RetryAnalysisPolicy.shouldRetry(segments: pending, upstream: ["ollama": "ok"]))
        #expect(!RetryAnalysisPolicy.shouldRetry(segments: pending, upstream: [:]))
    }

    @Test("never retries failed-only sessions")
    func failedOnly() {
        let failed = [segment("failed", error: "whisper read timed out"),
                      segment("failed", error: pendingError)]
        #expect(!RetryAnalysisPolicy.shouldRetry(segments: failed, upstream: healthy))
    }

    @Test("does not trigger on processed sessions or empty segments")
    func processedOrEmpty() {
        #expect(!RetryAnalysisPolicy.shouldRetry(segments: [segment("processed")], upstream: healthy))
        #expect(!RetryAnalysisPolicy.shouldRetry(segments: [], upstream: healthy))
    }

    @Test("requires the analysis_pending error")
    func requiresPendingError() {
        #expect(!RetryAnalysisPolicy.shouldRetry(segments: [segment("pending_analysis")], upstream: healthy))
        #expect(!RetryAnalysisPolicy.shouldRetry(
            segments: [segment("pending_analysis", error: "something else")], upstream: healthy))
    }

    @Test("session_busy, session_not_retryable and 404 are expected skips")
    func expectedSkips() {
        func http(_ status: Int, _ detail: String) -> ServerClientError {
            .http(status: status, detail: detail, failure: UpstreamFailure())
        }
        #expect(RetryAnalysisPolicy.isExpectedSkip(http(409, "session_busy")))
        #expect(RetryAnalysisPolicy.isExpectedSkip(http(409, "session_not_retryable")))
        #expect(RetryAnalysisPolicy.isExpectedSkip(http(404, "session_not_found")))
        #expect(!RetryAnalysisPolicy.isExpectedSkip(http(409, "other")))
        #expect(!RetryAnalysisPolicy.isExpectedSkip(http(500, "boom")))
        #expect(!RetryAnalysisPolicy.isExpectedSkip(URLError(.timedOut)))
    }

    @Test("lookback is 14 days")
    func lookback() {
        let now = Date()
        #expect(RetryAnalysisPolicy.isRecent(now.addingTimeInterval(-13 * 86_400), now: now))
        #expect(!RetryAnalysisPolicy.isRecent(now.addingTimeInterval(-15 * 86_400), now: now))
    }
}

private actor Calls {
    private(set) var retried: [String] = []
    private(set) var statusChecks = 0
    func retry(_ id: String) { retried.append(id) }
    func statusCheck() { statusChecks += 1 }
}

/// One-shot latch so a test can hold a pass open without sleeping.
private actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}

private struct Boom: Error {}

@Suite("AnalysisRetrier")
struct AnalysisRetrierTests {
    private func response(_ id: String, _ segments: [Segment]) -> ServerClient.SessionStatusResponse {
        .init(session_id: id, received_at: "", state: "partial", segments: segments)
    }

    /// `unknown` sessions answer 404 (nil status); `retryErrors` makes the
    /// retry call for that session throw; `started` / `hold` let a test
    /// pause the first retry call.
    private func retrier(
        calls: Calls,
        health: (@Sendable () async throws -> [String: String])? = nil,
        ids: [String],
        pending: Set<String>,
        unknown: Set<String> = [],
        retryErrors: [String: any Error] = [:],
        started: Gate? = nil,
        hold: Gate? = nil
    ) -> AnalysisRetrier {
        AnalysisRetrier(deps: .init(
            health: health ?? { healthy },
            recentSessionIDs: { _ in ids },
            status: { id in
                await calls.statusCheck()
                if unknown.contains(id) { return nil }
                let seg = pending.contains(id)
                    ? segment("pending_analysis", error: pendingError) : segment("processed")
                return response(id, [seg])
            },
            retry: { id in
                await calls.retry(id)
                await started?.open()
                await hold?.wait()
                if let error = retryErrors[id] { throw error }
            }
        ))
    }

    @Test("retries only pending sessions, once each, even if listed twice")
    func oneAttemptPerSession() async {
        let calls = Calls()
        let r = retrier(calls: calls, ids: ["a", "b", "a"], pending: ["a"])
        await r.runOnForeground()
        #expect(await calls.retried == ["a"])
        #expect(await calls.statusChecks == 2)
    }

    @Test("a second .active without going to the background is not a new foreground")
    func inactiveFlipDoesNotRetry() async {
        let calls = Calls()
        let r = retrier(calls: calls, ids: ["a"], pending: ["a"])
        await r.runOnForeground()
        await r.runOnForeground()
        #expect(await calls.retried == ["a"])
    }

    @Test("after the app was backgrounded the next foreground attempts again")
    func nextForegroundRetriesAgain() async {
        let calls = Calls()
        let r = retrier(calls: calls, ids: ["a"], pending: ["a"])
        await r.runOnForeground()
        await r.markBackgrounded()
        await r.runOnForeground()
        #expect(await calls.retried == ["a", "a"])
    }

    @Test("a trigger is dropped while a pass is still running")
    func overlappingPassDropped() async {
        let calls = Calls()
        let started = Gate()
        let hold = Gate()
        let r = retrier(calls: calls, ids: ["a"], pending: ["a"], started: started, hold: hold)
        let first = Task { await r.runOnForeground() }
        await started.wait()
        await r.markBackgrounded()
        await r.runOnForeground()
        await hold.open()
        await first.value
        #expect(await calls.retried == ["a"])
    }

    @Test("degraded Ollama or LightRAG makes no per-session request")
    func unhealthySkipsEverything() async {
        let calls = Calls()
        let r = retrier(calls: calls, health: { ["ollama": "down", "lightrag": "ok"] }, ids: ["a"], pending: ["a"])
        await r.runOnForeground()
        #expect(await calls.statusChecks == 0)
        #expect(await calls.retried.isEmpty)
    }

    @Test("an unreachable /health makes no per-session request")
    func healthFailureSkipsEverything() async {
        let calls = Calls()
        let r = retrier(calls: calls, health: { throw Boom() }, ids: ["a"], pending: ["a"])
        await r.runOnForeground()
        #expect(await calls.statusChecks == 0)
    }

    @Test("session_busy and session_not_retryable do not stop the pass", arguments: ["session_busy", "session_not_retryable"])
    func expectedConflictsAreSkipped(detail: String) async {
        let calls = Calls()
        let conflict = ServerClientError.http(status: 409, detail: detail, failure: UpstreamFailure())
        let r = retrier(calls: calls, ids: ["a", "b"], pending: ["a", "b"], retryErrors: ["a": conflict])
        await r.runOnForeground()
        #expect(await calls.retried == ["a", "b"])
    }

    @Test("a session the server does not know is skipped without a retry")
    func unknownSessionSkipped() async {
        let calls = Calls()
        let r = retrier(calls: calls, ids: ["a", "b"], pending: ["b"], unknown: ["a"])
        await r.runOnForeground()
        #expect(await calls.retried == ["b"])
    }

    @Test("an unexpected failure on one session does not stop the pass")
    func unexpectedFailureContinues() async {
        let calls = Calls()
        let server = ServerClientError.http(status: 500, detail: "boom", failure: UpstreamFailure())
        let r = retrier(calls: calls, ids: ["a", "b", "c"], pending: ["a", "b", "c"],
                        retryErrors: ["a": server, "b": URLError(.timedOut)])
        await r.runOnForeground()
        #expect(await calls.retried == ["a", "b", "c"])
    }
}

