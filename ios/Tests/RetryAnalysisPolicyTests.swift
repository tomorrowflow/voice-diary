import Foundation
import Testing
@testable import VoiceDiary

// Pure policy table for the app-driven retry of `pending_analysis`
// sessions (SPEC §10.6.1), plus the once-per-foreground pass that applies it.

private typealias Segment = ServerClient.SessionStatusResponse.SegmentStatus

private func segment(_ status: String, error: String? = nil) -> Segment {
    Segment(segment_id: "s01", status: status, transcript_id: nil, error: error, code: nil, upstream: nil)
}

private func http(_ status: Int, _ detail: String) -> ServerClientError {
    .http(status: status, detail: detail, failure: UpstreamFailure())
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

    // Blindfold gate: only a `blindfold` entry in /health matters; a default
    // route or an old server has none and keeps today's decision.
    @Test("a Blindfold entry that is ok retries as before; no entry is unchanged")
    func blindfoldOkOrAbsent() {
        let pending = [segment("pending_analysis", error: pendingError)]
        #expect(RetryAnalysisPolicy.shouldRetry(
            segments: pending, upstream: healthy.merging(["blindfold": "ok"]) { $1 }))
        #expect(RetryAnalysisPolicy.shouldRetry(segments: pending, upstream: healthy))
    }

    @Test("does not trigger while Blindfold is not ok, even with Ollama and LightRAG ok",
          arguments: ["down", "skipped", "fixture", "starting", ""])
    func blindfoldNotOk(state: String) {
        let pending = [segment("pending_analysis", error: pendingError)]
        #expect(!RetryAnalysisPolicy.shouldRetry(
            segments: pending, upstream: healthy.merging(["blindfold": state]) { $1 }))
    }

    @Test("Blindfold ok does not rescue an unhealthy Ollama or LightRAG")
    func blindfoldOkDoesNotOverride() {
        let pending = [segment("pending_analysis", error: pendingError)]
        let up = healthy.merging(["blindfold": "ok", "ollama": "down"]) { $1 }
        #expect(!RetryAnalysisPolicy.shouldRetry(segments: pending, upstream: up))
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

// Exact boundaries of the policy: the inclusive cutoff, string matching that
// must not loosen into case-insensitive or substring matching, and the
// narrow set of skip responses.
@Suite("RetryAnalysisPolicy boundaries")
struct RetryAnalysisPolicyBoundaryTests {
    // A whole-second reference date, so every offset below is exact.
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private let cutoff: TimeInterval = 14 * 24 * 60 * 60

    private func retries(status: String, error: String?) -> Bool {
        RetryAnalysisPolicy.shouldRetry(segments: [segment(status, error: error)], upstream: healthy)
    }

    @Test("a session captured exactly 14 days ago is still recent")
    func cutoffIsInclusive() {
        #expect(RetryAnalysisPolicy.isRecent(now.addingTimeInterval(-cutoff), now: now))
    }

    @Test("one second inside the cutoff is recent, one second outside is not")
    func cutoffNeighbours() {
        #expect(RetryAnalysisPolicy.isRecent(now.addingTimeInterval(-cutoff + 1), now: now))
        #expect(!RetryAnalysisPolicy.isRecent(now.addingTimeInterval(-cutoff - 1), now: now))
    }

    @Test("a session captured right now or in the future is recent",
          arguments: [0.0, 1.0, 60.0, 14 * 24 * 60 * 60.0])
    func nowAndFuture(offset: TimeInterval) {
        #expect(RetryAnalysisPolicy.isRecent(now.addingTimeInterval(offset), now: now))
    }

    @Test("only the exact pending_analysis status qualifies",
          arguments: ["Pending_Analysis", "PENDING_ANALYSIS", "pending_analysis ", " pending_analysis",
                      "pending", "pending_analysis_", "analysis_pending", ""])
    func nearMissStatus(status: String) {
        #expect(!retries(status: status, error: "analysis_pending: ollama_unavailable"))
    }

    @Test("an error with the exact analysis_pending: prefix qualifies, with or without a suffix",
          arguments: ["analysis_pending:", "analysis_pending: ", "analysis_pending:x",
                      "analysis_pending: ollama_unavailable: connection refused"])
    func validPrefix(error: String) {
        #expect(retries(status: "pending_analysis", error: error))
    }

    @Test("a near-miss or empty error does not qualify",
          arguments: ["", "analysis_pending", "analysis_pending;", "analysis_pending :", "Analysis_Pending: x",
                      "ANALYSIS_PENDING:", " analysis_pending: x", "x analysis_pending: x",
                      "analysis-pending: x", "analysis_pend:"])
    func nearMissErrorPrefix(error: String) {
        #expect(!retries(status: "pending_analysis", error: error))
    }

    @Test("a missing error does not qualify")
    func missingError() {
        #expect(!retries(status: "pending_analysis", error: nil))
    }

    @Test("404 is an expected skip whatever the detail",
          arguments: ["", "session_not_found", "session_busy", "anything at all", "Not Found"])
    func notFoundAnyDetail(detail: String) {
        #expect(RetryAnalysisPolicy.isExpectedSkip(http(404, detail)))
    }

    @Test("409 skips only for the two exact details",
          arguments: ["session_busy", "session_not_retryable"])
    func conflictExactDetails(detail: String) {
        #expect(RetryAnalysisPolicy.isExpectedSkip(http(409, detail)))
    }

    @Test("409 with a near-miss detail is not a skip",
          arguments: ["", "Session_Busy", "SESSION_NOT_RETRYABLE", "session_busy ", " session_busy",
                      "session_busy:", "session_busy: retry later", "session_not_retry",
                      "session_not_retryable.", "session_not_found", "busy"])
    func conflictNearMissDetails(detail: String) {
        #expect(!RetryAnalysisPolicy.isExpectedSkip(http(409, detail)))
    }

    @Test("other statuses are never skips, even with a skip detail",
          arguments: [200, 204, 400, 401, 403, 405, 408, 410, 422, 429, 500, 502, 503])
    func otherStatuses(status: Int) {
        #expect(!RetryAnalysisPolicy.isExpectedSkip(http(status, "session_busy")))
        #expect(!RetryAnalysisPolicy.isExpectedSkip(http(status, "session_not_retryable")))
        #expect(!RetryAnalysisPolicy.isExpectedSkip(http(status, "session_not_found")))
    }

    @Test("errors that are not HTTP responses are never skips")
    func nonHTTPErrors() {
        #expect(!RetryAnalysisPolicy.isExpectedSkip(URLError(.timedOut)))
        #expect(!RetryAnalysisPolicy.isExpectedSkip(URLError(.notConnectedToInternet)))
        #expect(!RetryAnalysisPolicy.isExpectedSkip(CancellationError()))
        #expect(!RetryAnalysisPolicy.isExpectedSkip(ServerClientError.notConfigured))
        #expect(!RetryAnalysisPolicy.isExpectedSkip(ServerClientError.decodingFailed("session_busy")))
        #expect(!RetryAnalysisPolicy.isExpectedSkip(ServerClientError.missingFile(URL(fileURLWithPath: "/404"))))
    }
}

private actor Calls {
    private(set) var retried: [String] = []
    private(set) var statusChecks = 0
    /// Records the attempt and returns how many have been made so far.
    func retry(_ id: String) -> Int {
        retried.append(id)
        return retried.count
    }
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
    /// pause the first retry call only.
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
                if await calls.retry(id) == 1 {
                    await started?.open()
                    await hold?.wait()
                }
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

    @Test("a pass still running when the app backgrounds stops, and cannot overlap the next foreground's pass")
    func stalePassStopsAtForegroundChange() async {
        let calls = Calls()
        let started = Gate()
        let hold = Gate()
        let r = retrier(calls: calls, ids: ["a", "b"], pending: ["a", "b"], started: started, hold: hold)

        // Foreground 1: the pass is mid-request on "a".
        let stale = Task { await r.runOnForeground() }
        await started.wait()

        // Background, then foreground 2 runs its own pass to completion.
        await r.markBackgrounded()
        await r.runOnForeground()
        #expect(await calls.retried == ["a", "a", "b"])

        // An inactive -> active flip in foreground 2 starts nothing.
        await r.runOnForeground()

        // The stale pass finishes its in-flight request but skips "b".
        await hold.open()
        await stale.value
        #expect(await calls.retried == ["a", "a", "b"])
    }

    @Test("degraded Ollama or LightRAG makes no per-session request")
    func unhealthySkipsEverything() async {
        let calls = Calls()
        let r = retrier(calls: calls, health: { ["ollama": "down", "lightrag": "ok"] }, ids: ["a"], pending: ["a"])
        await r.runOnForeground()
        #expect(await calls.statusChecks == 0)
        #expect(await calls.retried.isEmpty)
    }

    @Test("a down Blindfold makes no per-session request; ok proceeds")
    func blindfoldDownSkipsEverything() async {
        let down = Calls()
        let waiting = retrier(
            calls: down, health: { healthy.merging(["blindfold": "down"]) { $1 } }, ids: ["a"], pending: ["a"])
        await waiting.runOnForeground()
        #expect(await down.statusChecks == 0)
        #expect(await down.retried.isEmpty)

        let up = Calls()
        let proceeding = retrier(
            calls: up, health: { healthy.merging(["blindfold": "ok"]) { $1 } }, ids: ["a"], pending: ["a"])
        await proceeding.runOnForeground()
        #expect(await up.retried == ["a"])
    }

    @Test("an unreachable /health makes no per-session request")
    func healthFailureSkipsEverything() async {
        let calls = Calls()
        let r = retrier(calls: calls, health: { throw Boom() }, ids: ["a"], pending: ["a"])
        await r.runOnForeground()
        #expect(await calls.statusChecks == 0)
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
