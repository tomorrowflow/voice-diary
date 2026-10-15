import Foundation

/// The additive failure fields of a server error response (PRD "Upstream
/// Failure Handling", ADR 0002): top-level `code`, `upstream` and
/// `retryable` in the JSON body plus the `Retry-After` header. Every field
/// is optional because an older server sends none of them, which is
/// exactly the pre-contract behaviour.
public struct UpstreamFailure: Equatable, Sendable {
    public let code: String?
    public let upstream: String?
    public let retryable: Bool?
    /// `Retry-After` in seconds; nil when absent or not a non-negative
    /// number of seconds (the HTTP-date form is not used by the server).
    public let retryAfter: TimeInterval?

    public init(
        code: String? = nil,
        upstream: String? = nil,
        retryable: Bool? = nil,
        retryAfter: TimeInterval? = nil
    ) {
        self.code = code
        self.upstream = upstream
        self.retryable = retryable
        self.retryAfter = retryAfter
    }

    /// Read the contract fields out of an error body and `Retry-After`
    /// header value. Never throws: anything missing or mistyped is nil.
    public static func parse(body: Data, retryAfterHeader: String?) -> UpstreamFailure {
        let obj = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        return UpstreamFailure(
            code: nonEmpty(obj?["code"] as? String),
            upstream: nonEmpty(obj?["upstream"] as? String),
            retryable: obj?["retryable"] as? Bool,
            retryAfter: seconds(fromRetryAfter: retryAfterHeader)
        )
    }

    static func seconds(fromRetryAfter value: String?) -> TimeInterval? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespaces),
              let seconds = TimeInterval(trimmed),
              seconds.isFinite, seconds >= 0
        else { return nil }
        return seconds
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}
