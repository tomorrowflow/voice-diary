import Foundation
import Testing
@testable import VoiceDiary

// Pure classification of upload errors — no network. A 409 from
// POST /api/sessions means the session is already ingested (the original
// 2xx was lost), so it must be treated as success, not a permanent failure.

@Suite("UploadOutcome")
struct UploadOutcomeTests {
    private func http(_ status: Int) -> ServerClientError {
        .http(status: status, detail: "")
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
        #expect(UploadOutcome.classify(http(status)) == .retry)
    }

    @Test("non-HTTP errors are retryable")
    func nonHTTPErrors() {
        #expect(UploadOutcome.classify(ServerClientError.notConfigured) == .retry)
        #expect(UploadOutcome.classify(ServerClientError.decodingFailed("x")) == .retry)
        #expect(UploadOutcome.classify(URLError(.timedOut)) == .retry)
    }
}
