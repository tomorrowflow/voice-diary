import Foundation
import Testing
@testable import VoiceDiary

// ServerClientError.http reads the additive failure contract (ADR 0002):
// `code`, `upstream`, `retryable` in the body and `Retry-After` in the
// header. Old servers send none of them; every field must then be nil and
// `detail` must behave exactly as before.

@Suite("UpstreamFailureParsing")
struct UpstreamFailureParsingTests {
    private func error(
        status: Int,
        body: String,
        headers: [String: String] = [:]
    ) -> (detail: String, failure: UpstreamFailure, status: Int)? {
        let response = HTTPURLResponse(
            url: URL(string: "https://server.example/x")!,
            statusCode: status,
            httpVersion: nil,
            headerFields: headers
        )!
        guard case .http(let status, let detail, let failure) =
                ServerClientError.http(from: response, body: Data(body.utf8))
        else { return nil }
        return (detail, failure, status)
    }

    @Test("new body decodes detail, code, upstream and retryable")
    func newShape() throws {
        let e = try #require(error(status: 503, body: """
            {"detail":"whisper_unavailable: connection refused","code":"whisper_unavailable",\
            "upstream":"whisper","retryable":true}
            """))
        #expect(e.status == 503)
        #expect(e.detail == "whisper_unavailable: connection refused")
        #expect(e.failure == UpstreamFailure(
            code: "whisper_unavailable", upstream: "whisper", retryable: true, retryAfter: nil
        ))
    }

    @Test("old body keeps the detail string and leaves every new field nil")
    func oldShape() throws {
        let e = try #require(error(status: 502, body: #"{"detail":"rate_limited: backoff_exhausted"}"#))
        #expect(e.detail == "rate_limited: backoff_exhausted")
        #expect(e.failure == UpstreamFailure())
    }

    @Test("a non-JSON body is the detail and carries no failure fields")
    func plainBody() throws {
        let e = try #require(error(status: 500, body: "Internal Server Error"))
        #expect(e.detail == "Internal Server Error")
        #expect(e.failure == UpstreamFailure())
    }

    @Test("mistyped fields are ignored")
    func mistypedFields() throws {
        let e = try #require(error(
            status: 503,
            body: #"{"detail":"x","code":7,"upstream":["a"],"retryable":"yes"}"#
        ))
        #expect(e.failure == UpstreamFailure())
    }

    @Test("Retry-After is parsed as seconds, case-insensitively")
    func retryAfterSeconds() throws {
        let e = try #require(error(
            status: 429,
            body: #"{"detail":"x","code":"msgraph_rate_limited","upstream":"msgraph","retryable":true}"#,
            headers: ["retry-after": "30"]
        ))
        #expect(e.failure.retryAfter == 30)
        #expect(e.failure.code == "msgraph_rate_limited")
    }

    @Test("Retry-After without a code still decodes")
    func retryAfterAlone() throws {
        let e = try #require(error(status: 429, body: #"{"detail":"slow down"}"#, headers: ["Retry-After": "5"]))
        #expect(e.failure == UpstreamFailure(retryAfter: 5))
    }

    @Test("Retry-After values that are not seconds are nil",
          arguments: ["", "soon", "-3", "Wed, 21 Oct 2026 07:28:00 GMT", "nan", "inf"])
    func retryAfterInvalid(value: String) throws {
        let e = try #require(error(status: 503, body: #"{"detail":"x"}"#, headers: ["Retry-After": value]))
        #expect(e.failure.retryAfter == nil)
    }
}
