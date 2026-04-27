import Foundation
import UniformTypeIdentifiers

// Multipart upload to POST /api/sessions plus thin GET helpers for /health,
// /today/calendar, etc. Intentionally URLSession-only — no Alamofire.

public enum ServerClientError: Error, CustomStringConvertible, Sendable {
    case notConfigured
    case http(status: Int, detail: String)
    case decodingFailed(String)
    case missingFile(URL)

    public var description: String {
        switch self {
        case .notConfigured:
            return "server URL or bearer token not set"
        case .http(let status, let detail):
            return "HTTP \(status): \(detail.prefix(200))"
        case .decodingFailed(let msg):
            return "decode error: \(msg)"
        case .missingFile(let url):
            return "missing file: \(url.path)"
        }
    }
}

public actor ServerClient {
    public static let shared = ServerClient()

    private let session: URLSession

    public init() {
        let config = URLSessionConfiguration.default
        // 90 s of idle is enough headroom for Tailscale handshakes plus the
        // server's synchronous parts (ffmpeg + Whisper). The actual session
        // ingest endpoint returns 202 immediately and processing happens in
        // a background task on the server; iOS polls for status if needed.
        config.timeoutIntervalForRequest = 90
        config.timeoutIntervalForResource = 600
        // The SessionUploader queue handles retry, so we don't need
        // URLSession to spin waiting for connectivity itself — fail fast
        // and let the queue reschedule with backoff.
        config.waitsForConnectivity = false
        self.session = URLSession(configuration: config)
    }

    deinit {
        session.invalidateAndCancel()
    }

    private func config() throws -> (URL, String) {
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

    public func todayCalendar(date: String) async throws -> Data {
        let (url, token) = try endpoint("/today/calendar")
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "date", value: date)]
        var req = URLRequest(url: components.url!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: req)
        try Self.assertOK(response: response, body: data)
        return data
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

        let body = try await Self.makeMultipartBody(
            manifest: manifest,
            audioFiles: audioFiles,
            boundary: boundary
        )

        let (data, response) = try await session.upload(for: req, from: body)
        try Self.assertOK(response: response, body: data)
        do {
            return try JSONDecoder().decode(SessionAccepted.self, from: data)
        } catch {
            throw ServerClientError.decodingFailed("\(error)")
        }
    }

    // --- helpers -------------------------------------------------------

    private static func assertOK(response: URLResponse, body: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            // FastAPI's default error shape is `{"detail": "..."}`; pull
            // that out when present so logs and UI show the precise code
            // instead of a JSON blob.
            let detail: String
            if let obj = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
               let d = obj["detail"] as? String {
                detail = d
            } else {
                detail = String(data: body, encoding: .utf8) ?? "<binary>"
            }
            throw ServerClientError.http(status: http.statusCode, detail: detail)
        }
    }

    private static func makeMultipartBody(
        manifest: Manifest,
        audioFiles: [String: URL],
        boundary: String
    ) async throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let manifestJSON = try encoder.encode(manifest)

        var data = Data()
        let boundaryLine = "--\(boundary)\r\n".data(using: .utf8)!
        let endBoundary = "--\(boundary)--\r\n".data(using: .utf8)!

        // manifest part
        data.append(boundaryLine)
        data.append(
            "Content-Disposition: form-data; name=\"manifest\"; filename=\"manifest.json\"\r\n".data(using: .utf8)!
        )
        data.append("Content-Type: application/json\r\n\r\n".data(using: .utf8)!)
        data.append(manifestJSON)
        data.append("\r\n".data(using: .utf8)!)

        // audio parts
        for (fieldName, fileURL) in audioFiles {
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                throw ServerClientError.missingFile(fileURL)
            }
            let fileData = try Data(contentsOf: fileURL, options: .mappedIfSafe)
            let baseName = fileURL.lastPathComponent
            let mime = mimeType(for: fileURL)
            data.append(boundaryLine)
            data.append(
                "Content-Disposition: form-data; name=\"\(fieldName)\"; filename=\"\(baseName)\"\r\n".data(using: .utf8)!
            )
            data.append("Content-Type: \(mime)\r\n\r\n".data(using: .utf8)!)
            data.append(fileData)
            data.append("\r\n".data(using: .utf8)!)
        }

        data.append(endBoundary)
        return data
    }

    private static func mimeType(for url: URL) -> String {
        if let type = UTType(filenameExtension: url.pathExtension),
           let mime = type.preferredMIMEType {
            return mime
        }
        return "application/octet-stream"
    }
}
