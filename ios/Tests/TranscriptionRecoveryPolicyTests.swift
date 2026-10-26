import Foundation
import Testing
@testable import VoiceDiary

// Pure decision table for the "Erneut transkribieren" action of a failed
// segment (ADR 0005, 0007; PRD "Failed-Transcription Recovery"). The policy
// has no IO: it only maps what the app knows to hidden / disabled / enabled /
// in flight, and health coming back can only change the answer, never start
// an attempt.

private func action(
    _ segment: SegmentState,
    recoverable: Bool? = true,
    whisper: WhisperHealth = .ok,
    inFlight: Bool = false,
    sibling: Bool = false
) -> TranscriptionRecoveryAction {
    TranscriptionRecoveryPolicy.action(
        segment: segment, recoverable: recoverable, whisper: whisper,
        attemptInFlight: inFlight, siblingTranscribing: sibling)
}

@Suite("TranscriptionRecoveryPolicy")
struct TranscriptionRecoveryPolicyTests {
    @Test("enabled only for a recoverable failed segment with Whisper ok and nothing running")
    func enabled() {
        #expect(action(.failed) == .enabled)
    }

    @Test("disabled with the Whisper reason while Whisper is degraded, down or unknown",
          arguments: [WhisperHealth.degraded, .down, .unknown])
    func whisperNotOK(health: WhisperHealth) {
        #expect(action(.failed, whisper: health) == .disabled(.whisperNotReachable))
    }

    @Test("disabled with the sibling reason while another segment of the session is transcribing")
    func siblingRunning() {
        #expect(action(.failed, sibling: true) == .disabled(.siblingTranscribing))
    }

    @Test("Whisper health is judged before a running sibling")
    func whisperBeforeSibling() {
        #expect(action(.failed, whisper: .down, sibling: true) == .disabled(.whisperNotReachable))
    }

    @Test("in flight while this screen's attempt runs, whatever health says")
    func inFlight() {
        #expect(action(.failed, inFlight: true) == .inFlight)
        #expect(action(.transcribing, inFlight: true) == .inFlight)
        #expect(action(.failed, whisper: .down, inFlight: true) == .inFlight)
    }

    @Test("hidden for recoverable false and for an absent flag (older server)")
    func notRecoverable() {
        #expect(action(.failed, recoverable: false) == .hidden)
        #expect(action(.failed, recoverable: nil) == .hidden)
        #expect(action(.failed, recoverable: nil, whisper: .down, sibling: true) == .hidden)
    }

    @Test("hidden for processed, pending_analysis, transcribing and unknown segments, whatever the flag",
          arguments: [SegmentState.processed, .pendingAnalysis, .transcribing, .unknown],
          [true, false])
    func notFailed(segment: SegmentState, recoverable: Bool) {
        #expect(action(segment, recoverable: recoverable) == .hidden)
        #expect(action(segment, recoverable: nil) == .hidden)
    }

    @Test("Whisper coming back only changes the answer to enabled")
    func healthRecovery() {
        #expect(action(.failed, whisper: .down) == .disabled(.whisperNotReachable))
        #expect(action(.failed, whisper: .ok) == .enabled)
    }

    @Test("a /health entry maps to a typed state; anything but ok or degraded or down is unknown")
    func whisperHealthMapping() {
        #expect(WhisperHealth(upstreamState: "ok") == .ok)
        #expect(WhisperHealth(upstreamState: "degraded") == .degraded)
        #expect(WhisperHealth(upstreamState: "down") == .down)
        #expect(WhisperHealth(upstreamState: nil) == .unknown)
        #expect(WhisperHealth(upstreamState: "skipped") == .unknown)
        #expect(WhisperHealth(upstreamState: "") == .unknown)
    }
}
