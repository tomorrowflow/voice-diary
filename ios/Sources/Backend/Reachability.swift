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
        case down(reason: String)
    }

    @Published public private(set) var status: Status = .unknown

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
        do {
            let data = try await ServerClient.shared.health()
            let parsed = try JSONDecoder().decode(HealthResponse.self, from: data)
            switch parsed.status {
            case "ok":       status = .ok(upstream: parsed.upstream)
            case "degraded": status = .degraded(upstream: parsed.upstream)
            default:         status = .down(reason: "server reports \(parsed.status)")
            }
        } catch {
            status = .down(reason: "\(error)")
        }
    }

    private struct HealthResponse: Decodable {
        let status: String
        let upstream: [String: String]
    }
}
