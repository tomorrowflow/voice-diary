import Foundation

/// Pure decision for "should the app ask the server to retry this
/// session's analysis?" (SPEC §10.6.1, PRD "Upstream Failure Handling").
/// No IO, in the style of `TTSFallbackPolicy`.
///
/// A session qualifies only when a segment is `pending_analysis` with an
/// `analysis_pending` error *and* the server reports both Ollama and
/// LightRAG `ok`, and Blindfold `ok` whenever `/health` has a `blindfold`
/// entry (the analysis is routed there) — retrying into a dead upstream
/// would only rewrite the same error. No entry (default route, older
/// server) leaves the decision unchanged. Segments that `failed` before transcription are never
/// retried this way: there is no transcript to analyse.
public enum RetryAnalysisPolicy {
    /// `/health` upstream names the analysis and ingest stages depend on.
    static let requiredUpstreams = ["ollama", "lightrag"]

    static let pendingStatus = "pending_analysis"
    static let pendingErrorPrefix = "analysis_pending:"

    /// How far back locally known sessions are considered.
    static let lookback: TimeInterval = 14 * 24 * 60 * 60

    /// Present in `/health` only when the analysis route is Blindfold.
    static let routedUpstream = FailureCatalog.Upstream.blindfold.rawValue

    /// Both analysis upstreams answer `ok`, and so does Blindfold when
    /// it is reported at all.
    static func upstreamsHealthy(_ upstream: [String: String]) -> Bool {
        requiredUpstreams.allSatisfy { upstream[$0] == "ok" }
            && (upstream[routedUpstream] ?? "ok") == "ok"
    }

    public static func shouldRetry(
        segments: [ServerClient.SessionStatusResponse.SegmentStatus],
        upstream: [String: String]
    ) -> Bool {
        guard upstreamsHealthy(upstream) else { return false }
        return segments.contains { segment in
            segment.status == pendingStatus
                && (segment.error?.hasPrefix(pendingErrorPrefix) ?? false)
        }
    }

    /// True for the responses a retry attempt expects when it lost a
    /// race: another run is in flight (`session_busy`), the session has
    /// nothing left to retry (`session_not_retryable`), or the server
    /// forgot it. They are skipped without any user-visible error.
    static func isExpectedSkip(_ error: any Error) -> Bool {
        guard case ServerClientError.http(let status, let detail, _) = error else { return false }
        switch status {
        case 409: return detail == "session_busy" || detail == "session_not_retryable"
        case 404: return true
        default: return false
        }
    }

    /// Whether a session captured at `capturedAt` is recent enough.
    static func isRecent(_ capturedAt: Date, now: Date) -> Bool {
        now.timeIntervalSince(capturedAt) <= lookback
    }
}
