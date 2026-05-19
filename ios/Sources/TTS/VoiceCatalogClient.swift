import Foundation

// Fetches the bundled Voxtral voice catalog from the server's
// `GET /api/tts/voices` endpoint and caches it in UserDefaults so
// Settings has something to show on offline launch.
//
// Refresh policy: `VoiceSettingsView.onAppear` kicks off a background
// refresh, so the cache stays warm without blocking the UI. Errors land
// in `lastError` and the UI surfaces an empty state with a retry button
// instead of a stuck spinner.

public struct VoxtralVoice: Codable, Identifiable, Sendable, Hashable {
    public let id: String
    public let language: String
    public let label: String
    public let description: String
    public let source: String?      // "bundled" | "librivox" | "user" — nil for pre-07a servers
    public let ref_text: String?

    public var voiceID: String { VoicePreferences.voxtralPrefix + id }

    /// User-recorded voices can be deleted from the picker; bundled
    /// and librivox-seeded ones can't.
    public var isUserDeletable: Bool { source == "user" }
}

public enum VoiceCatalogError: Error, Sendable {
    case notConfigured
    case unauthorized
    case audioTooLarge
    case audioFormat
    case voiceNotFound
    case serverError(status: Int, detail: String)
    case transport(underlying: Error)
    case decodeFailed(reason: String)
}

@MainActor
public final class VoiceCatalogClient: ObservableObject {
    public static let shared = VoiceCatalogClient()

    @Published public private(set) var voicesByLanguage: [String: [VoxtralVoice]] = [:]
    @Published public private(set) var lastError: String?
    @Published public private(set) var isLoading: Bool = false

    private let session: URLSession
    private let timeout: TimeInterval
    private let userDefaultsKey = "voicediary.tts.voxtral_voices_cache.v1"

    public init(session: URLSession = .shared, timeout: TimeInterval = 8) {
        self.session = session
        self.timeout = timeout
        self.voicesByLanguage = Self.loadCache(key: userDefaultsKey)
    }

    /// Returns voices for the given iOS language code ("de" / "en").
    /// Maps to the server's upper-case keys ("DE" / "EN") internally.
    public func voices(for iosLanguage: String) -> [VoxtralVoice] {
        let key = String(iosLanguage.prefix(2)).uppercased()
        return voicesByLanguage[key] ?? []
    }

    /// Refresh from the server. Safe to call repeatedly; concurrent
    /// callers see the same in-flight Task via the `isLoading` gate.
    public func refresh() async {
        guard !isLoading else { return }
        guard
            let serverURL = KeychainStore.read(.serverURL),
            let baseURL = URL(string: serverURL.trimmingCharacters(in: .whitespacesAndNewlines)),
            let bearer = KeychainStore.read(.bearerToken)?.trimmingCharacters(in: .whitespacesAndNewlines),
            !bearer.isEmpty
        else {
            lastError = "Server-URL oder Bearer fehlt — siehe Einstellungen → Server."
            return
        }

        isLoading = true
        lastError = nil
        defer { isLoading = false }

        var req = URLRequest(url: baseURL.appending(path: "/api/tts/voices"), timeoutInterval: timeout)
        req.httpMethod = "GET"
        req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                lastError = "Antwort ohne HTTP-Status."
                return
            }
            switch http.statusCode {
            case 200..<300:
                let decoded = try JSONDecoder().decode([String: [VoxtralVoice]].self, from: data)
                voicesByLanguage = decoded
                persistCache(decoded)
            case 401:
                lastError = "401 — Bearer stimmt nicht mit IOS_BEARER_TOKEN überein."
            case 503:
                lastError = "Voxtral-Sidecar ist gerade nicht erreichbar."
            default:
                lastError = "Server \(http.statusCode)."
            }
        } catch let urlError as URLError where urlError.code == .timedOut {
            lastError = "Zeitüberschreitung beim Laden der Stimmenliste."
        } catch {
            lastError = "Netzwerk-Fehler: \(error.localizedDescription)"
        }
    }

    // MARK: - Upload (slice 07b)

    /// POST a recorded WAV reference to `/api/tts/voices/custom` and
    /// refresh the local catalog on success. Throws a typed
    /// `VoiceCatalogError` so the recorder UI can surface specific
    /// failure modes.
    public func uploadCustomVoice(
        audio: URL,
        language: String,
        label: String,
        refText: String?
    ) async throws -> VoxtralVoice {
        let (baseURL, bearer) = try requireCredentials()
        let audioData: Data
        do {
            audioData = try Data(contentsOf: audio)
        } catch {
            throw VoiceCatalogError.transport(underlying: error)
        }

        let boundary = "vd-ref-" + UUID().uuidString
        var req = URLRequest(url: baseURL.appending(path: "/api/tts/voices/custom"))
        req.httpMethod = "POST"
        req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        body.append(field: "label", value: label, boundary: boundary)
        body.append(field: "language", value: language.uppercased(), boundary: boundary)
        body.append(field: "ref_text", value: refText ?? "", boundary: boundary)
        body.appendFile(
            field: "audio",
            filename: audio.lastPathComponent,
            mimeType: "audio/wav",
            data: audioData,
            boundary: boundary
        )
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.upload(for: req, from: body)
        } catch {
            throw VoiceCatalogError.transport(underlying: error)
        }

        let descriptor = try Self.decodeVoiceOrThrow(data: data, response: response)
        await refresh()
        return descriptor
    }

    /// DELETE a user-uploaded voice. Refresh on success. Server
    /// refuses deletes of bundled/librivox voices (403) — surface
    /// that as `.serverError` so the UI can show the reason.
    public func deleteCustomVoice(id: String) async throws {
        let (baseURL, bearer) = try requireCredentials()
        // Strip the `voxtral:` prefix if the caller passed in a
        // full voiceID — the server route expects the bare id.
        let bareID: String
        if id.hasPrefix(VoicePreferences.voxtralPrefix) {
            bareID = String(id.dropFirst(VoicePreferences.voxtralPrefix.count))
        } else {
            bareID = id
        }

        var req = URLRequest(url: baseURL.appending(path: "/api/tts/voices/custom/\(bareID)"))
        req.httpMethod = "DELETE"
        req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw VoiceCatalogError.transport(underlying: error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw VoiceCatalogError.decodeFailed(reason: "non-HTTP response")
        }
        switch http.statusCode {
        case 200..<300:
            await refresh()
        case 401:
            throw VoiceCatalogError.unauthorized
        case 404:
            throw VoiceCatalogError.voiceNotFound
        default:
            throw VoiceCatalogError.serverError(status: http.statusCode, detail: Self.extractDetail(data))
        }
    }

    // MARK: - Cache

    private func persistCache(_ voices: [String: [VoxtralVoice]]) {
        guard let data = try? JSONEncoder().encode(voices) else { return }
        UserDefaults.standard.set(data, forKey: userDefaultsKey)
    }

    private static func loadCache(key: String) -> [String: [VoxtralVoice]] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([String: [VoxtralVoice]].self, from: data) else {
            return [:]
        }
        return decoded
    }

    // MARK: - Internals

    private func requireCredentials() throws -> (URL, String) {
        guard
            let serverURL = KeychainStore.read(.serverURL),
            let baseURL = URL(string: serverURL.trimmingCharacters(in: .whitespacesAndNewlines)),
            let bearer = KeychainStore.read(.bearerToken)?.trimmingCharacters(in: .whitespacesAndNewlines),
            !bearer.isEmpty
        else {
            throw VoiceCatalogError.notConfigured
        }
        return (baseURL, bearer)
    }

    private static func decodeVoiceOrThrow(data: Data, response: URLResponse) throws -> VoxtralVoice {
        guard let http = response as? HTTPURLResponse else {
            throw VoiceCatalogError.decodeFailed(reason: "non-HTTP response")
        }
        switch http.statusCode {
        case 200..<300:
            do {
                return try JSONDecoder().decode(VoxtralVoice.self, from: data)
            } catch {
                throw VoiceCatalogError.decodeFailed(reason: error.localizedDescription)
            }
        case 401:
            throw VoiceCatalogError.unauthorized
        case 413:
            throw VoiceCatalogError.audioTooLarge
        case 400:
            let detail = extractDetail(data)
            if detail.contains("audio_format") || detail.lowercased().contains("wav") {
                throw VoiceCatalogError.audioFormat
            }
            throw VoiceCatalogError.serverError(status: 400, detail: detail)
        default:
            throw VoiceCatalogError.serverError(status: http.statusCode, detail: extractDetail(data))
        }
    }

    private static func extractDetail(_ data: Data) -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return String(data: data.prefix(300), encoding: .utf8) ?? ""
        }
        if let detail = json["detail"] {
            if let s = detail as? String { return s }
            if let d = detail as? [String: Any], let s = d["detail"] as? String { return s }
            return String(describing: detail)
        }
        return String(describing: json)
    }
}

// MARK: - Multipart helpers

private extension Data {
    mutating func append(field name: String, value: String, boundary: String) {
        append("--\(boundary)\r\n".data(using: .utf8)!)
        append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
        append(value.data(using: .utf8) ?? Data())
        append("\r\n".data(using: .utf8)!)
    }

    mutating func appendFile(
        field name: String,
        filename: String,
        mimeType: String,
        data: Data,
        boundary: String
    ) {
        append("--\(boundary)\r\n".data(using: .utf8)!)
        append(
            "Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n"
                .data(using: .utf8)!
        )
        append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
        append(data)
        append("\r\n".data(using: .utf8)!)
    }
}
