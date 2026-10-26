import Foundation
import Testing
@testable import VoiceDiary

// IOS-A30: which last-error the server settings screen shows for a probe
// `Reachability.Status`. Pure value in, value out: no probe, no Keychain,
// no localization, no view.

@Suite("ServerStatusError")
struct ServerStatusErrorTests {
    private static let upstream = ["postgres": "ok", "whisper": "slow"]

    @Test("an invalid bearer projects the authentication marker")
    func authInvalidIsAuthentication() {
        #expect(ServerStatusError(status: .authInvalid) == .authentication)
    }

    @Test("a down status projects exactly its reason, empty included",
          arguments: ["", " ", "server reports down", "URLError(-1004)", "Zeitüberschreitung ✗", "line one\nline two"])
    func downKeepsReason(reason: String) {
        #expect(ServerStatusError(status: .down(reason: reason)) == .down(reason: reason))
    }

    @Test("an empty down reason is still an error, not a clear")
    func emptyDownReasonIsAnError() {
        #expect(ServerStatusError(status: .down(reason: "")) != nil)
    }

    @Test("unknown, ok and degraded project no error")
    func healthyOrUnknownClears() {
        #expect(ServerStatusError(status: .unknown) == nil)
        #expect(ServerStatusError(status: .ok(upstream: Self.upstream)) == nil)
        #expect(ServerStatusError(status: .ok(upstream: [:])) == nil)
        #expect(ServerStatusError(status: .degraded(upstream: Self.upstream)) == nil)
        #expect(ServerStatusError(status: .degraded(upstream: [:])) == nil)
    }

    @Test("successive projections follow each status with no carry-over")
    func successiveProjections() {
        let sequence: [(Reachability.Status, ServerStatusError?)] = [
            (.down(reason: "timed out"), .down(reason: "timed out")),
            (.ok(upstream: Self.upstream), nil),
            (.authInvalid, .authentication),
            (.degraded(upstream: Self.upstream), nil),
            (.down(reason: ""), .down(reason: "")),
            (.unknown, nil),
            (.down(reason: "refused"), .down(reason: "refused")),
            (.authInvalid, .authentication),
            (.down(reason: "refused"), .down(reason: "refused")),
        ]
        for (status, expected) in sequence {
            #expect(ServerStatusError(status: status) == expected)
        }
    }
}
