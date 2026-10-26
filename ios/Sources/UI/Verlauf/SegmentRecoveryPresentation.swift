import Foundation

/// What a Verlauf segment row says and offers for the transcription-recovery
/// states (FTR-05, PROTO-1 option B, ADR 0005/0007). Pure: it takes the
/// segment's server status and the action `TranscriptionRecoveryPolicy`
/// decided, and the SwiftUI row only draws the result. nil leaves the row to
/// its existing status-based explanation: processed and pending segments, and
/// a `failed` one from an older server (no `recoverable`), which gets no
/// action.
struct SegmentRecoveryPresentation: Equatable {
    enum Tone: Equatable {
        /// The destructive colour of a failed row.
        case failure
        /// A running attempt: no failure to flag.
        case neutral
    }

    struct Button: Equatable {
        let title: String
        let isEnabled: Bool
    }

    /// The pill reads "Transcribing…" instead of the status label.
    let isTranscribing: Bool
    let body: String
    let tone: Tone
    /// The latest failure reason, under the body; nil when the segment has
    /// none or it only repeats "Transcription failed".
    let reason: String?
    let button: Button?
    /// Why the button is disabled, or why the last tap did nothing.
    let note: String?

    static func make(
        segment: ServerClient.SessionStatusResponse.SegmentStatus,
        action: TranscriptionRecoveryAction,
        audioMissing: Bool,
        notice: TranscriptionRecoveryRefusal?,
        language: OpenerLanguage? = nil
    ) -> SegmentRecoveryPresentation? {
        func text(_ key: String) -> String { FailureCatalog.text(key, language) }

        switch segment.state {
        case .transcribing:
            return transcribing(text)
        case .failed:
            // The tap is on the wire: the pill follows it before the status does.
            if action == .inFlight { return transcribing(text) }
            if segment.recoverable == false || audioMissing {
                return SegmentRecoveryPresentation(
                    isTranscribing: false, body: text("The recording is no longer on the server."),
                    tone: .failure, reason: nil, button: nil, note: nil)
            }
            guard segment.recoverable == true else { return nil }
            let button: Button?
            let note: String?
            switch action {
            case .enabled:
                button = Button(title: text("Retry transcription"), isEnabled: true)
                note = notice.flatMap { noticeText($0, text) }
            case .disabled(let reason):
                button = Button(title: text("Retry transcription"), isEnabled: false)
                note = disabledText(reason, text)
            case .hidden, .inFlight:
                button = nil
                note = nil
            }
            return SegmentRecoveryPresentation(
                isTranscribing: false,
                body: text("Transcription failed. The recording is safely stored on the server."),
                tone: .failure,
                reason: reason(for: segment, text, language),
                button: button, note: note)
        case .processed, .pendingAnalysis, .unknown:
            return nil
        }
    }

    /// The status pill of a segment being transcribed again. Looked up with
    /// `FailureCatalog.text`, like the rest of this copy, because that goes
    /// through `Bundle.main.localizedString`, which the app's language
    /// setting swaps; `String(localized:)` would keep the system language
    /// when the app is forced to German on an English phone.
    static func transcribingPillLabel(language: OpenerLanguage? = nil) -> String {
        FailureCatalog.text("Transcribing…", language)
    }

    private static func transcribing(_ text: (String) -> String) -> SegmentRecoveryPresentation {
        SegmentRecoveryPresentation(
            isTranscribing: true, body: text("The recording is being transcribed again."),
            tone: .neutral, reason: nil, button: nil, note: nil)
    }

    private static func disabledText(
        _ reason: TranscriptionRecoveryAction.DisabledReason, _ text: (String) -> String
    ) -> String {
        switch reason {
        case .whisperNotReachable: return text("Whisper isn't reachable right now.")
        case .siblingTranscribing: return text("Another recording of this session is being transcribed.")
        }
    }

    /// `session_busy` means another operation holds the session, which the
    /// user can only read as "another recording is being transcribed". The
    /// refusals that say nothing new for the user get no note: the status
    /// read that follows them shows where the segment really is.
    private static func noticeText(
        _ refusal: TranscriptionRecoveryRefusal, _ text: (String) -> String
    ) -> String? {
        switch refusal {
        case .sessionBusy: return disabledText(.siblingTranscribing, text)
        case .whisperUnavailable: return disabledText(.whisperNotReachable, text)
        case .sessionNotFound, .segmentNotFound, .segmentNotFailed, .segmentAudioMissing: return nil
        }
    }

    private static func reason(
        for segment: ServerClient.SessionStatusResponse.SegmentStatus,
        _ text: (String) -> String,
        _ language: OpenerLanguage?
    ) -> String? {
        guard let title = FailureCatalog.segmentExplanation(
            status: segment.status, code: segment.code, upstream: segment.upstream, language: language
        ), title != text("Transcription failed") else { return nil }
        return title
    }
}
