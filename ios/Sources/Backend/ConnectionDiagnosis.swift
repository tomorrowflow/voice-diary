import Foundation

/// User-friendly classification of any error coming out of `ServerClient`.
///
/// The raw `ServerClientError` / `URLError` / decode failure stringifies
/// poorly ("Error Domain=NSURLErrorDomain Code=-1004 …") which leaves the
/// user staring at jargon when Tailscale flaps or the server is offline.
/// `classify(_:)` maps each known shape to a short, actionable triple
/// (title, hint, detail) plus a `kind` so the UI can pick the right
/// primary action — Tailscale / connectivity issues take a "Tagesübersicht
/// erneut laden" refresh; missing server config takes a deeplink into
/// Settings.
public struct ConnectionDiagnosis: Equatable, Sendable {
    public enum Kind: Sendable {
        /// Server URL or bearer token missing → user must open Settings.
        case notConfigured
        /// Tailscale / network couldn't reach the server (DNS, connection
        /// refused, host down). Refreshing once Tailscale is back works.
        case unreachable
        /// Device isn't connected to any network at all.
        case offline
        /// Connection established but server didn't answer in time.
        case timeout
        /// Server returned an authentication error (401 / 403). Likely a
        /// rotated bearer token — Settings again.
        case unauthorised
        /// Server returned 5xx. Refresh might help once the server recovers.
        case serverError
        /// Server returned a 4xx other than auth.
        case clientError
        /// Server replied with something we couldn't parse.
        case malformedResponse
        /// Anything we couldn't classify — fall back to the raw string.
        case unknown
    }

    public let kind: Kind
    public let title: String
    public let hint: String
    /// Optional precise technical detail (HTTP status, URLError code,
    /// raw NSError message). Shown in monospaced caption under the hint
    /// for diagnostics — never load-bearing.
    public let detail: String?
    public let systemImage: String

    public init(
        kind: Kind,
        title: String,
        hint: String,
        detail: String?,
        systemImage: String
    ) {
        self.kind = kind
        self.title = title
        self.hint = hint
        self.detail = detail
        self.systemImage = systemImage
    }

    /// Map any error from `ServerClient` calls to a structured diagnosis.
    /// Strings are German because the front rail of the app is German;
    /// English copy is kept symmetrical so a future locale switch is a
    /// table swap, not a rewrite.
    public static func classify(_ error: Error) -> ConnectionDiagnosis {
        if let serverError = error as? ServerClientError {
            return classify(serverError)
        }
        if let urlError = error as? URLError {
            return classify(urlError)
        }
        // Decode errors not wrapped by ServerClientError (e.g. the local
        // `JSONDecoder().decode(TodayCalendarResponse.self, ...)` after a
        // 200 OK with the wrong shape) land here.
        if error is DecodingError {
            return ConnectionDiagnosis(
                kind: .malformedResponse,
                title: "Antwort vom Server konnte nicht gelesen werden",
                hint: "Der Server hat geantwortet, aber das Format passt nicht zur App. Prüfe, ob Server und App auf der gleichen Version sind.",
                detail: String(describing: error),
                systemImage: "questionmark.circle.fill"
            )
        }
        return ConnectionDiagnosis(
            kind: .unknown,
            title: "Unerwarteter Fehler",
            hint: "Versuche es noch einmal. Wenn der Fehler bleibt, prüfe Tailscale und die Server-Einstellungen.",
            detail: String(describing: error),
            systemImage: "exclamationmark.triangle.fill"
        )
    }

    private static func classify(_ error: ServerClientError) -> ConnectionDiagnosis {
        switch error {
        case .notConfigured:
            return ConnectionDiagnosis(
                kind: .notConfigured,
                title: "Server noch nicht eingerichtet",
                hint: "Trage in den Einstellungen die Server-URL und das Bearer-Token ein, dann lädt die Tagesübersicht.",
                detail: nil,
                systemImage: "gearshape.fill"
            )
        case .http(let status, let detail):
            switch status {
            case 401, 403:
                return ConnectionDiagnosis(
                    kind: .unauthorised,
                    title: "Anmeldung am Server abgelehnt",
                    hint: "Das Bearer-Token wird vom Server nicht akzeptiert. Erzeuge in den Server-Einstellungen ein neues Token und trage es in den Einstellungen ein.",
                    detail: "HTTP \(status): \(detail.prefix(160))",
                    systemImage: "lock.trianglebadge.exclamationmark.fill"
                )
            case 500..<600:
                return ConnectionDiagnosis(
                    kind: .serverError,
                    title: "Server-Fehler",
                    hint: "Der Server hat die Anfrage nicht abschließen können. Schau in die Logs auf dem Server und versuche es danach erneut.",
                    detail: "HTTP \(status): \(detail.prefix(160))",
                    systemImage: "server.rack"
                )
            default:
                return ConnectionDiagnosis(
                    kind: .clientError,
                    title: "Anfrage abgelehnt",
                    hint: "Der Server hat die Anfrage zurückgewiesen. Häufigste Ursache: ein veralteter Endpunkt. Prüfe die Server-Version.",
                    detail: "HTTP \(status): \(detail.prefix(160))",
                    systemImage: "exclamationmark.octagon.fill"
                )
            }
        case .decodingFailed(let msg):
            return ConnectionDiagnosis(
                kind: .malformedResponse,
                title: "Antwort vom Server konnte nicht gelesen werden",
                hint: "Der Server hat geantwortet, aber das Format passt nicht zur App. Prüfe, ob Server und App auf der gleichen Version sind.",
                detail: msg,
                systemImage: "questionmark.circle.fill"
            )
        case .missingFile(let url):
            return ConnectionDiagnosis(
                kind: .unknown,
                title: "Datei fehlt",
                hint: "Eine lokale Datei für den Upload wurde nicht gefunden. Starte die App neu, um den Cache zu reparieren.",
                detail: url.path,
                systemImage: "doc.questionmark"
            )
        }
    }

    private static func classify(_ error: URLError) -> ConnectionDiagnosis {
        let detail = "URLError \(error.errorCode): \(error.localizedDescription)"
        switch error.code {
        case .notConnectedToInternet:
            return ConnectionDiagnosis(
                kind: .offline,
                title: "Kein Netzwerk",
                hint: "Das Gerät ist gerade nicht im Netz. Sobald WLAN oder Mobilfunk wieder steht, lädt die Tagesübersicht.",
                detail: detail,
                systemImage: "wifi.slash"
            )
        case .cannotFindHost, .dnsLookupFailed:
            return ConnectionDiagnosis(
                kind: .unreachable,
                title: "Server nicht erreichbar",
                hint: "Der Tailscale-Hostname konnte nicht aufgelöst werden. Öffne die Tailscale-App und prüfe, ob die Verbindung steht.",
                detail: detail,
                systemImage: "antenna.radiowaves.left.and.right.slash"
            )
        case .cannotConnectToHost, .networkConnectionLost,
             .secureConnectionFailed, .resourceUnavailable:
            return ConnectionDiagnosis(
                kind: .unreachable,
                title: "Server nicht erreichbar",
                hint: "Tailscale ist da, aber der Server antwortet nicht. Prüfe, ob der Server-Container läuft und der Port stimmt.",
                detail: detail,
                systemImage: "antenna.radiowaves.left.and.right.slash"
            )
        case .timedOut:
            return ConnectionDiagnosis(
                kind: .timeout,
                title: "Server antwortet zu langsam",
                hint: "Die Verbindung steht, der Server reagiert aber nicht rechtzeitig. Häufig vorübergehend — versuche es gleich noch einmal.",
                detail: detail,
                systemImage: "clock.badge.exclamationmark.fill"
            )
        case .badURL, .unsupportedURL:
            return ConnectionDiagnosis(
                kind: .notConfigured,
                title: "Server-URL ungültig",
                hint: "Die in den Einstellungen hinterlegte Server-URL ist nicht korrekt. Prüfe Schema (http/https) und Tailnet-Hostname.",
                detail: detail,
                systemImage: "link.badge.plus"
            )
        case .userAuthenticationRequired:
            return ConnectionDiagnosis(
                kind: .unauthorised,
                title: "Anmeldung am Server abgelehnt",
                hint: "Das Bearer-Token wird vom Server nicht akzeptiert. Erzeuge in den Server-Einstellungen ein neues Token und trage es in den Einstellungen ein.",
                detail: detail,
                systemImage: "lock.trianglebadge.exclamationmark.fill"
            )
        default:
            return ConnectionDiagnosis(
                kind: .unreachable,
                title: "Verbindung zum Server fehlgeschlagen",
                hint: "Prüfe Tailscale, das WLAN und die Server-URL. Wenn die Verbindung wieder steht, lade die Tagesübersicht erneut.",
                detail: detail,
                systemImage: "antenna.radiowaves.left.and.right.slash"
            )
        }
    }
}
