import Foundation
import Testing
@testable import VoiceDiary

// `ServerClient.retryTranscription` and the status decode it relies on
// (FTR-02 contract, ADR 0007). Runs through a `URLProtocol` stub with fixed
// credentials, so no server or Keychain is involved.

private final class RecoveryStubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var status = 202
    nonisolated(unsafe) static var headers: [String: String] = [:]
    nonisolated(unsafe) static var body = "{}"
    nonisolated(unsafe) static var failure: (any Error)?
    nonisolated(unsafe) static var requests: [URLRequest] = []

    static func reset() {
        status = 202
        headers = [:]
        body = "{}"
        failure = nil
        requests = []
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requests.append(request)
        if let failure = Self.failure {
            client?.urlProtocol(self, didFailWithError: failure)
            return
        }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: Self.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(Self.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private let sessionID = "2026-10-24T18:00:00+02:00"

private let acceptedBody = """
{"session_id": "2026-10-24T18:00:00+02:00", "received_at": "2026-10-24T16:00:00Z", "state": "processing",
 "segments": [
   {"segment_id": "s01", "status": "processed", "transcript_id": 41},
   {"segment_id": "s02", "status": "transcribing", "transcript_id": null}]}
"""

@Suite("Transcription recovery client", .serialized)
struct TranscriptionRecoveryClientTests {
    private func makeClient() -> ServerClient {
        RecoveryStubProtocol.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RecoveryStubProtocol.self]
        return ServerClient(
            session: URLSession(configuration: config),
            credentials: { (URL(string: "http://stub.invalid")!, "tok") })
    }

    /// The thrown error of a request the stub answers with `status`.
    private func refusal(
        _ status: Int, body: String, headers: [String: String] = [:]
    ) async -> TranscriptionRecoveryRefusal? {
        let client = makeClient()
        RecoveryStubProtocol.status = status
        RecoveryStubProtocol.body = body
        RecoveryStubProtocol.headers = headers
        do {
            _ = try await client.retryTranscription(sessionID: sessionID, segmentID: "s02")
            Issue.record("expected a throw for HTTP \(status)")
            return nil
        } catch {
            return TranscriptionRecoveryRefusal(error)
        }
    }

    // --- the 202 --------------------------------------------------------

    @Test("posts to the segment's retry-transcription route with the bearer token and decodes the 202")
    func accepted() async throws {
        let client = makeClient()
        RecoveryStubProtocol.body = acceptedBody
        let status = try await client.retryTranscription(sessionID: sessionID, segmentID: "s02")

        let request = try #require(RecoveryStubProtocol.requests.first)
        #expect(RecoveryStubProtocol.requests.count == 1)
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
        #expect(status.state == "processing")
        #expect(status.segments.map(\.state) == [.processed, .transcribing])
        #expect(status.segments[1].transcript_id == nil)
    }

    // The session id is an ISO timestamp. The server looks the session up by
    // the id as the phone sent it in the manifest, after decoding the path
    // once. A percent-encoded id that is encoded again (`%253A`) decodes to
    // `18%3A00` and finds no session, so every route would answer 404.
    @Test("every session route decodes to the session id, never encoded twice")
    func sessionIDIsEncodedOnce() async throws {
        let client = makeClient()
        RecoveryStubProtocol.body = acceptedBody

        _ = try await client.retryTranscription(sessionID: sessionID, segmentID: "s02")
        _ = try await client.sessionStatus(sessionID: sessionID)
        _ = try await client.retryAnalysis(sessionID: sessionID)

        let urls = RecoveryStubProtocol.requests.compactMap(\.url)
        let wire = urls.compactMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.percentEncodedPath }
        #expect(wire.count == 3)
        #expect(wire.allSatisfy { !$0.contains("%25") })
        #expect(urls.map(\.path) == [
            "/api/sessions/2026-10-24T18:00:00+02:00/segments/s02/retry-transcription",
            "/api/sessions/2026-10-24T18:00:00+02:00/status",
            "/api/sessions/2026-10-24T18:00:00+02:00/retry-analysis",
        ])
    }

    @Test("a segment id with a slash stays one path component")
    func segmentIDWithSlash() async throws {
        let client = makeClient()
        RecoveryStubProtocol.body = acceptedBody

        _ = try await client.retryTranscription(sessionID: sessionID, segmentID: "s/02")

        let url = try #require(RecoveryStubProtocol.requests.first?.url)
        let wire = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath
        #expect(wire?.hasSuffix("/segments/s%2F02/retry-transcription") == true)
    }

    // --- the request errors ---------------------------------------------

    @Test("404 session_not_found and segment_not_found decode")
    func notFound() async {
        #expect(await refusal(404, body: #"{"detail": "session_not_found"}"#) == .sessionNotFound)
        #expect(await refusal(404, body: #"{"detail": "segment_not_found"}"#) == .segmentNotFound)
    }

    @Test("409 segment_not_failed, segment_audio_missing and session_busy decode")
    func conflicts() async {
        #expect(await refusal(409, body: #"{"detail": "segment_not_failed"}"#) == .segmentNotFailed)
        #expect(await refusal(409, body: #"{"detail": "segment_audio_missing"}"#) == .segmentAudioMissing)
        #expect(await refusal(409, body: #"{"detail": "session_busy"}"#) == .sessionBusy)
    }

    @Test("503 whisper_unavailable decodes from the shared failure shape, with Retry-After")
    func whisperUnavailable() async {
        let body = #"{"detail": "whisper_unavailable", "code": "whisper_unavailable", "upstream": "whisper", "retryable": true}"#
        #expect(await refusal(503, body: body, headers: ["Retry-After": "30"])
                == .whisperUnavailable(retryAfter: 30))
        #expect(await refusal(503, body: body) == .whisperUnavailable(retryAfter: nil))
    }

    @Test("the code is taken from the detail when the body has no code field, and may carry a message")
    func detailWithMessage() async {
        #expect(await refusal(503, body: #"{"detail": "whisper_unavailable: connection refused"}"#)
                == .whisperUnavailable(retryAfter: nil))
    }

    @Test("a code on the wrong status, an unknown code and other statuses are not refusals")
    func notARefusal() async {
        #expect(await refusal(500, body: #"{"detail": "boom"}"#) == nil)
        #expect(await refusal(502, body: "<html>bad gateway</html>") == nil)
        #expect(await refusal(409, body: #"{"detail": "something_new"}"#) == nil)
        #expect(await refusal(404, body: #"{"detail": "Not Found"}"#) == nil)
        #expect(await refusal(409, body: #"{"detail": "whisper_unavailable"}"#) == nil)
    }

    @Test("a timeout and a lost connection reach the caller as transport errors, not refusals")
    func transportErrors() async {
        for code in [URLError.Code.timedOut, .networkConnectionLost, .notConnectedToInternet] {
            let client = makeClient()
            RecoveryStubProtocol.failure = URLError(code)
            do {
                _ = try await client.retryTranscription(sessionID: sessionID, segmentID: "s02")
                Issue.record("expected a throw for \(code)")
            } catch {
                #expect((error as? URLError)?.code == code)
                #expect(TranscriptionRecoveryRefusal(error) == nil)
            }
        }
    }

    @Test("an unconfigured client throws before any request")
    func notConfigured() async {
        RecoveryStubProtocol.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RecoveryStubProtocol.self]
        let client = ServerClient(
            session: URLSession(configuration: config), credentials: { throw ServerClientError.notConfigured })
        await #expect(throws: ServerClientError.self) {
            _ = try await client.retryTranscription(sessionID: sessionID, segmentID: "s02")
        }
        #expect(RecoveryStubProtocol.requests.isEmpty)
    }

    // --- the status fields ----------------------------------------------

    @Test("the status decodes transcribing and recoverable, and the session state processing")
    func statusWithNewFields() async throws {
        let client = makeClient()
        RecoveryStubProtocol.status = 200
        RecoveryStubProtocol.body = """
        {"session_id": "a", "received_at": "t", "state": "processing", "segments": [
          {"segment_id": "s01", "status": "failed", "transcript_id": null, "error": "whisper read timed out",
           "code": "whisper_timeout", "upstream": "whisper", "recoverable": true},
          {"segment_id": "s02", "status": "failed", "transcript_id": null, "recoverable": false},
          {"segment_id": "s03", "status": "transcribing", "transcript_id": null}]}
        """
        let status = try #require(try await client.sessionStatus(sessionID: sessionID))
        #expect(status.segments.map(\.state) == [.failed, .failed, .transcribing])
        #expect(status.segments.map(\.recoverable) == [true, false, nil])
        #expect(status.segments[0].code == "whisper_timeout")
    }

    @Test("a status from an older server has no recoverable flag and no transcribing")
    func statusWithoutNewFields() async throws {
        let client = makeClient()
        RecoveryStubProtocol.status = 200
        RecoveryStubProtocol.body = """
        {"session_id": "a", "received_at": "t", "state": "partial", "segments": [
          {"segment_id": "s01", "status": "processed", "transcript_id": 1},
          {"segment_id": "s02", "status": "failed", "transcript_id": null, "error": "boom"},
          {"segment_id": "s03", "status": "pending_analysis", "transcript_id": 3, "error": "analysis_pending: x"}]}
        """
        let status = try #require(try await client.sessionStatus(sessionID: sessionID))
        #expect(status.segments.map(\.state) == [.processed, .failed, .pendingAnalysis])
        #expect(status.segments.allSatisfy { $0.recoverable == nil })
    }

    @Test("an unrecognised segment status maps to unknown and still decodes")
    func unknownStatusFallback() async throws {
        let client = makeClient()
        RecoveryStubProtocol.status = 200
        RecoveryStubProtocol.body = """
        {"session_id": "a", "received_at": "t", "state": "done", "segments": [
          {"segment_id": "s01", "status": "archived", "transcript_id": null, "recoverable": true}]}
        """
        let status = try #require(try await client.sessionStatus(sessionID: sessionID))
        #expect(status.segments[0].status == "archived")
        #expect(status.segments[0].state == .unknown)
        #expect(SegmentState(serverStatus: "") == .unknown)
    }
}
