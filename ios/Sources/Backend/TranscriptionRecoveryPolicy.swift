import Foundation

/// A segment's status as the server reports it (SPEC §10.5). The wire value
/// stays a string so an additive status never breaks decoding; anything the
/// app does not know is `.unknown`, which the Verlauf pill shows as
/// "Unknown" and which never offers an action.
public enum SegmentState: Equatable, Sendable {
    case processed
    case pendingAnalysis
    case transcribing
    case failed
    case unknown

    init(serverStatus: String) {
        switch serverStatus {
        case "processed": self = .processed
        case "pending_analysis": self = .pendingAnalysis
        case "transcribing": self = .transcribing
        case "failed": self = .failed
        default: self = .unknown
        }
    }
}

/// The last-known `/health` state of Whisper. Only `ok` counts as healthy:
/// degraded, down, absent and anything unrecognised all disable the action.
public enum WhisperHealth: Equatable, Sendable {
    case ok, degraded, down, unknown

    init(upstreamState: String?) {
        switch upstreamState {
        case "ok": self = .ok
        case "degraded": self = .degraded
        case "down": self = .down
        default: self = .unknown
        }
    }
}

/// What the screen shows for a failed segment's "Erneut transkribieren".
public enum TranscriptionRecoveryAction: Equatable, Sendable {
    /// No action: not a recoverable failed segment, or the server is older.
    case hidden
    /// Shown but not tappable, with the reason to explain.
    case disabled(DisabledReason)
    case enabled
    /// This screen's attempt is running ("Wird transkribiert…").
    case inFlight

    public enum DisabledReason: Equatable, Sendable {
        /// Whisper is degraded, down or its health is unknown.
        case whisperNotReachable
        /// Another segment of the session is being transcribed; the server
        /// runs one operation per session.
        case siblingTranscribing
    }
}

/// Pure decision for "may the user ask for this failed segment to be
/// transcribed again?" (ADR 0005, 0007; PRD "Failed-Transcription
/// Recovery"). No IO, in the style of `RetryAnalysisPolicy`.
///
/// Health gates the button, not the work: it can turn `disabled` into
/// `enabled` and never starts anything. Only a tap does.
public enum TranscriptionRecoveryPolicy {
    /// - Parameters:
    ///   - segment: the segment's server status.
    ///   - recoverable: the server's flag; nil from an older server.
    ///   - attemptInFlight: this screen has an attempt running for *this*
    ///     segment.
    ///   - siblingTranscribing: another segment of the session is
    ///     `transcribing`, or this screen is recovering another one.
    public static func action(
        segment: SegmentState,
        recoverable: Bool?,
        whisper: WhisperHealth,
        attemptInFlight: Bool,
        siblingTranscribing: Bool
    ) -> TranscriptionRecoveryAction {
        if attemptInFlight { return .inFlight }
        guard segment == .failed, recoverable == true else { return .hidden }
        guard whisper == .ok else { return .disabled(.whisperNotReachable) }
        if siblingTranscribing { return .disabled(.siblingTranscribing) }
        return .enabled
    }
}
