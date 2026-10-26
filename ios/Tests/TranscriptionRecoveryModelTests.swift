import Foundation
import Testing
@testable import VoiceDiary

// The Verlauf detail screen's model (FTR-05) turns the screen's lifecycle into
// runner calls. A screen that is left must stop reading the status at once,
// whatever its appearance was still waiting for.

private let session = "2026-10-24T18:00:00+02:00"

private func transcribing() -> ServerClient.SessionStatusResponse {
    .init(session_id: session, received_at: "", state: "processing", segments: [
        .init(segment_id: "s01", status: "processed", transcript_id: nil, error: nil, code: nil, upstream: nil),
        .init(segment_id: "s02", status: "transcribing", transcript_id: nil, error: nil, code: nil, upstream: nil),
    ])
}

/// A status read that waits for the test to let it answer, and counts how
/// often the refresh loop went to sleep (it only does so while following).
private actor SlowServer {
    private(set) var reads = 0
    private(set) var sleeps = 0
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func read() async -> ServerClient.SessionStatusResponse? {
        reads += 1
        if !released { await withCheckedContinuation { waiters.append($0) } }
        return transcribing()
    }

    func release() {
        released = true
        waiters.forEach { $0.resume() }
        waiters = []
    }

    func slept() { sleeps += 1 }
}

@MainActor
private func makeModel(_ server: SlowServer) -> TranscriptionRecoveryModel {
    TranscriptionRecoveryModel(
        sessionID: session,
        deps: .init(
            retry: { _, _ in transcribing() },
            status: { _ in await server.read() },
            sleep: { _ in
                await server.slept()
                throw CancellationError()
            }),
        readHealth: { Data(#"{"upstream":{"whisper":"ok"}}"#.utf8) })
}

@MainActor
private func waitUntil(_ condition: @MainActor () async -> Bool) async {
    for _ in 0..<500 {  // 1 s at most (CODING_STANDARDS.md, Tests)
        if await condition() { return }
        try? await Task.sleep(for: .milliseconds(2))
    }
    Issue.record("condition not reached in time")
}

@Suite("TranscriptionRecoveryModel")
@MainActor
struct TranscriptionRecoveryModelTests {
    @Test("leaving while the appearance's status read is still out stops the refresh before it starts")
    func leaveDuringSlowAppearance() async {
        let server = SlowServer()
        let model = makeModel(server)

        model.setVisible(true)
        await waitUntil { await server.reads == 1 }
        model.setVisible(false)
        await server.release()
        try? await Task.sleep(for: .milliseconds(100))

        // The leave bumps the runner's read epoch (FTR-04), so the answer
        // that arrives off screen is dropped and the return reads again.
        #expect(model.state.status == nil)
        #expect(await server.sleeps == 0)
        #expect(await server.reads == 1)
    }

    @Test("returning after a leave follows a running segment again")
    func returnFollows() async {
        let server = SlowServer()
        let model = makeModel(server)
        await server.release()

        model.setVisible(true)
        await waitUntil { await server.sleeps == 1 }
        model.setVisible(false)
        model.setVisible(true)
        await waitUntil { await server.sleeps == 2 }

        #expect(await server.reads >= 2)
    }

    @Test("the Whisper entry of the health answer reaches the rows' action")
    func healthReachesTheAction() async {
        let server = SlowServer()
        let model = makeModel(server)
        await server.release()

        model.setVisible(true)
        await waitUntil { model.whisper == .ok }

        #expect(model.whisper == .ok)
    }

    @Test("a health read cancelled by leaving the screen keeps the last answer")
    func cancelledHealthReadChangesNothing() async {
        let server = SlowServer()
        let health = HealthScript()
        let model = TranscriptionRecoveryModel(
            sessionID: session,
            deps: .init(retry: { _, _ in transcribing() }, status: { _ in nil }, sleep: { _ in }),
            readHealth: { await health.next() })
        await server.release()

        model.setVisible(true)
        await waitUntil { model.whisper == .ok }
        model.setVisible(false)
        model.setVisible(true)
        await waitUntil { await health.reads == 2 }
        model.setVisible(false)   // cancels the second read, which then answers nothing
        await health.finishSecondRead()
        try? await Task.sleep(for: .milliseconds(50))

        #expect(model.whisper == .ok)
    }
}

/// `/health` answers ok once, then holds the next read until released and
/// answers nothing (a cancelled or failed read).
private actor HealthScript {
    private(set) var reads = 0
    private var held: CheckedContinuation<Void, Never>?

    func next() async -> Data? {
        reads += 1
        if reads == 1 { return Data(#"{"upstream":{"whisper":"ok"}}"#.utf8) }
        await withCheckedContinuation { held = $0 }
        return nil
    }

    func finishSecondRead() {
        held?.resume()
        held = nil
    }
}
