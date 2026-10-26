import Foundation

// Multipart upload to POST /api/sessions plus thin GET helpers for /health,
// /today/calendar, etc. Intentionally URLSession-only — no Alamofire.

public enum ServerClientError: Error, CustomStringConvertible, Sendable {
    case notConfigured
    /// `failure` carries the additive contract fields (`code`, `upstream`,
    /// `retryable`, `Retry-After`); all nil when the server predates them.
    case http(status: Int, detail: String, failure: UpstreamFailure = UpstreamFailure())
    case decodingFailed(String)
    case missingFile(URL)

    public var description: String {
        switch self {
        case .notConfigured:
            return "server URL or bearer token not set"
        case .http(let status, let detail, _):
            return "HTTP \(status): \(detail.prefix(200))"
        case .decodingFailed(let msg):
            return "decode error: \(msg)"
        case .missingFile(let url):
            return "missing file: \(url.path)"
        }
    }
}

extension ServerClientError {
    /// Build the `.http` error for a non-2xx response. FastAPI's default
    /// error shape is `{"detail": "..."}`; pull that out when present so
    /// logs and UI show the precise code instead of a JSON blob. The
    /// contract fields (`code`, `upstream`, `retryable`, `Retry-After`)
    /// ride along in `failure`.
    static func http(from response: HTTPURLResponse, body: Data) -> ServerClientError {
        let detail: String
        if let obj = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
           let d = obj["detail"] as? String {
            detail = d
        } else {
            detail = String(data: body, encoding: .utf8) ?? "<binary>"
        }
        let failure = UpstreamFailure.parse(
            body: body,
            retryAfterHeader: response.value(forHTTPHeaderField: "Retry-After")
        )
        return .http(status: response.statusCode, detail: detail, failure: failure)
    }
}

public actor ServerClient {
    public static let shared = ServerClient()

    private let session: URLSession
    private let credentials: @Sendable () throws -> (URL, String)

    public init() {
        self.init(session: Self.makeSession())
    }

    /// Test seam: lets tests inject a session backed by a `URLProtocol` stub
    /// and the server URL and token to use instead of the Keychain's.
    init(
        session: URLSession,
        credentials: @escaping @Sendable () throws -> (URL, String) = ServerClient.keychainCredentials
    ) {
        self.session = session
        self.credentials = credentials
    }

    private static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.default
        // 90 s of idle is enough headroom for Tailscale handshakes plus the
        // server's synchronous parts (ffmpeg + Whisper). The actual session
        // ingest endpoint returns 202 immediately and processing happens in
        // a background task on the server; iOS polls for status if needed.
        config.timeoutIntervalForRequest = 90
        config.timeoutIntervalForResource = Self.longRequestTimeout
        // The SessionUploader queue handles retry, so we don't need
        // URLSession to spin waiting for connectivity itself — fail fast
        // and let the queue reschedule with backoff.
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }

    deinit {
        session.invalidateAndCancel()
    }

    private func config() throws -> (URL, String) {
        try credentials()
    }

    private static func keychainCredentials() throws -> (URL, String) {
        guard let urlString = KeychainStore.read(.serverURL),
              let url = URL(string: urlString),
              let token = KeychainStore.read(.bearerToken),
              !token.isEmpty else {
            throw ServerClientError.notConfigured
        }
        return (url, token)
    }

    private func endpoint(_ path: String) throws -> (URL, String) {
        let (base, token) = try config()
        return (base.appending(path: path), token)
    }

    // --- /health (no auth required) -------------------------------------

    public func health() async throws -> Data {
        guard let urlString = KeychainStore.read(.serverURL),
              let url = URL(string: urlString) else {
            throw ServerClientError.notConfigured
        }
        let req = URLRequest(url: url.appending(path: "/health"))
        let (data, response) = try await session.data(for: req)
        try Self.assertOK(response: response, body: data)
        return data
    }

    // --- /today/calendar -----------------------------------------------

    public static let defaultRSVPFilter = "accepted,organizer"

    /// Fetches the calendar events for `date`. `rsvpFilter` is a comma-
    /// separated list of `accepted` / `tentative` / `declined` /
    /// `not_responded` / `organizer` / `none`. Default narrows to
    /// **only the meetings you actively committed to** — events you
    /// organised yourself plus invites you explicitly accepted. The
    /// walkthrough therefore skips tentative invites you typically
    /// don't attend.
    public func todayCalendar(
        date: String,
        rsvpFilter: String = ServerClient.defaultRSVPFilter
    ) async throws -> Data {
        let (url, token) = try endpoint("/today/calendar")
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw ServerClientError.notConfigured
        }
        components.queryItems = [
            URLQueryItem(name: "date", value: date),
            URLQueryItem(name: "rsvp_filter", value: rsvpFilter),
        ]
        guard let resolvedURL = components.url else {
            throw ServerClientError.notConfigured
        }
        var req = URLRequest(url: resolvedURL)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: req)
        try Self.assertOK(response: response, body: data)
        return data
    }

    public func calendarEvent(id: String) async throws -> Data {
        let (url, token) = try endpoint("/calendar/event/\(id)")
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: req)
        try Self.assertOK(response: response, body: data)
        return data
    }

    /// Distinct dates (yyyy-MM-dd, recording-target) that already have at
    /// least one transcript on the server. Used by the walkthrough date
    /// picker to mark days that have already been recorded for.
    public func recordedDates(from: String? = nil, to: String? = nil) async throws -> [String] {
        let (url, token) = try endpoint("/api/sessions/dates")
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw ServerClientError.notConfigured
        }
        var items: [URLQueryItem] = []
        if let from { items.append(URLQueryItem(name: "date_from", value: from)) }
        if let to   { items.append(URLQueryItem(name: "date_to", value: to)) }
        components.queryItems = items.isEmpty ? nil : items
        guard let resolvedURL = components.url else {
            throw ServerClientError.notConfigured
        }
        var req = URLRequest(url: resolvedURL)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: req)
        try Self.assertOK(response: response, body: data)
        struct Payload: Decodable { let dates: [String] }
        return try JSONDecoder().decode(Payload.self, from: data).dates
    }

    // --- enrichment ---------------------------------------------------

    public func emailSearch(query: String, responseLanguage: String = "de") async throws -> EnrichmentSummary {
        let (url, token) = try endpoint("/email/search")
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw ServerClientError.notConfigured
        }
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "response_language", value: responseLanguage),
        ]
        guard let resolvedURL = components.url else {
            throw ServerClientError.notConfigured
        }
        var req = URLRequest(url: resolvedURL)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: req)
        try Self.assertOK(response: response, body: data)
        return try Self.decode(EnrichmentSummary.self, from: data)
    }

    public func lightragQuery(
        query: String,
        responseLanguage: String = "de",
        mode: String = "naive"
    ) async throws -> EnrichmentSummary {
        let (url, token) = try endpoint("/lightrag/query")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "query": query,
            "mode": mode,
            "response_language": responseLanguage,
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: req)
        try Self.assertOK(response: response, body: data)
        return try Self.decode(EnrichmentSummary.self, from: data)
    }

    private static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw ServerClientError.decodingFailed("\(error)")
        }
    }

    // --- /api/sessions/{id}/status -------------------------------------

    /// Per-segment processing status for a previously-uploaded session.
    /// Returns `nil` when the server has no record (HTTP 404) — the
    /// status map is in-memory on the server, so a restart loses it
    /// even though the bundle on disk survives.
    public func sessionStatus(sessionID: String) async throws -> SessionStatusResponse? {
        let (url, token) = try sessionEndpoint(sessionID, "status")
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: req)
        if let http = response as? HTTPURLResponse, http.statusCode == 404 {
            return nil
        }
        try Self.assertOK(response: response, body: data)
        return try Self.decode(SessionStatusResponse.self, from: data)
    }

    /// Asks the server to re-run analysis for a `pending_analysis` session
    /// (SPEC §10.6.1). Returns the updated status; a retry that fails again
    /// still answers `200`. Throws `.http` for `409 session_busy` /
    /// `session_not_retryable` and `404`.
    public func retryAnalysis(sessionID: String) async throws -> SessionStatusResponse {
        let (url, token) = try sessionEndpoint(sessionID, "retry-analysis")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        // The server runs the whole analysis inside this request (Ollama
        // calls alone can take up to 120 s), so the shared 90 s idle
        // timeout would abandon a retry that is still working.
        req.timeoutInterval = Self.longRequestTimeout
        let (data, response) = try await session.data(for: req)
        try Self.assertOK(response: response, body: data)
        return try Self.decode(SessionStatusResponse.self, from: data)
    }

    /// Asks the server to transcribe one `failed` segment again from its
    /// retained audio (FTR-02, ADR 0005, 0007). The route answers `202` at
    /// once and runs the attempt in the background, so the default timeout
    /// applies; the outcome is read with `sessionStatus`. Throws `.http` for
    /// the request errors (see `TranscriptionRecoveryRefusal`); any other
    /// error, such as a timeout or a lost connection, leaves the outcome
    /// unknown.
    public func retryTranscription(sessionID: String, segmentID: String) async throws -> SessionStatusResponse {
        let (url, token) = try sessionEndpoint(sessionID, "segments", segmentID, "retry-transcription")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: req)
        try Self.assertOK(response: response, body: data)
        return try Self.decode(SessionStatusResponse.self, from: data)
    }

    /// The longest any request may run; also `timeoutIntervalForResource`.
    static let longRequestTimeout: TimeInterval = 600

    /// `/api/sessions/{id}/{parts…}`. Each part is percent-encoded exactly
    /// once by `appending(component:)` (an ISO8601 session id contains ':'),
    /// so the server decodes the path to the id the phone sent. Encoding a
    /// part first and then appending it would encode the '%' again, and the
    /// server would look up a session that does not exist.
    private func sessionEndpoint(_ sessionID: String, _ parts: String...) throws -> (URL, String) {
        let (base, token) = try config()
        let url = ([sessionID] + parts).reduce(base.appending(path: "/api/sessions")) {
            $0.appending(component: $1)
        }
        return (url, token)
    }

    public struct SessionStatusResponse: Codable, Sendable, Equatable {
        public let session_id: String
        public let received_at: String
        public let state: String         // "processing" | "done" | "failed" | "partial"
        public let segments: [SegmentStatus]

        public struct SegmentStatus: Codable, Sendable, Equatable {
            public let segment_id: String
            /// "processed" | "failed" | "pending_analysis" | "transcribing";
            /// read it through `state`, which maps anything else to `.unknown`.
            public let status: String
            public let transcript_id: Int?
            public let error: String?
            /// Failure contract fields (SPEC §10.5); set on `failed` and on
            /// `pending_analysis` segments left by an upstream outage. nil
            /// for processed segments, non-upstream errors and servers
            /// without them.
            public let code: String?
            public let upstream: String?
            /// Set on `failed` segments only: `true` while the manifest
            /// entry and the retained audio exist (ADR 0007). nil on other
            /// segments and on servers without it, which means no action.
            public let recoverable: Bool?

            public init(
                segment_id: String,
                status: String,
                transcript_id: Int?,
                error: String?,
                code: String?,
                upstream: String?,
                recoverable: Bool? = nil
            ) {
                self.segment_id = segment_id
                self.status = status
                self.transcript_id = transcript_id
                self.error = error
                self.code = code
                self.upstream = upstream
                self.recoverable = recoverable
            }

            public var state: SegmentState { SegmentState(serverStatus: status) }
        }
    }

    // --- /api/sessions multipart upload --------------------------------

    public func uploadSession(
        manifest: Manifest,
        audioFiles: [String: URL]   // multipart field name → on-disk URL
    ) async throws -> SessionAccepted {
        let (url, token) = try endpoint("/api/sessions")

        let boundary = "vd-" + UUID().uuidString
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue(
            "multipart/form-data; boundary=\(boundary)",
            forHTTPHeaderField: "Content-Type"
        )

        let (data, response) = try await sendMultipart(
            req,
            manifest: manifest,
            audioFiles: audioFiles,
            boundary: boundary
        )
        try Self.assertOK(response: response, body: data)
        do {
            return try JSONDecoder().decode(SessionAccepted.self, from: data)
        } catch {
            throw ServerClientError.decodingFailed("\(error)")
        }
    }

    /// Streams the multipart body from a temporary file and deletes that file
    /// once the upload finishes, fails or is cancelled.
    func sendMultipart(
        _ req: URLRequest,
        manifest: Manifest,
        audioFiles: [String: URL],
        boundary: String,
        bodyDirectory: URL = FileManager.default.temporaryDirectory
    ) async throws -> (Data, URLResponse) {
        let bodyURL = try await MultipartBodyFile.write(
            manifest: manifest,
            audioFiles: audioFiles,
            boundary: boundary,
            directory: bodyDirectory
        )
        defer { try? FileManager.default.removeItem(at: bodyURL) }
        return try await session.upload(for: req, fromFile: bodyURL)
    }

    // --- helpers -------------------------------------------------------

    /// Common shape returned by `/email/search` and `/lightrag/query`.
    public struct EnrichmentSummary: Codable, Sendable {
        public let summary: String
        public let response_language: String
        public let source_count: Int?
        public let raw_response: String?
    }

    private static func assertOK(response: URLResponse, body: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            throw ServerClientError.http(from: http, body: body)
        }
    }
}
