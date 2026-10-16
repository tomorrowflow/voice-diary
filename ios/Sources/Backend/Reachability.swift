import Foundation
import Network

// Pings only the Voice Diary server's `/health` endpoint, so an
// "unreachable" banner means specifically "the server is down" — not
// "no internet" generally.

@MainActor
public final class Reachability: ObservableObject {
    public enum Status: Sendable, Equatable {
        case unknown
        case ok(upstream: [String: String])
        case degraded(upstream: [String: String])
        case authInvalid                        // 401 from a bearer-gated route
        case down(reason: String)
    }

    @Published public private(set) var status: Status = .unknown
    /// Per-upstream probe results of the last `/health` answer, kept apart
    /// from `status` because the overall `down` (Postgres or Whisper)
    /// carries no per-upstream detail. Empty while the server is unknown or
    /// unreachable.
    @Published public private(set) var upstream: [String: String] = [:]

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "vd.reachability")

    public init() {
        monitor.pathUpdateHandler = { [weak self] _ in
            Task { await self?.refresh() }
        }
        monitor.start(queue: queue)
    }

    deinit { monitor.cancel() }

    public func refresh() async {
        // 1. Liveness — `/health` is unauthenticated by design (iOS pings
        // it pre-onboarding). A green response here only proves the
        // server is reachable.
        let probes: [String: String]
        let healthLevel: String
        do {
            let data = try await ServerClient.shared.health()
            let parsed = try JSONDecoder().decode(HealthResponse.self, from: data)
            probes = parsed.upstream
            healthLevel = parsed.status
        } catch {
            upstream = [:]
            status = .down(reason: "\(error)")
            return
        }
        upstream = probes

        // 2. Bearer validation — fire a cheap bearer-gated GET. A 200
        // means the bearer is correct; a 401 means the user's Keychain
        // value doesn't match the server's `IOS_BEARER_TOKEN`. Anything
        // else falls through to the health-derived state.
        let dateString: String = {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy-MM-dd"
            return f.string(from: Date())
        }()
        do {
            _ = try await ServerClient.shared.todayCalendar(date: dateString)
        } catch ServerClientError.http(let code, _, _) where code == 401 {
            status = .authInvalid
            return
        } catch ServerClientError.notConfigured {
            status = .authInvalid
            return
        } catch {
            // Other errors (5xx, network) — fall through to health state.
        }

        switch healthLevel {
        case "ok":       status = .ok(upstream: probes)
        case "degraded": status = .degraded(upstream: probes)
        default:         status = .down(reason: "server reports \(healthLevel)")
        }
    }

    private struct HealthResponse: Decodable {
        let status: String
        let upstream: [String: String]
    }
}
