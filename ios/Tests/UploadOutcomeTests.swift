import Foundation
import Testing
@testable import VoiceDiary

// Pure classification of upload errors — no network. A 409 from
// POST /api/sessions means the session is already ingested (the original
// 2xx was lost), so it must be treated as success, not a permanent failure.
// `Retry-After` and `retryable` (ADR 0002) only refine the retryable cases.

@Suite("UploadOutcome")
struct UploadOutcomeTests {
    private func http(_ status: Int, failure: UpstreamFailure = UpstreamFailure()) -> ServerClientError {
        .http(status: status, detail: "", failure: failure)
    }

    @Test("409 is treated as already uploaded")
    func conflictIsUploaded() {
        #expect(UploadOutcome.classify(http(409)) == .uploaded)
    }

    @Test("400, 404 and 422 stay permanent", arguments: [400, 404, 422])
    func permanentStatuses(status: Int) {
        #expect(UploadOutcome.classify(http(status)) == .permanent)
    }

    @Test("401, 403, 408, 429 and 5xx stay retryable", arguments: [401, 403, 408, 429, 500, 502, 503])
    func retryableStatuses(status: Int) {
        #expect(UploadOutcome.classify(http(status)) == .retry(after: nil))
    }

    @Test("non-HTTP errors are retryable")
    func nonHTTPErrors() {
        #expect(UploadOutcome.classify(ServerClientError.notConfigured) == .retry(after: nil))
        #expect(UploadOutcome.classify(ServerClientError.decodingFailed("x")) == .retry(after: nil))
        #expect(UploadOutcome.classify(URLError(.timedOut)) == .retry(after: nil))
    }

    @Test("Retry-After is carried on retryable failures")
    func retryAfterIsCarried() {
        let failure = UpstreamFailure(code: "msgraph_rate_limited", retryable: true, retryAfter: 120)
        #expect(UploadOutcome.classify(http(429, failure: failure)) == .retry(after: 120))
    }

    @Test("retryable: false pauses instead of retrying or failing permanently", arguments: [401, 429, 500, 503])
    func notRetryablePauses(status: Int) {
        let failure = UpstreamFailure(code: "msgraph_not_bootstrapped", retryable: false, retryAfter: 30)
        #expect(UploadOutcome.classify(http(status, failure: failure)) == .paused)
    }

    @Test("retryable: true or absent keeps the default retry")
    func retryableTrueOrAbsent() {
        #expect(UploadOutcome.classify(http(503, failure: UpstreamFailure(retryable: true))) == .retry(after: nil))
        #expect(UploadOutcome.classify(http(503, failure: UpstreamFailure(code: "x"))) == .retry(after: nil))
    }

    @Test("409 and 400/404/422 ignore the failure fields", arguments: [400, 404, 422])
    func statusRulesWinOverGuidance(status: Int) {
        let failure = UpstreamFailure(retryable: false, retryAfter: 60)
        #expect(UploadOutcome.classify(http(status, failure: failure)) == .permanent)
        #expect(UploadOutcome.classify(http(409, failure: failure)) == .uploaded)
    }

    @Test("failureCode reads the contract code, nil without one")
    func failureCode() {
        #expect(UploadOutcome.failureCode(of: http(503, failure: UpstreamFailure(code: "whisper_unavailable")))
                == "whisper_unavailable")
        #expect(UploadOutcome.failureCode(of: http(503)) == nil)
        #expect(UploadOutcome.failureCode(of: URLError(.timedOut)) == nil)
    }
}
