import Foundation
import Testing
@testable import VoiceDiary

// Classification behind the "Server voices" status block in
// VoiceSettingsView. The view maps each case to its localized label and
// detail and each tone to a Theme color; these tests pin which case,
// icon and tone every reachability status produces.

@Suite("ServerVoiceAvailability")
struct ServerVoiceAvailabilityTests {
    private static func statuses(upstream: [String: String]) -> [Reachability.Status] {
        [.ok(upstream: upstream), .degraded(upstream: upstream)]
    }

    @Test("a recognized voxtral value maps to its case, icon and tone",
          arguments: [
            ("ok", ServerVoiceAvailability.connected, "checkmark.circle.fill",
             ServerVoiceAvailability.Tone.success),
            ("down", .unreachable, "exclamationmark.triangle.fill", .destructive),
            ("skipped", .notConfigured, "minus.circle", .subdued),
          ])
    func recognizedValue(
        value: String,
        expected: ServerVoiceAvailability,
        icon: String,
        tone: ServerVoiceAvailability.Tone
    ) {
        for status in Self.statuses(upstream: ["voxtral": value]) {
            let availability = ServerVoiceAvailability(status: status)
            #expect(availability == expected)
            #expect(availability.iconName == icon)
            #expect(availability.tone == tone)
        }
    }

    @Test("a missing voxtral key is unknown")
    func missingKey() {
        for status in Self.statuses(upstream: [:]) {
            #expect(ServerVoiceAvailability(status: status) == .unknown)
        }
    }

    @Test("unrelated upstream keys do not decide the classification")
    func unrelatedKeys() {
        let upstream = ["whisper": "ok", "postgres": "down", "lightrag": "skipped"]
        for status in Self.statuses(upstream: upstream) {
            #expect(ServerVoiceAvailability(status: status) == .unknown)
        }
    }

    @Test("other keys do not change a recognized voxtral value")
    func recognizedValueAmongOtherKeys() {
        let upstream = ["whisper": "down", "voxtral": "ok", "postgres": "skipped"]
        for status in Self.statuses(upstream: upstream) {
            #expect(ServerVoiceAvailability(status: status) == .connected)
        }
    }

    @Test("empty, unrecognized and case-mismatched values are unknown",
          arguments: ["", "OK", "Ok", "DOWN", "Down", "Skipped", "SKIPPED",
                      "unknown", "degraded", " ok", "ok "])
    func unrecognizedValue(value: String) {
        for status in Self.statuses(upstream: ["voxtral": value]) {
            let availability = ServerVoiceAvailability(status: status)
            #expect(availability == .unknown)
            #expect(availability.iconName == "questionmark.circle")
            #expect(availability.tone == .subdued)
        }
    }

    @Test("non-health statuses keep the question-mark icon and subdued tone",
          arguments: [
            (Reachability.Status.unknown, ServerVoiceAvailability.unknown),
            (.authInvalid, .bearerInvalid),
            (.down(reason: "timeout"), .serverUnreachable),
          ])
    func nonHealthStatus(status: Reachability.Status, expected: ServerVoiceAvailability) {
        let availability = ServerVoiceAvailability(status: status)
        #expect(availability == expected)
        #expect(availability.iconName == "questionmark.circle")
        #expect(availability.tone == .subdued)
    }

    @Test("a down status ignores its reason",
          arguments: ["", "timeout", "voxtral", "HTTP 503"])
    func downReason(reason: String) {
        #expect(ServerVoiceAvailability(status: .down(reason: reason)) == .serverUnreachable)
    }
}
