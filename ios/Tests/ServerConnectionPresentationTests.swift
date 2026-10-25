import Foundation
import Testing
@testable import VoiceDiary

// IOS-A22: what the server settings screen shows for a saved/unsaved URL
// and a `Reachability.Status`. Pure value in, value out — no probe, no
// Keychain, no view.

@Suite("ServerConnectionPresentation")
struct ServerConnectionPresentationTests {
    typealias Presentation = ServerConnectionPresentation
    typealias State = ServerConnectionPresentation.State

    private static let upstream = ["postgres": "ok", "whisper": "slow"]

    /// Every `Reachability.Status` case, with non-empty payloads where the
    /// case carries one.
    private static let statuses: [(name: String, status: Reachability.Status, state: State, connected: Bool)] = [
        ("unknown", .unknown, .unknown, false),
        ("ok", .ok(upstream: upstream), .ok, true),
        ("degraded", .degraded(upstream: upstream), .degraded, true),
        ("authInvalid", .authInvalid, .authInvalid, false),
        ("down", .down(reason: "server reports down"), .down, false),
    ]

    @Test("a saved URL shows the probe status unchanged",
          arguments: statuses)
    func savedShowsProbe(entry: (name: String, status: Reachability.Status, state: State, connected: Bool)) {
        let p = Presentation(hasSavedURL: true, probeStatus: entry.status)
        #expect(p.effectiveStatus == entry.status)
        #expect(p.state == entry.state)
        #expect(p.isConnected == entry.connected)
    }

    @Test("an unsaved URL reads as unknown whatever the probe said",
          arguments: statuses)
    func unsavedIsUnknown(entry: (name: String, status: Reachability.Status, state: State, connected: Bool)) {
        let p = Presentation(hasSavedURL: false, probeStatus: entry.status)
        #expect(p.effectiveStatus == .unknown)
        #expect(p.state == .unknown)
        #expect(!p.isConnected)
    }

    @Test("saved ok and degraded keep their upstream dictionary")
    func upstreamPayloadSurvives() {
        let ok = Presentation(hasSavedURL: true, probeStatus: .ok(upstream: Self.upstream))
        let degraded = Presentation(hasSavedURL: true, probeStatus: .degraded(upstream: Self.upstream))
        #expect(ok.effectiveStatus == .ok(upstream: Self.upstream))
        #expect(degraded.effectiveStatus == .degraded(upstream: Self.upstream))
        #expect(ok.effectiveStatus != .ok(upstream: [:]))
    }

    @Test("an empty upstream dictionary still counts as connected")
    func emptyUpstreamConnected() {
        #expect(Presentation(hasSavedURL: true, probeStatus: .ok(upstream: [:])).isConnected)
        #expect(Presentation(hasSavedURL: true, probeStatus: .degraded(upstream: [:])).isConnected)
    }

    @Test("a saved URL keeps any down reason and is never connected",
          arguments: ["", "server reports down", "URLError(-1004)", "Zeitüberschreitung ✗"])
    func downReasonSurvives(reason: String) {
        let p = Presentation(hasSavedURL: true, probeStatus: .down(reason: reason))
        #expect(p.effectiveStatus == .down(reason: reason))
        #expect(p.state == .down)
        #expect(!p.isConnected)
    }

    @Test("an unsaved URL drops the down reason",
          arguments: ["", "server reports down"])
    func unsavedDropsReason(reason: String) {
        let p = Presentation(hasSavedURL: false, probeStatus: .down(reason: reason))
        #expect(p.effectiveStatus == .unknown)
        #expect(!p.isConnected)
    }
}
