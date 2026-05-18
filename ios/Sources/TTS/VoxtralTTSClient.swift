import Foundation

// Pure HTTP layer for the server-side Voxtral TTS proxy. Knows the
// `/api/tts/synthesize` wire format, owns timeouts, classifies failures
// into typed `VoxtralError`s, and hands back a WAV file URL.
//
// Deliberately knows nothing about `TTSEngine`, `AVAudioPlayer`, the
// walkthrough, or `VoicePreferences` — that lets future tests (slice
// out of scope for v1) drive this class with a `URLProtocol` stub.

public enum VoxtralError: Error, Sendable {
    /// No server URL or bearer token in Keychain — user has not onboarded.
    case notConfigured
    /// Server returned 401 — bearer is wrong or `IOS_BEARER_TOKEN` rotated.
    case unauthorized
    /// Server returned 400 with `unknown_voice` — vLLM does not know that voice id.
    case unknownVoice(detail: String)
    /// Server returned 503 (`voxtral_unavailable`) — vLLM is down or unreachable.
    case unavailable(detail: String)
    /// Server returned 504 (`voxtral_timeout`).
    case timeout(detail: String)
    /// Any other non-2xx (502, 4xx, 5xx).
    case serverError(status: Int, detail: String)
    /// Transport-level failure on the iOS side (no network, name resolution failed, …).
    case transport(underlying: Error)
    /// Response body could not be written to disk or had zero length.
    case decodeFailed(reason: String)
}

public struct VoxtralTTSClient: Sendable {
    public struct Request: Sendable {
        public let text: String
        public let language: String          // "DE" or "EN" — server validates
        public let voice: String             // bare vLLM voice id, no prefix
        public let responseFormat: String    // "wav" (default)

        public init(text: String, language: String, voice: String, responseFormat: String = "wav") {
            self.text = text
            self.language = language
            self.voice = voice
            self.responseFormat = responseFormat
        }
    }

    public let session: URLSession
    public let timeout: TimeInterval

    public init(session: URLSession = .shared, timeout: TimeInterval = 30) {
        self.session = session
        self.timeout = timeout
    }

    /// Synthesise on the server and write the returned audio to a temp
    /// file. The caller (engine) is responsible for playing and deleting
    /// the file. Returns the temp URL on success.
    public func synthesize(_ request: Request) async throws -> URL {
        guard let serverURL = KeychainStore.read(.serverURL),
              let baseURL = URL(string: serverURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              let bearer = KeychainStore.read(.bearerToken)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !bearer.isEmpty else {
            throw VoxtralError.notConfigured
        }

        let endpoint = baseURL.appending(path: "/api/tts/synthesize")
        var req = URLRequest(url: endpoint, timeoutInterval: timeout)
        req.httpMethod = "POST"
        req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("audio/wav", forHTTPHeaderField: "Accept")
        req.httpBody = try JSONEncoder().encode([
            "text": request.text,
            "language": request.language,
            "voice": request.voice,
            "response_format": request.responseFormat,
        ])

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            // URLSession's `URLError` for timeouts surfaces as
            // `.timedOut`; everything else is a generic transport failure.
            if let urlError = error as? URLError, urlError.code == .timedOut {
                throw VoxtralError.timeout(detail: urlError.localizedDescription)
            }
            throw VoxtralError.transport(underlying: error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw VoxtralError.decodeFailed(reason: "non-HTTP response")
        }

        switch http.statusCode {
        case 200..<300:
            guard !data.isEmpty else {
                throw VoxtralError.decodeFailed(reason: "empty body")
            }
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("voxtral-\(UUID().uuidString.prefix(8)).wav")
            do {
                try data.write(to: url, options: .atomic)
            } catch {
                throw VoxtralError.decodeFailed(reason: "write failed: \(error.localizedDescription)")
            }
            return url

        case 401:
            throw VoxtralError.unauthorized

        case 400:
            let detail = Self.extractDetail(data) ?? "bad request"
            if detail.lowercased().contains("unknown_voice") || detail.lowercased().contains("voice") {
                throw VoxtralError.unknownVoice(detail: detail)
            }
            throw VoxtralError.serverError(status: 400, detail: detail)

        case 503:
            throw VoxtralError.unavailable(detail: Self.extractDetail(data) ?? "voxtral unavailable")

        case 504:
            throw VoxtralError.timeout(detail: Self.extractDetail(data) ?? "voxtral timeout")

        default:
            throw VoxtralError.serverError(
                status: http.statusCode,
                detail: Self.extractDetail(data) ?? "status \(http.statusCode)"
            )
        }
    }

    private static func extractDetail(_ data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return String(data: data.prefix(300), encoding: .utf8)
        }
        if let detail = json["detail"] {
            if let s = detail as? String { return s }
            if let d = detail as? [String: Any], let s = d["detail"] as? String { return s }
            return String(describing: detail)
        }
        return String(describing: json)
    }
}
