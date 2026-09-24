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

    public var voiceID: String { VoicePreferences.voxtralPrefix + id }
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
}
