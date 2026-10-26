import Foundation

/// The last error `ServerSettingsView` shows for a probe `Reachability.Status`:
/// a pure projection with no probing, Keychain or localization. The view owns
/// the localized copy for `.authentication`; `.down` carries the probe's own
/// reason verbatim, empty included.
enum ServerStatusError: Equatable, Sendable {
    case authentication
    case down(reason: String)

    /// `nil` clears the error: `ok`, `degraded` and `unknown` have none.
    init?(status: Reachability.Status) {
        switch status {
        case .authInvalid: self = .authentication
        case .down(let reason): self = .down(reason: reason)
        case .ok, .degraded, .unknown: return nil
        }
    }
}
