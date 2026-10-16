import Foundation

/// What Mehr → Server says about sessions still waiting in the upload
/// queue (SPEC §10.6): how many, and why the latest attempt failed.
public struct PendingUploadSummary: Equatable, Sendable {
    public let count: Int
    /// The code of the last failed attempt of the oldest waiting session
    /// that has one. Nil when no waiting session failed with a code (not
    /// attempted yet, older server, network error).
    public let lastFailureCode: String?

    /// Summary of the queue, or nil when nothing is waiting. Permanently
    /// rejected entries are kept only for diagnostics and never upload, so
    /// they are not "waiting".
    public static func make(from entries: [SessionUploader.QueueEntry]) -> PendingUploadSummary? {
        let waiting = entries.filter { !$0.permanentlyFailed }
        guard !waiting.isEmpty else { return nil }
        return PendingUploadSummary(
            count: waiting.count,
            lastFailureCode: waiting.lazy.compactMap(\.last_failure_code).first
        )
    }

    /// Explanation of the last failure, nil when there is no code or it is
    /// not one the app knows. `language: nil` follows the app language.
    public func explanation(language: OpenerLanguage? = nil) -> FailureCopy? {
        guard let lastFailureCode else { return nil }
        return FailureCatalog.copy(for: UpstreamFailure(code: lastFailureCode), language: language)
    }
}
