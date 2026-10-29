import Foundation
import Testing
@testable import VoiceDiary

// `[ServerCalendarEvent].filtered(by:)` decides which calendar events reach
// the walkthrough's per-event loop. These pin the current policy as-is:
// "accepted" and "organizer" always pass, "tentative" needs includeTentative,
// every other status needs includeNotAccepted, and all-day events need
// includeAllDay on top of the RSVP rule. RSVP statuses match case-sensitively.

private func event(_ id: String, allDay: Bool = false, rsvp: String) -> ServerCalendarEvent {
    ServerCalendarEvent(
        graph_event_id: id, subject: "Subject \(id)", start: "2026-10-15T10:00:00+02:00",
        end: "2026-10-15T10:30:00+02:00", is_all_day: allDay, show_as: "busy",
        rsvp_status: rsvp, organizer: ServerAttendee(name: "Olga", email: "olga@example.com"),
        attendees: [ServerAttendee(name: "Ben", email: "ben@example.com")],
        body_preview: "Preview \(id)", is_recurring: allDay, web_link: "https://example.com/\(id)"
    )
}

private func settings(
    allDay: Bool = false, tentative: Bool = false, notAccepted: Bool = false
) -> WalkthroughSettings {
    WalkthroughSettings(includeAllDay: allDay, includeTentative: tentative, includeNotAccepted: notAccepted)
}

private func ids(_ events: [ServerCalendarEvent]) -> [String] {
    events.map(\.graph_event_id)
}

private func encoded(_ events: [ServerCalendarEvent]) throws -> [Data] {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    return try events.map { try encoder.encode($0) }
}

// Timed (t-) and all-day (a-) events across every RSVP bucket, interleaved so
// the expected results also show that input order survives filtering.
private let mixedEvents: [ServerCalendarEvent] = [
    event("t-tentative", rsvp: "tentative"),
    event("a-accepted", allDay: true, rsvp: "accepted"),
    event("t-declined", rsvp: "declined"),
    event("a-none", allDay: true, rsvp: "none"),
    event("t-organizer", rsvp: "organizer"),
    event("a-tentative", allDay: true, rsvp: "tentative"),
    event("t-none", rsvp: "none"),
    event("a-organizer", allDay: true, rsvp: "organizer"),
    event("t-accepted", rsvp: "accepted"),
    event("a-declined", allDay: true, rsvp: "declined"),
    event("t-not-responded", rsvp: "notResponded"),
    event("a-not-responded", allDay: true, rsvp: "notResponded")
]

@Suite("Walkthrough calendar filter — RSVP policy on timed events")
struct WalkthroughCalendarFilterRSVPTests {
    @Test("default settings keep accepted and organizer events")
    func defaultsKeepAcceptedAndOrganizer() {
        let events = [event("a", rsvp: "accepted"), event("o", rsvp: "organizer")]
        #expect(ids(events.filtered(by: .default)) == ["a", "o"])
    }

    @Test("default settings drop tentative, declined, none and unknown statuses")
    func defaultsDropEverythingElse() {
        let events = ["tentative", "declined", "none", "notResponded", "needsAction", ""]
            .map { event("e-\($0)", rsvp: $0) }
        #expect(events.filtered(by: .default).isEmpty)
    }

    @Test("includeTentative admits tentative events and nothing else")
    func tentativeOptIn() {
        let events = [
            event("tentative", rsvp: "tentative"),
            event("declined", rsvp: "declined"),
            event("none", rsvp: "none")
        ]
        #expect(ids(events.filtered(by: settings(tentative: true))) == ["tentative"])
    }

    @Test("includeNotAccepted admits declined and unknown statuses but not tentative")
    func notAcceptedOptIn() {
        let events = [
            event("tentative", rsvp: "tentative"),
            event("declined", rsvp: "declined"),
            event("none", rsvp: "none"),
            event("empty", rsvp: "")
        ]
        #expect(ids(events.filtered(by: settings(notAccepted: true))) == ["declined", "none", "empty"])
    }

    @Test("RSVP opt-ins never remove accepted or organizer events")
    func optInsKeepAccepted() {
        let events = [event("a", rsvp: "accepted"), event("o", rsvp: "organizer")]
        #expect(ids(events.filtered(by: settings(tentative: true, notAccepted: true))) == ["a", "o"])
    }

    @Test("status matching is case-sensitive, so other casings count as not accepted")
    func statusIsCaseSensitive() {
        let events = [
            event("Accepted", rsvp: "Accepted"),
            event("ORGANIZER", rsvp: "ORGANIZER"),
            event("Tentative", rsvp: "Tentative")
        ]
        #expect(events.filtered(by: .default).isEmpty)
        #expect(events.filtered(by: settings(tentative: true)).isEmpty)
        #expect(ids(events.filtered(by: settings(notAccepted: true))) == ["Accepted", "ORGANIZER", "Tentative"])
    }
}

@Suite("Walkthrough calendar filter — all-day gate")
struct WalkthroughCalendarFilterAllDayTests {
    @Test("all-day events are dropped by default even when accepted or organizer")
    func allDayDroppedByDefault() {
        let events = [event("a", allDay: true, rsvp: "accepted"), event("o", allDay: true, rsvp: "organizer")]
        #expect(events.filtered(by: .default).isEmpty)
    }

    @Test("includeAllDay admits accepted and organizer all-day events")
    func allDayOptInKeepsAccepted() {
        let events = [event("a", allDay: true, rsvp: "accepted"), event("o", allDay: true, rsvp: "organizer")]
        #expect(ids(events.filtered(by: settings(allDay: true))) == ["a", "o"])
    }

    @Test("includeAllDay alone does not bypass the RSVP rule")
    func allDayDoesNotBypassRSVP() {
        let events = [
            event("tentative", allDay: true, rsvp: "tentative"),
            event("declined", allDay: true, rsvp: "declined"),
            event("none", allDay: true, rsvp: "none")
        ]
        #expect(events.filtered(by: settings(allDay: true)).isEmpty)
    }

    @Test("RSVP opt-ins alone do not bypass the all-day gate")
    func rsvpOptInsDoNotBypassAllDay() {
        let events = [
            event("accepted", allDay: true, rsvp: "accepted"),
            event("tentative", allDay: true, rsvp: "tentative"),
            event("declined", allDay: true, rsvp: "declined")
        ]
        #expect(events.filtered(by: settings(tentative: true)).isEmpty)
        #expect(events.filtered(by: settings(notAccepted: true)).isEmpty)
        #expect(events.filtered(by: settings(tentative: true, notAccepted: true)).isEmpty)
    }

    @Test("includeAllDay with an RSVP opt-in admits the matching all-day events")
    func allDayWithRSVPOptIn() {
        let events = [
            event("tentative", allDay: true, rsvp: "tentative"),
            event("declined", allDay: true, rsvp: "declined")
        ]
        #expect(ids(events.filtered(by: settings(allDay: true, tentative: true))) == ["tentative"])
        #expect(ids(events.filtered(by: settings(allDay: true, notAccepted: true))) == ["declined"])
    }
}

@Suite("Walkthrough calendar filter — settings combinations")
struct WalkthroughCalendarFilterCombinationTests {
    struct Combination: Sendable, CustomTestStringConvertible {
        let allDay: Bool
        let tentative: Bool
        let notAccepted: Bool
        let expected: [String]

        var testDescription: String {
            "allDay=\(allDay) tentative=\(tentative) notAccepted=\(notAccepted)"
        }
    }

    private static let combinations: [Combination] = [
        Combination(
            allDay: false, tentative: false, notAccepted: false,
            expected: ["t-organizer", "t-accepted"]
        ),
        Combination(
            allDay: false, tentative: true, notAccepted: false,
            expected: ["t-tentative", "t-organizer", "t-accepted"]
        ),
        Combination(
            allDay: false, tentative: false, notAccepted: true,
            expected: ["t-declined", "t-organizer", "t-none", "t-accepted", "t-not-responded"]
        ),
        Combination(
            allDay: false, tentative: true, notAccepted: true,
            expected: ["t-tentative", "t-declined", "t-organizer", "t-none", "t-accepted", "t-not-responded"]
        ),
        Combination(
            allDay: true, tentative: false, notAccepted: false,
            expected: ["a-accepted", "t-organizer", "a-organizer", "t-accepted"]
        ),
        Combination(
            allDay: true, tentative: true, notAccepted: false,
            expected: ["t-tentative", "a-accepted", "t-organizer", "a-tentative", "a-organizer", "t-accepted"]
        ),
        Combination(
            allDay: true, tentative: false, notAccepted: true,
            expected: [
                "a-accepted", "t-declined", "a-none", "t-organizer", "t-none",
                "a-organizer", "t-accepted", "a-declined", "t-not-responded", "a-not-responded"
            ]
        ),
        Combination(
            allDay: true, tentative: true, notAccepted: true,
            expected: [
                "t-tentative", "a-accepted", "t-declined", "a-none", "t-organizer", "a-tentative",
                "t-none", "a-organizer", "t-accepted", "a-declined", "t-not-responded", "a-not-responded"
            ]
        )
    ]

    @Test("all eight settings combinations filter the mixed list and keep input order", arguments: combinations)
    func combination(_ combination: Combination) {
        let result = mixedEvents.filtered(by: settings(
            allDay: combination.allDay, tentative: combination.tentative, notAccepted: combination.notAccepted
        ))
        #expect(ids(result) == combination.expected)
    }

    @Test("the combination table covers each settings triple exactly once")
    func tableCoversEightTriples() {
        let triples = Set(Self.combinations.map { "\($0.allDay)/\($0.tentative)/\($0.notAccepted)" })
        #expect(Self.combinations.count == 8)
        #expect(triples.count == 8)
    }
}

@Suite("Walkthrough calendar filter — identity and empty input")
struct WalkthroughCalendarFilterIdentityTests {
    @Test("surviving events keep their original payloads untouched")
    func payloadsUnchanged() throws {
        let everything = mixedEvents.filtered(by: settings(allDay: true, tentative: true, notAccepted: true))
        #expect(try encoded(everything) == encoded(mixedEvents))

        let defaults = mixedEvents.filtered(by: .default)
        let expected = mixedEvents.filter { ["t-organizer", "t-accepted"].contains($0.graph_event_id) }
        #expect(try encoded(defaults) == encoded(expected))
    }

    @Test("duplicate event ids are not collapsed")
    func duplicatesPreserved() {
        let events = [event("dup", rsvp: "accepted"), event("dup", rsvp: "accepted"), event("dup", rsvp: "declined")]
        #expect(ids(events.filtered(by: .default)) == ["dup", "dup"])
    }

    @Test("an empty list stays empty under every settings combination")
    func emptyInput() {
        let none: [ServerCalendarEvent] = []
        for allDay in [false, true] {
            for tentative in [false, true] {
                for notAccepted in [false, true] {
                    let result = none.filtered(by: settings(allDay: allDay, tentative: tentative, notAccepted: notAccepted))
                    #expect(result.isEmpty)
                }
            }
        }
    }
}
