import Foundation

/// What `ServerSettingsView` shows for the server connection: one pure
/// projection of "is a valid URL saved" and the last `Reachability.Status`.
/// It never probes and never reads Keychain. The view maps `state` to its
/// localized label and theme colour.
struct ServerConnectionPresentation: Equatable, Sendable {

    /// The payload-free shape of the effective status, for label and colour.
    enum State: Equatable, Sendable {
        case unknown, ok, degraded, authInvalid, down
    }

    /// Nothing is configured until a valid URL has been saved, so a "down"
    /// from probing an empty Keychain would only mislead: an unsaved URL
    /// reads as `.unknown` whatever the probe said. Otherwise the probe
    /// status, payload and reason included.
    let effectiveStatus: Reachability.Status

    init(hasSavedURL: Bool, probeStatus: Reachability.Status) {
        effectiveStatus = hasSavedURL ? probeStatus : .unknown
    }

    var state: State {
        switch effectiveStatus {
        case .unknown: return .unknown
        case .ok: return .ok
        case .degraded: return .degraded
        case .authInvalid: return .authInvalid
        case .down: return .down
        }
    }

    /// Whether the first-run setup offers "Continue" rather than
    /// "Set up later".
    var isConnected: Bool {
        switch state {
        case .ok, .degraded: return true
        case .unknown, .authInvalid, .down: return false
        }
    }
}
