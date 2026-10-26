import Foundation
import Testing
@testable import VoiceDiary

// What a Verlauf segment row says and offers for each recovery state (FTR-05,
// PROTO-1 option B). Pure: the copy, the pill override and the button come
// from the segment's server status and the recovery action; the SwiftUI row
// only draws them.

private func segment(
    _ status: String,
    recoverable: Bool? = true,
    code: String? = nil,
    upstream: String? = nil
) -> ServerClient.SessionStatusResponse.SegmentStatus {
    .init(segment_id: "s02", status: status, transcript_id: nil, error: nil,
          code: code, upstream: upstream, recoverable: recoverable)
}

private func make(
    _ segment: ServerClient.SessionStatusResponse.SegmentStatus,
    action: TranscriptionRecoveryAction,
    audioMissing: Bool = false,
    notice: TranscriptionRecoveryRefusal? = nil,
    language: OpenerLanguage = .de
) -> SegmentRecoveryPresentation? {
    SegmentRecoveryPresentation.make(
        segment: segment, action: action, audioMissing: audioMissing,
        notice: notice, language: language)
}

@Suite("SegmentRecoveryPresentation")
struct SegmentRecoveryPresentationTests {
    @Test("a recoverable failed row explains the safe recording and offers the enabled button")
    func failedEnabled() {
        let row = make(segment("failed"), action: .enabled)
        #expect(row?.body == "Transkription fehlgeschlagen. Die Aufnahme ist auf dem Server gesichert.")
        #expect(row?.tone == .failure)
        #expect(row?.isTranscribing == false)
        #expect(row?.button == .init(title: "Erneut transkribieren", isEnabled: true))
        #expect(row?.note == nil)
    }

    @Test("English copy for the failed row")
    func failedEnglish() {
        let row = make(segment("failed"), action: .enabled, language: .en)
        #expect(row?.body == "Transcription failed. The recording is safely stored on the server.")
        #expect(row?.button?.title == "Retry transcription")
    }

    @Test("Whisper not reachable disables the button and says why")
    func whisperDisabled() {
        let de = make(segment("failed"), action: .disabled(.whisperNotReachable))
        #expect(de?.button == .init(title: "Erneut transkribieren", isEnabled: false))
        #expect(de?.note == "Whisper ist gerade nicht erreichbar.")
        let en = make(segment("failed"), action: .disabled(.whisperNotReachable), language: .en)
        #expect(en?.note == "Whisper isn't reachable right now.")
    }

    @Test("a sibling transcribing disables the button and says so")
    func siblingRunning() {
        let de = make(segment("failed"), action: .disabled(.siblingTranscribing))
        #expect(de?.button?.isEnabled == false)
        #expect(de?.note == "Eine andere Aufnahme dieser Sitzung wird gerade transkribiert.")
        let en = make(segment("failed"), action: .disabled(.siblingTranscribing), language: .en)
        #expect(en?.note == "Another recording of this session is being transcribed.")
    }

    @Test("an attempt in flight shows the Transcribing pill and body, with no button, even before the status says so")
    func inFlight() {
        for status in ["failed", "transcribing"] {
            let de = make(segment(status), action: .inFlight)
            #expect(de?.isTranscribing == true)
            #expect(de?.body == "Die Aufnahme wird erneut transkribiert.")
            #expect(de?.tone == .neutral)
            #expect(de?.button == nil)
            #expect(de?.note == nil)
        }
        let en = make(segment("transcribing"), action: .inFlight, language: .en)
        #expect(en?.body == "The recording is being transcribed again.")
    }

    @Test("a segment the server says is transcribing keeps the in-flight look when this screen started no attempt")
    func transcribingFromServer() {
        let row = make(segment("transcribing", recoverable: nil), action: .hidden)
        #expect(row?.isTranscribing == true)
        #expect(row?.body == "Die Aufnahme wird erneut transkribiert.")
        #expect(row?.button == nil)
    }

    @Test("recoverable false says the recording is gone and shows no action")
    func audioGone() {
        let de = make(segment("failed", recoverable: false), action: .hidden)
        #expect(de?.body == "Die Aufnahme ist nicht mehr auf dem Server.")
        #expect(de?.tone == .failure)
        #expect(de?.button == nil)
        let en = make(segment("failed", recoverable: false), action: .hidden, language: .en)
        #expect(en?.body == "The recording is no longer on the server.")
    }

    @Test("a segment_audio_missing answer to a tap says the same")
    func audioMissingAfterTap() {
        let row = make(segment("failed"), action: .hidden, audioMissing: true)
        #expect(row?.body == "Die Aufnahme ist nicht mehr auf dem Server.")
        #expect(row?.button == nil)
    }

    @Test("an older server (no recoverable) leaves the row as it was")
    func olderServer() {
        #expect(make(segment("failed", recoverable: nil, code: "whisper_timeout", upstream: "whisper"),
                     action: .hidden) == nil)
    }

    @Test("processed and pending rows are left as they were")
    func otherStatuses() {
        #expect(make(segment("processed", recoverable: nil), action: .hidden) == nil)
        #expect(make(segment("pending_analysis", recoverable: nil), action: .hidden) == nil)
        #expect(make(segment("mystery", recoverable: nil), action: .hidden) == nil)
    }

    @Test("the latest failure reason stays visible under the body")
    func latestReason() {
        let row = make(segment("failed", code: "whisper_timeout", upstream: "whisper"), action: .enabled)
        #expect(row?.reason == "Transkription dauert zu lange")
        #expect(row?.body == "Transkription fehlgeschlagen. Die Aufnahme ist auf dem Server gesichert.")
    }

    @Test("a reason that only repeats the generic failure is dropped")
    func genericReasonDropped() {
        let row = make(segment("failed", code: "whisper_engine_error", upstream: "whisper"), action: .enabled)
        #expect(row?.reason == nil)
        #expect(make(segment("failed"), action: .enabled)?.reason == nil)
    }

    @Test("a refused tap leaves the button as it was and adds the reason as the note")
    func refusals() {
        let busy = make(segment("failed"), action: .enabled, notice: .sessionBusy)
        #expect(busy?.button?.isEnabled == true)
        #expect(busy?.note == "Eine andere Aufnahme dieser Sitzung wird gerade transkribiert.")
        let whisper = make(segment("failed"), action: .enabled, notice: .whisperUnavailable(retryAfter: nil))
        #expect(whisper?.note == "Whisper ist gerade nicht erreichbar.")
        // Not documented reasons: nothing extra to say, the next read settles it.
        #expect(make(segment("failed"), action: .enabled, notice: .segmentNotFound)?.note == nil)
        #expect(make(segment("failed"), action: .enabled, notice: .sessionNotFound)?.note == nil)
    }

    @Test("a disabled reason wins over a stale refusal note")
    func disabledReasonWins() {
        let row = make(segment("failed"), action: .disabled(.whisperNotReachable), notice: .sessionBusy)
        #expect(row?.note == "Whisper ist gerade nicht erreichbar.")
    }
}

@Suite("Transcribing pill label")
struct TranscribingPillLabelTests {
    @Test("German and English labels from the string catalog")
    func labels() {
        #expect(SegmentRecoveryPresentation.transcribingPillLabel(language: .de) == "Wird transkribiert…")
        #expect(SegmentRecoveryPresentation.transcribingPillLabel(language: .en) == "Transcribing…")
    }

    @Test("with no language it resolves through Bundle.main, which the app's language override swaps")
    func followsTheAppLanguage() {
        #expect(SegmentRecoveryPresentation.transcribingPillLabel()
                == Bundle.main.localizedString(forKey: "Transcribing…", value: "Transcribing…", table: nil))
    }
}

@Suite("WhisperHealth from /health")
struct WhisperHealthParsingTests {
    private func health(_ json: String) -> WhisperHealth {
        WhisperHealth(healthData: Data(json.utf8))
    }

    @Test("reads the whisper upstream state", arguments: [
        ("ok", WhisperHealth.ok), ("degraded", .degraded), ("down", .down), ("odd", .unknown),
    ])
    func states(raw: String, expected: WhisperHealth) {
        #expect(health(#"{"status":"ok","upstream":{"whisper":"\#(raw)","ollama":"ok"}}"#) == expected)
    }

    @Test("a missing entry or an unreadable body is unknown, which counts as not ok")
    func unknown() {
        #expect(health(#"{"upstream":{"ollama":"ok"}}"#) == .unknown)
        #expect(health(#"{"status":"ok"}"#) == .unknown)
        #expect(health("not json") == .unknown)
        #expect(WhisperHealth(healthData: nil) == .unknown)
    }
}
