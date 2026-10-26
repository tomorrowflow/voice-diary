import Foundation
import Testing
@testable import VoiceDiary

// The recovery runner (ADR 0005, 0007) driven through closure fakes: one
// attempt per call, no resubmission after an unknown outcome, refreshing
// while the screen is visible and nothing at all while it is not.

private typealias Response = ServerClient.SessionStatusResponse
private typealias Segment = ServerClient.SessionStatusResponse.SegmentStatus

private let session = "2026-10-24T18:00:00+02:00"

private func segment(_ id: String, _ status: String, recoverable: Bool? = nil) -> Segment {
    Segment(segment_id: id, status: status, transcript_id: nil, error: nil, code: nil, upstream: nil,
            recoverable: recoverable)
}

private func response(_ segments: Segment...) -> Response {
    Response(session_id: session, received_at: "", state: "partial", segments: segments)
}

/// s01 processed, s02 `s02` (recoverable when failed), s03 failed and recoverable.
private func twoFailed(_ s02: String = "failed") -> Response {
    response(segment("s01", "processed"),
             segment("s02", s02, recoverable: s02 == "failed" ? true : nil),
             segment("s03", "failed", recoverable: true))
}

private func http(_ status: Int, _ detail: String, retryAfter: TimeInterval? = nil) -> ServerClientError {
    .http(status: status, detail: detail,
          failure: UpstreamFailure(code: status == 503 ? detail : nil, retryAfter: retryAfter))
}

/// The server the runner talks to: records every call and answers from a
/// script. The last scripted answer repeats.
private actor FakeServer {
    private(set) var retries: [String] = []
    private(set) var reads = 0
    private(set) var sleeps: [TimeInterval] = []
    private var retryScript: [Result<Response, any Error>]
    private var readScript: [Result<Response?, any Error>] = [.success(nil)]
    private var readIndex = 0
    private var hold: RecoveryGate?
    private var started: RecoveryGate?
    private var readHold: RecoveryGate?
    private var readStarted: RecoveryGate?

    init(retry: [Result<Response, any Error>] = []) { retryScript = retry }

    /// Makes the next status read take its answer, then open `started` and
    /// wait for `hold` before returning it.
    func holdNextRead(started: RecoveryGate, until hold: RecoveryGate) {
        readStarted = started
        readHold = hold
    }

    func scriptReads(_ script: [Result<Response?, any Error>]) {
        readScript = script
        readIndex = 0
    }

    /// Makes the next retry call open `started` and wait for `hold`.
    func holdNextRetry(started: RecoveryGate, until hold: RecoveryGate) {
        self.started = started
        self.hold = hold
    }

    func retry(_ sessionID: String, _ segmentID: String) async throws -> Response {
        retries.append("\(sessionID)/\(segmentID)")
        let index = retries.count - 1
        if let started, let hold {
            self.started = nil
            self.hold = nil
            await started.open()
            await hold.wait()
        }
        return try retryScript[min(index, retryScript.count - 1)].get()
    }

    func read(_ sessionID: String) async throws -> Response? {
        reads += 1
        let result = readScript[min(readIndex, readScript.count - 1)]
        readIndex += 1
        if let readStarted, let readHold {
            self.readStarted = nil
            self.readHold = nil
            await readStarted.open()
            await readHold.wait()
        }
        return try result.get()
    }

    func slept(_ interval: TimeInterval) { sleeps.append(interval) }
}

/// One-shot latch so a test can hold a request open without sleeping.
private actor RecoveryGate {
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

/// A sleep the test advances by hand; a cancelled sleeper throws.
private actor Ticker {
    private var waiters: [UUID: CheckedContinuation<Void, any Error>] = [:]
    /// Sleepers parked and not yet ticked; a ticked sleeper stops counting at
    /// once, so a test never mistakes it for the next sleep.
    var sleeping: Int { waiters.count }

    func sleep() async throws {
        let id = UUID()
        try await withTaskCancellationHandler(
            operation: { try await self.park(id) },
            onCancel: { Task { await self.cancel(id) } })
    }

    private func park(_ id: UUID) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            if Task.isCancelled {
                continuation.resume(throwing: CancellationError())
            } else {
                waiters[id] = continuation
            }
        }
    }

    func tick() {
        let current = waiters
        waiters = [:]
        current.values.forEach { $0.resume() }
    }

    private func cancel(_ id: UUID) {
        waiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }
}

private func waitUntil(_ condition: @Sendable () async -> Bool) async {
    for _ in 0..<500 {  // 1 s at most (CODING_STANDARDS.md, Tests)
        if await condition() { return }
        try? await Task.sleep(for: .milliseconds(2))
    }
    Issue.record("condition not reached in time")
}

private func makeRunner(
    _ server: FakeServer,
    ticker: Ticker? = nil,
    interval: TimeInterval = 7
) -> TranscriptionRecoveryRunner {
    TranscriptionRecoveryRunner(
        sessionID: session,
        deps: .init(
            retry: { try await server.retry($0, $1) },
            status: { try await server.read($0) },
            sleep: { interval in
                await server.slept(interval)
                if let ticker {
                    try await ticker.sleep()
                } else {
                    try Task.checkCancellation()
                    await Task.yield()
                }
            }),
        refreshInterval: interval)
}

@Suite("TranscriptionRecoveryRunner")
struct TranscriptionRecoveryRunnerTests {
    // --- one attempt per tap --------------------------------------------

    @Test("a tap makes exactly one request, for that segment, and shows it in flight")
    func oneAttemptPerTap() async {
        let server = FakeServer(retry: [.success(twoFailed("transcribing"))])
        await server.scriptReads([.success(twoFailed("transcribing"))])
        let runner = makeRunner(server)

        await runner.start(segmentID: "s02")

        #expect(await server.retries == ["\(session)/s02"])
        let state = await runner.state
        #expect(state.attemptSegmentID == "s02")
        #expect(state.action(for: "s02", whisper: .ok) == .inFlight)
        // The other failed segment of the session waits behind the running one.
        #expect(state.action(for: "s03", whisper: .ok) == .disabled(.siblingTranscribing))
    }

    @Test("a double tap while the request is in flight does nothing")
    func doubleTapWhileSubmitting() async {
        let server = FakeServer(retry: [.success(twoFailed("transcribing"))])
        let started = RecoveryGate()
        let release = RecoveryGate()
        await server.holdNextRetry(started: started, until: release)
        let runner = makeRunner(server)

        let first = Task { await runner.start(segmentID: "s02") }
        await started.wait()
        await runner.start(segmentID: "s02")
        await runner.start(segmentID: "s03")
        await release.open()
        await first.value

        #expect(await server.retries == ["\(session)/s02"])
    }

    @Test("a status read that began before the tap and lands after it cannot end the attempt")
    func staleReadDoesNotEndAttempt() async {
        let server = FakeServer(retry: [.success(twoFailed("transcribing"))])
        await server.scriptReads([.success(twoFailed("failed"))])
        let readStarted = RecoveryGate()
        let readRelease = RecoveryGate()
        await server.holdNextRead(started: readStarted, until: readRelease)
        let ticker = Ticker()
        let runner = makeRunner(server, ticker: ticker)

        let appearing = Task { await runner.screenAppeared() }
        await readStarted.wait()
        await runner.start(segmentID: "s02")
        await readRelease.open()
        await appearing.value

        let state = await runner.state
        #expect(state.attemptSegmentID == "s02")
        #expect(state.status?.segments[1].state == .transcribing)
        #expect(state.action(for: "s02", whisper: .ok) == .inFlight)
        await runner.start(segmentID: "s02")
        #expect(await server.retries == ["\(session)/s02"])
        await runner.screenLeft()
    }

    @Test("a tap while the attempt is still being followed does nothing")
    func tapWhileFollowing() async {
        let server = FakeServer(retry: [.success(twoFailed("transcribing"))])
        await server.scriptReads([.success(twoFailed("transcribing"))])
        let ticker = Ticker()
        let runner = makeRunner(server, ticker: ticker)
        await runner.screenAppeared()

        await runner.start(segmentID: "s02")
        await runner.start(segmentID: "s02")
        await runner.start(segmentID: "s03")

        #expect(await server.retries == ["\(session)/s02"])
        await runner.screenLeft()
    }

    @Test("a tap after the attempt ended starts a new attempt, one per tap")
    func tapAfterOutcome() async {
        let server = FakeServer(retry: [.success(twoFailed("transcribing")), .success(twoFailed("transcribing"))])
        await server.scriptReads([.success(twoFailed("failed"))])
        let runner = makeRunner(server)
        await runner.screenAppeared()

        await runner.start(segmentID: "s02")
        await runner.settled()
        #expect(await runner.state.attemptSegmentID == nil)
        await runner.start(segmentID: "s02")
        await runner.settled()

        #expect(await server.retries == ["\(session)/s02", "\(session)/s02"])
    }

    // --- refreshing -----------------------------------------------------

    @Test("while the screen is visible the status is read on the interval until the segment leaves transcribing")
    func refreshesUntilSegmentLeavesTranscribing() async {
        let server = FakeServer(retry: [.success(twoFailed("transcribing"))])
        await server.scriptReads([
            .success(twoFailed("failed")),          // read when the screen appears
            .success(twoFailed("transcribing")),
            .success(twoFailed("transcribing")),
            .success(twoFailed("pending_analysis")),
        ])
        let runner = makeRunner(server, interval: 7)
        await runner.screenAppeared()

        await runner.start(segmentID: "s02")
        await runner.settled()

        #expect(await server.reads == 4)
        #expect(await server.sleeps == [7, 7, 7])
        let state = await runner.state
        #expect(state.attemptSegmentID == nil)
        #expect(state.status?.segments[1].state == .pendingAnalysis)
        #expect(state.action(for: "s02", whisper: .ok) == .hidden)
        #expect(await server.retries.count == 1)
    }

    @Test("a segment that ends failed again is offered again, and the refresh stops")
    func endsFailed() async {
        let server = FakeServer(retry: [.success(twoFailed("transcribing"))])
        await server.scriptReads([.success(twoFailed("transcribing")), .success(twoFailed("failed"))])
        let runner = makeRunner(server)

        await runner.screenAppeared()
        await runner.start(segmentID: "s02")
        await runner.settled()

        let state = await runner.state
        #expect(state.attemptSegmentID == nil)
        #expect(state.action(for: "s02", whisper: .ok) == .enabled)
        #expect(await server.retries.count == 1)
        let reads = await server.reads
        await runner.settled()
        #expect(await server.reads == reads)
    }

    @Test("nothing is read or slept while the screen has not appeared")
    func notVisibleNoRefresh() async {
        let server = FakeServer(retry: [.success(twoFailed("transcribing"))])
        let runner = makeRunner(server)

        await runner.start(segmentID: "s02")
        await runner.settled()

        #expect(await server.retries.count == 1)
        #expect(await server.reads == 0)
        #expect(await server.sleeps.isEmpty)
    }

    // --- leaving and returning ------------------------------------------

    @Test("leaving the screen stops the refresh; returning reads once and resumes until the outcome")
    func leaveAndReconcile() async {
        let server = FakeServer(retry: [.success(twoFailed("transcribing"))])
        await server.scriptReads([.success(twoFailed("failed"))])
        let ticker = Ticker()
        let runner = makeRunner(server, ticker: ticker)
        await runner.screenAppeared()
        await server.scriptReads([.success(twoFailed("transcribing"))])
        let baseline = await server.reads

        await runner.start(segmentID: "s02")
        await waitUntil { await ticker.sleeping == 1 }
        await runner.screenLeft()
        await runner.settled()
        await waitUntil { await ticker.sleeping == 0 }   // the cancelled sleep ended
        await ticker.tick()
        #expect(await server.reads == baseline)

        // The server finished meanwhile; returning reconciles without a request.
        await server.scriptReads([.success(twoFailed("processed"))])
        await runner.screenAppeared()
        await runner.settled()

        #expect(await server.reads == baseline + 1)
        let state = await runner.state
        #expect(state.attemptSegmentID == nil)
        #expect(state.status?.segments[1].state == .processed)
        #expect(await server.retries == ["\(session)/s02"])
    }

    @Test("returning while the segment is still transcribing resumes the refresh, with no new request")
    func returnWhileStillRunning() async {
        let server = FakeServer(retry: [.success(twoFailed("transcribing"))])
        await server.scriptReads([.success(twoFailed("transcribing"))])
        let ticker = Ticker()
        let runner = makeRunner(server, ticker: ticker)

        await runner.start(segmentID: "s02")
        await runner.screenAppeared()
        await waitUntil { await ticker.sleeping == 1 }
        await runner.screenLeft()
        await waitUntil { await ticker.sleeping == 0 }   // the cancelled sleep ended
        await runner.screenAppeared()
        await waitUntil { await ticker.sleeping == 1 }

        await server.scriptReads([.success(twoFailed("pending_analysis"))])
        await ticker.tick()
        await runner.settled()

        #expect(await runner.state.attemptSegmentID == nil)
        #expect(await server.retries.count == 1)
        await runner.screenLeft()
    }

    @Test("a lifecycle call that arrives after a newer one is dropped")
    func lateLifecycleCallIsDropped() async {
        let server = FakeServer()
        await server.scriptReads([.success(twoFailed("failed"))])
        let runner = makeRunner(server)

        await runner.screenLeft(order: 2)
        await runner.screenAppeared(order: 1)

        #expect(await server.reads == 0)
        await runner.screenAppeared(order: 3)
        #expect(await server.reads == 1)
        await runner.screenLeft()
    }

    @Test("a fresh screen finding a segment transcribing follows it without having started anything")
    func freshScreenFollowsRunningSegment() async {
        let server = FakeServer()
        await server.scriptReads([.success(twoFailed("transcribing")), .success(twoFailed("processed"))])
        let runner = makeRunner(server)

        await runner.screenAppeared()
        await runner.settled()

        #expect(await server.retries.isEmpty)
        #expect(await server.reads == 2)
        #expect(await runner.state.status?.segments[1].state == .processed)
    }

    @Test("a screen that finds nothing transcribing does not poll")
    func freshScreenQuiet() async {
        let server = FakeServer()
        await server.scriptReads([.success(twoFailed("failed"))])
        let runner = makeRunner(server)

        await runner.screenAppeared()
        await runner.settled()

        #expect(await server.reads == 1)
        #expect(await server.sleeps.isEmpty)
        #expect(await runner.state.action(for: "s02", whisper: .ok) == .enabled)
    }

    // --- an unknown outcome ---------------------------------------------

    @Test("after a timeout or lost connection the status is read and followed, never resubmitted",
          arguments: [URLError.Code.timedOut, .networkConnectionLost, .cancelled])
    func ambiguousThenTranscribing(code: URLError.Code) async {
        let server = FakeServer(retry: [.failure(URLError(code))])
        await server.scriptReads([.success(twoFailed("failed"))])
        let ticker = Ticker()
        let runner = makeRunner(server, ticker: ticker)
        await runner.screenAppeared()
        let appearing = await server.reads
        await server.scriptReads([
            .success(twoFailed("transcribing")),
            .success(twoFailed("transcribing")),
            .success(twoFailed("processed")),
        ])

        await runner.start(segmentID: "s02")
        // The status is read right away, before the interval or any other request.
        #expect(await server.reads == appearing + 1)
        #expect(await runner.state.attemptSegmentID == "s02")
        await waitUntil { await ticker.sleeping == 1 }
        await ticker.tick()
        await waitUntil { await ticker.sleeping == 1 }
        await ticker.tick()
        await runner.settled()

        #expect(await server.retries == ["\(session)/s02"])
        let state = await runner.state
        #expect(state.attemptSegmentID == nil)
        #expect(state.status?.segments[1].state == .processed)
    }

    @Test("an ambiguous outcome that the status shows as pending_analysis or processed ends the attempt",
          arguments: ["pending_analysis", "processed"])
    func ambiguousThenSucceeded(status: String) async {
        let server = FakeServer(retry: [.failure(URLError(.timedOut))])
        await server.scriptReads([.success(twoFailed(status))])
        let runner = makeRunner(server)

        await runner.start(segmentID: "s02")
        await runner.settled()

        #expect(await server.retries.count == 1)
        let state = await runner.state
        #expect(state.attemptSegmentID == nil)
        #expect(state.action(for: "s02", whisper: .ok) == .hidden)
    }

    @Test("an ambiguous outcome with the segment still failed offers the action again, without resubmitting")
    func ambiguousThenStillFailed() async {
        let server = FakeServer(retry: [.failure(URLError(.networkConnectionLost))])
        await server.scriptReads([.success(twoFailed("failed"))])
        let runner = makeRunner(server)
        await runner.screenAppeared()

        await runner.start(segmentID: "s02")
        await runner.settled()

        #expect(await server.retries.count == 1)
        let state = await runner.state
        #expect(state.attemptSegmentID == nil)
        #expect(state.action(for: "s02", whisper: .ok) == .enabled)
        #expect(await server.sleeps.isEmpty)
    }

    @Test("when the status cannot be read either the outcome stays unknown: still in flight, reading again, not resubmitting")
    func ambiguousStatusUnreadable() async {
        let server = FakeServer(retry: [.failure(URLError(.timedOut))])
        await server.scriptReads([.success(twoFailed("failed"))])
        let ticker = Ticker()
        let runner = makeRunner(server, ticker: ticker)
        await runner.screenAppeared()
        let appearing = await server.reads
        await server.scriptReads([
            .failure(URLError(.notConnectedToInternet)),
            .failure(URLError(.notConnectedToInternet)),
            .success(twoFailed("failed")),
        ])

        await runner.start(segmentID: "s02")
        #expect(await runner.state.attemptSegmentID == "s02")
        await waitUntil { await ticker.sleeping == 1 }
        await ticker.tick()
        await waitUntil { await ticker.sleeping == 1 }
        #expect(await runner.state.attemptSegmentID == "s02")
        await ticker.tick()
        await runner.settled()

        #expect(await server.retries.count == 1)
        #expect(await server.reads == appearing + 3)
        #expect(await runner.state.attemptSegmentID == nil)
        #expect(await runner.state.action(for: "s02", whisper: .ok) == .enabled)
    }

    @Test("a 202 that cannot be decoded is an unknown outcome too, settled when the screen is next visible")
    func undecodable202() async {
        let server = FakeServer(retry: [.failure(ServerClientError.decodingFailed("bad"))])
        await server.scriptReads([.success(twoFailed("transcribing")), .success(twoFailed("processed"))])
        let runner = makeRunner(server)

        await runner.start(segmentID: "s02")
        #expect(await server.reads == 1)
        #expect(await runner.state.attemptSegmentID == "s02")
        await runner.screenAppeared()
        await runner.settled()

        #expect(await server.retries.count == 1)
        #expect(await runner.state.attemptSegmentID == nil)
    }

    @Test("an unconfigured client never sent the request: nothing is in flight and nothing is read")
    func notConfigured() async {
        let server = FakeServer(retry: [.failure(ServerClientError.notConfigured)])
        let runner = makeRunner(server)

        await runner.start(segmentID: "s02")

        #expect(await runner.state.attemptSegmentID == nil)
        #expect(await server.reads == 0)
    }

    // --- request errors -------------------------------------------------

    @Test("409 segment_audio_missing hides the action for that segment only, and further taps are ignored")
    func audioMissing() async {
        let server = FakeServer(retry: [.failure(http(409, "segment_audio_missing"))])
        await server.scriptReads([.success(twoFailed("failed"))])
        let runner = makeRunner(server)
        await runner.screenAppeared()

        await runner.start(segmentID: "s02")
        await runner.start(segmentID: "s02")

        let state = await runner.state
        #expect(state.action(for: "s02", whisper: .ok) == .hidden)
        #expect(state.action(for: "s03", whisper: .ok) == .enabled)
        #expect(state.attemptSegmentID == nil)
        #expect(await server.retries.count == 1)
        // A later status read does not bring the action back.
        await runner.screenLeft()
        await runner.screenAppeared()
        #expect(await runner.state.action(for: "s02", whisper: .ok) == .hidden)
    }

    @Test("session_busy and whisper_unavailable leave the segment as it was and give the screen a reason",
          arguments: [
              (409, "session_busy", TranscriptionRecoveryRefusal.sessionBusy),
              (503, "whisper_unavailable", TranscriptionRecoveryRefusal.whisperUnavailable(retryAfter: 30)),
          ])
    func refusedLeavesSegmentAsIs(status: Int, detail: String, expected: TranscriptionRecoveryRefusal) async {
        let server = FakeServer(retry: [.failure(http(status, detail, retryAfter: 30))])
        await server.scriptReads([.success(twoFailed("failed"))])
        let runner = makeRunner(server)
        await runner.screenAppeared()
        let before = await runner.state

        await runner.start(segmentID: "s02")
        await runner.settled()

        let after = await runner.state
        #expect(after.notices["s02"] == expected)
        #expect(after.notices["s03"] == nil)
        #expect(after.status == before.status)
        #expect(after.attemptSegmentID == nil)
        #expect(after.action(for: "s02", whisper: .ok) == .enabled)
        #expect(await server.reads == 1)   // no status read, no polling
        #expect(await server.sleeps.isEmpty)
    }

    @Test("a refusal's reason is dropped by the next tap")
    func noticeClearedByNextTap() async {
        let server = FakeServer(retry: [.failure(http(409, "session_busy")), .success(twoFailed("transcribing"))])
        await server.scriptReads([.success(twoFailed("transcribing"))])
        let runner = makeRunner(server)

        await runner.start(segmentID: "s02")
        #expect(await runner.state.notices["s02"] == .sessionBusy)
        await runner.start(segmentID: "s02")

        #expect(await runner.state.notices["s02"] == nil)
        #expect(await server.retries.count == 2)
    }

    @Test("409 segment_not_failed reads the status instead of resubmitting")
    func segmentNotFailed() async {
        let server = FakeServer(retry: [.failure(http(409, "segment_not_failed"))])
        await server.scriptReads([.success(twoFailed("processed"))])
        let runner = makeRunner(server)

        await runner.start(segmentID: "s02")
        await runner.settled()

        #expect(await server.retries.count == 1)
        #expect(await server.reads == 1)
        #expect(await runner.state.attemptSegmentID == nil)
        #expect(await runner.state.status?.segments[1].state == .processed)
    }

    @Test("a missing session or segment ends the attempt with the reason and no read")
    func notFound() async {
        let server = FakeServer(retry: [.failure(http(404, "session_not_found"))])
        let runner = makeRunner(server)

        await runner.start(segmentID: "s02")

        let state = await runner.state
        #expect(state.notices["s02"] == .sessionNotFound)
        #expect(state.attemptSegmentID == nil)
        #expect(await server.reads == 0)
    }

    // --- the state the screen reads --------------------------------------

    @Test("an action needs a status the runner has read")
    func noStatusNoAction() async {
        let runner = makeRunner(FakeServer())
        #expect(await runner.state.action(for: "s02", whisper: .ok) == .hidden)
    }

    @Test("Whisper coming back enables the action and starts nothing")
    func healthNeverStarts() async {
        let server = FakeServer()
        await server.scriptReads([.success(twoFailed("failed"))])
        let runner = makeRunner(server)
        await runner.screenAppeared()
        await runner.settled()

        let state = await runner.state
        #expect(state.action(for: "s02", whisper: .down) == .disabled(.whisperNotReachable))
        #expect(state.action(for: "s02", whisper: .ok) == .enabled)
        #expect(await server.retries.isEmpty)
    }

    @Test("every state change is published to the screen")
    func publishes() async {
        let server = FakeServer(retry: [.success(twoFailed("transcribing"))])
        await server.scriptReads([.success(twoFailed("processed"))])
        let seen = Seen()
        let runner = TranscriptionRecoveryRunner(
            sessionID: session,
            deps: .init(
                retry: { try await server.retry($0, $1) },
                status: { try await server.read($0) },
                sleep: { _ in }),
            refreshInterval: 1,
            onChange: { state in Task { await seen.record(state.attemptSegmentID) } })

        await runner.start(segmentID: "s02")
        await waitUntil { await seen.values.contains(where: { $0 == "s02" }) }
    }
}

private actor Seen {
    private(set) var values: [String?] = []
    func record(_ value: String?) { values.append(value) }
}

// --- no request without an explicit call ---------------------------------

@Suite("Recovery is never started implicitly")
struct RecoveryNeverImplicitTests {
    /// Every Swift source under `ios/Sources` that mentions `needle`.
    private func sources(mentioning needle: String) throws -> Set<String> {
        let sourcesDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources", directoryHint: .isDirectory)
        let enumerator = try #require(FileManager.default.enumerator(
            at: sourcesDir, includingPropertiesForKeys: nil))
        var found: Set<String> = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            if try String(contentsOf: url, encoding: .utf8).contains(needle) {
                found.insert(url.lastPathComponent)
            }
        }
        return found
    }

    @Test("only the client and the runner name the recovery request")
    func requestIsReachedOnlyThroughTheRunner() throws {
        #expect(try sources(mentioning: "retryTranscription") ==
                ["ServerClient.swift", "TranscriptionRecoveryRunner.swift"])
    }

    // The foreground hook (`VoiceDiaryApp`), the health refresh (`Reachability`)
    // and `AnalysisRetrier` must not reach the runner. Only the Verlauf detail
    // screen's model (FTR-05) does, and it starts nothing but on the button.
    @Test("no hook, health refresh or retrier references the runner")
    func runnerIsReferencedOnlyByItselfAndTheScreenModel() throws {
        #expect(try sources(mentioning: "TranscriptionRecoveryRunner") ==
                ["TranscriptionRecoveryRunner.swift", "TranscriptionRecoveryModel.swift"])
    }

    @Test("the screen model starts an attempt only from recover(segmentID:)")
    func modelStartsOnlyFromRecover() throws {
        let sourcesDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/UI/Verlauf/TranscriptionRecoveryModel.swift")
        let source = try String(contentsOf: sourcesDir, encoding: .utf8)
        #expect(source.components(separatedBy: ".start(segmentID:").count == 2)
    }

    @Test("a screen appearing, health improving and the status refresh make no request on their own")
    func appearingAndHealthMakeNoRequest() async {
        let server = FakeServer()
        await server.scriptReads([.success(twoFailed("failed"))])
        let runner = makeRunner(server)

        await runner.screenAppeared()
        await runner.settled()
        for health in [WhisperHealth.down, .unknown, .ok] {
            _ = await runner.state.action(for: "s02", whisper: health)
        }
        await runner.screenLeft()
        await runner.screenAppeared()
        await runner.settled()

        #expect(await server.retries.isEmpty)
    }
}
