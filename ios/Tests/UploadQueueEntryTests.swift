import Foundation
import Testing
@testable import VoiceDiary

// Queue-entry rules for failed uploads (SPEC §10.6): backoff vs
// `Retry-After`, the last failure code, compatible decoding of old queue
// files, and audio paths that survive every failure. Pure — no network.

@Suite("SessionUploader.QueueEntry")
struct UploadQueueEntryTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func entry(attempts: Int = 0) -> SessionUploader.QueueEntry {
        .init(
            id: "2026-04-27T19:30:00+02:00",
            manifest: Manifest(session_id: "2026-04-27T19:30:00+02:00", date: "2026-04-27"),
            audio_file_paths: ["segments/s01.m4a": "~AppSupport/sessions/x/segments/s01.m4a"],
            attempts: attempts,
            next_attempt_at: now
        )
    }

    private func http(_ status: Int, _ failure: UpstreamFailure = UpstreamFailure()) -> ServerClientError {
        .http(status: status, detail: "", failure: failure)
    }

    private func fail(_ entry: SessionUploader.QueueEntry, _ error: any Error) -> SessionUploader.QueueEntry {
        entry.afterFailure(error, outcome: UploadOutcome.classify(error), now: now)
    }

    @Test("a Retry-After longer than the backoff step wins")
    func longerRetryAfterWins() {
        // attempts 0 -> 1: backoff step is 2s.
        let updated = fail(entry(), http(503, UpstreamFailure(retryable: true, retryAfter: 90)))
        #expect(updated.attempts == 1)
        #expect(updated.next_attempt_at == now.addingTimeInterval(90))
    }

    @Test("a Retry-After shorter than the backoff step is ignored")
    func shorterRetryAfterIgnored() {
        // attempts 5 -> 6: backoff step is 600s.
        let updated = fail(entry(attempts: 5), http(503, UpstreamFailure(retryable: true, retryAfter: 5)))
        #expect(updated.next_attempt_at == now.addingTimeInterval(600))
    }

    @Test("without Retry-After the backoff curve is unchanged")
    func backoffUnchanged() {
        let updated = fail(entry(), http(500))
        #expect(updated.attempts == 1)
        #expect(updated.next_attempt_at == now.addingTimeInterval(2))
    }

    @Test("retryable: false is neither rescheduled nor marked permanent")
    func notRetryableLeavesScheduleAlone() {
        let original = entry(attempts: 2)
        let updated = fail(original, http(503, UpstreamFailure(code: "msgraph_not_bootstrapped", retryable: false)))
        #expect(updated.permanentlyFailed == false)
        #expect(updated.attempts == original.attempts)
        #expect(updated.next_attempt_at == original.next_attempt_at)
        #expect(updated.last_failure_code == "msgraph_not_bootstrapped")
    }

    @Test("permanent failures are marked and keep the code")
    func permanentIsMarked() {
        let updated = fail(entry(), http(422, UpstreamFailure(code: "invalid_manifest")))
        #expect(updated.permanentlyFailed)
        #expect(updated.last_failure_code == "invalid_manifest")
    }

    @Test("after a Whisper-down rejection the entry is rescheduled, keeps its audio and records the code")
    func whisperDownKeepsAudio() {
        let original = entry()
        let failure = UpstreamFailure(code: "whisper_unavailable", upstream: "whisper", retryable: true)
        let updated = fail(original, http(503, failure))
        #expect(updated.attempts == 1)
        #expect(updated.next_attempt_at > original.next_attempt_at)
        #expect(updated.permanentlyFailed == false)
        #expect(updated.last_failure_code == "whisper_unavailable")
        #expect(updated.audio_file_paths == original.audio_file_paths)
        #expect(updated.manifest.session_id == original.manifest.session_id)
    }

    @Test("a later failure without a code clears the stale one")
    func codelessFailureClearsCode() {
        var original = entry()
        original.last_failure_code = "whisper_unavailable"
        #expect(fail(original, URLError(.notConnectedToInternet)).last_failure_code == nil)
    }

    @Test("last_failure_code survives a JSON round trip")
    func roundTrip() throws {
        var original = entry()
        original.last_failure_code = "whisper_timeout"
        let data = try JSONEncoder().encode([original])
        let decoded = try JSONDecoder().decode([SessionUploader.QueueEntry].self, from: data)
        #expect(decoded.first?.last_failure_code == "whisper_timeout")
    }

    @Test("a queue file written before last_failure_code decodes with a nil code")
    func oldQueueFileDecodes() throws {
        // The oldest entry shape: only the five original keys, neither
        // `permanentlyFailed` nor `last_failure_code`.
        let manifest = try JSONSerialization.jsonObject(with: JSONEncoder().encode(entry().manifest))
        let oldEntry: [String: Any] = [
            "id": "2026-04-27T19:30:00+02:00",
            "manifest": manifest,
            "audio_file_paths": ["segments/s01.m4a": "~AppSupport/sessions/x/segments/s01.m4a"],
            "attempts": 3,
            "next_attempt_at": 767_000_000.0,
        ]
        let old = try JSONSerialization.data(withJSONObject: [oldEntry])

        let decoded = try JSONDecoder().decode([SessionUploader.QueueEntry].self, from: old)
        #expect(decoded.count == 1)
        #expect(decoded[0].last_failure_code == nil)
        #expect(decoded[0].permanentlyFailed == false)
        #expect(decoded[0].attempts == 3)
        #expect(decoded[0].audio_file_paths.count == 1)
    }

    @Test("nextDue skips paused and permanently failed entries until they are due")
    func nextDueSkipsPaused() {
        var paused = entry()
        paused.id = "paused"
        var permanent = entry()
        permanent.id = "permanent"
        permanent.permanentlyFailed = true
        var future = entry()
        future.id = "future"
        future.next_attempt_at = now.addingTimeInterval(60)
        let ready = { var e = entry(); e.id = "ready"; return e }()
        let queue = [paused, permanent, future, ready]

        #expect(SessionUploader.nextDue(in: queue, paused: ["paused"], now: now)?.id == "ready")
        // Lifting the pause (what `kick()` does) makes the entry due again.
        #expect(SessionUploader.nextDue(in: queue, paused: [], now: now)?.id == "paused")
        #expect(SessionUploader.nextDue(in: [permanent, future], paused: [], now: now) == nil)
    }
}
