import Foundation

// Classifies what the server's `/health` answer says about its voice
// service, for the "Server voices" block in `VoiceSettingsView`. Pure: the
// view keeps the localized copy and the Theme colors and maps each case to
// them.
//
// Only the `voxtral` upstream value decides between connected,
// unreachable and not configured, and only while the overall status is
// `ok` or `degraded`. Values are matched case-sensitively; a missing or
// unrecognized value is `unknown`, like every non-health status. Those
// differ only in their label: a bearer the server rejected and a server
// that did not answer each get their own.

enum ServerVoiceAvailability: Equatable {
    case connected
    case unreachable
    case notConfigured
    case unknown
    case bearerInvalid
    case serverUnreachable

    /// Color role of the status icon; the view resolves it to a Theme color.
    enum Tone: Equatable {
        case success
        case destructive
        case subdued
    }

    init(status: Reachability.Status) {
        switch status {
        case .ok(let upstream), .degraded(let upstream):
            switch upstream["voxtral"] {
            case "ok":      self = .connected
            case "down":    self = .unreachable
            case "skipped": self = .notConfigured
            default:        self = .unknown
            }
        case .authInvalid:
            self = .bearerInvalid
        case .down:
            self = .serverUnreachable
        case .unknown:
            self = .unknown
        }
    }

    var iconName: String {
        switch self {
        case .connected:     return "checkmark.circle.fill"
        case .unreachable:   return "exclamationmark.triangle.fill"
        case .notConfigured: return "minus.circle"
        case .unknown, .bearerInvalid, .serverUnreachable:
            return "questionmark.circle"
        }
    }

    var tone: Tone {
        switch self {
        case .connected:   return .success
        case .unreachable: return .destructive
        case .notConfigured, .unknown, .bearerInvalid, .serverUnreachable:
            return .subdued
        }
    }
}
