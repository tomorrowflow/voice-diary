import Foundation
import Testing
@testable import VoiceDiary

// IOS-A20: walkthrough plan assembly lives in `WalkthroughPlanBuilder`, a
// pure function over the configured order, general sections, calendar
// events and voice notes. These tests drive it directly with values: no
// coordinator, settings store or history store is involved.

@Suite("WalkthroughPlanBuilder")
struct WalkthroughPlanBuilderTests {
    private func event(_ id: String) -> ServerCalendarEvent {
        ServerCalendarEvent(
            graph_event_id: id, subject: "Sync", start: "2026-10-15T10:00:00+02:00",
            end: "2026-10-15T10:30:00+02:00", is_all_day: false, show_as: "busy",
            rsvp_status: "accepted", organizer: ServerAttendee(name: "A", email: "a@example.com"),
            attendees: [], body_preview: "", is_recurring: false, web_link: ""
        )
    }

    private func note(_ id: String) -> VoiceNote {
        VoiceNote(
            seed_id: id, captured_at: Date(timeIntervalSince1970: 1_760_000_000),
            duration_seconds: 4, language: "en", transcript: "t",
            audio_file_url: URL(fileURLWithPath: "/tmp/\(id).m4a")
        )
    }

    private func section(_ id: String) -> GeneralSection {
        GeneralSection(id: id, title: "Title \(id)", introText: "Intro \(id)")
    }

    /// One readable token per step, carrying the payload identity in order.
    private func shape(_ steps: [WalkthroughPlanStep]) -> [String] {
        steps.map {
            switch $0 {
            case .general(let section):
                return "general:\(section.id)"
            case .calendar(let events):
                return "calendar:" + events.map(\.id).joined(separator: ",")
            case .voiceNote(let notes):
                return "voiceNote:" + notes.map(\.id).joined(separator: ",")
            }
        }
    }

    @Test("an empty order builds an empty plan whatever the inputs")
    func emptyOrder() {
        let steps = WalkthroughPlanBuilder.build(
            order: [], generals: [section("g1")], events: [event("e1")], notes: [note("n1")]
        )
        #expect(steps.isEmpty)
    }

    @Test("a general id with no matching section is skipped")
    func unknownGeneralID() {
        let steps = WalkthroughPlanBuilder.build(
            order: [.general(id: "missing"), .general(id: "g1")],
            generals: [section("g1")], events: [], notes: []
        )
        #expect(shape(steps) == ["general:g1"])
    }

    @Test("mixed sections keep the configured order")
    func mixedOrder() {
        let steps = WalkthroughPlanBuilder.build(
            order: [.voiceNote, .general(id: "g1"), .calendarEvents, .general(id: "g2")],
            generals: [section("g1"), section("g2")],
            events: [event("e1")], notes: [note("n1")]
        )
        #expect(shape(steps) == ["voiceNote:n1", "general:g1", "calendar:e1", "general:g2"])
    }

    @Test("no events omits the calendar step")
    func emptyCalendarOmitted() {
        let steps = WalkthroughPlanBuilder.build(
            order: [.general(id: "g1"), .calendarEvents],
            generals: [section("g1")], events: [], notes: []
        )
        #expect(shape(steps) == ["general:g1"])
    }

    @Test("events make one calendar step that holds them all")
    func nonEmptyCalendar() {
        let steps = WalkthroughPlanBuilder.build(
            order: [.calendarEvents], generals: [], events: [event("e1"), event("e2")], notes: []
        )
        #expect(shape(steps) == ["calendar:e1,e2"])
    }

    @Test("a voice-note step is kept when there are no notes")
    func emptyNotesKept() {
        let steps = WalkthroughPlanBuilder.build(
            order: [.voiceNote], generals: [], events: [], notes: []
        )
        #expect(shape(steps) == ["voiceNote:"])
    }

    @Test("a voice-note step holds its notes")
    func nonEmptyNotes() {
        let steps = WalkthroughPlanBuilder.build(
            order: [.voiceNote], generals: [], events: [], notes: [note("n1"), note("n2")]
        )
        #expect(shape(steps) == ["voiceNote:n1,n2"])
    }

    @Test("repeated order entries are not deduplicated")
    func repeatedEntries() {
        let steps = WalkthroughPlanBuilder.build(
            order: [.general(id: "g1"), .calendarEvents, .general(id: "g1"), .calendarEvents, .voiceNote, .voiceNote],
            generals: [section("g1")], events: [event("e1")], notes: [note("n1")]
        )
        #expect(shape(steps) == [
            "general:g1", "calendar:e1", "general:g1", "calendar:e1", "voiceNote:n1", "voiceNote:n1",
        ])
    }

    @Test("several general sections follow the order, not the generals array")
    func multipleGeneralSections() {
        let steps = WalkthroughPlanBuilder.build(
            order: [.general(id: "g3"), .general(id: "g1"), .general(id: "g2")],
            generals: [section("g1"), section("g2"), section("g3")], events: [], notes: []
        )
        #expect(shape(steps) == ["general:g3", "general:g1", "general:g2"])
    }

    @Test("a general step carries its section's payload unchanged")
    func generalPayload() {
        let configured = GeneralSection(id: "g1", title: "Reflection", introText: "How was your day?", followUpEnabled: true)
        let steps = WalkthroughPlanBuilder.build(
            order: [.general(id: "g1")], generals: [configured], events: [], notes: []
        )
        guard case .general(let built) = steps.first else {
            Issue.record("expected a general step")
            return
        }
        #expect(built == configured)
    }

    @Test("event and note payload order is kept as given")
    func stablePayloadOrder() {
        let steps = WalkthroughPlanBuilder.build(
            order: [.calendarEvents, .voiceNote], generals: [],
            events: [event("e3"), event("e1"), event("e2")],
            notes: [note("n2"), note("n3"), note("n1")]
        )
        #expect(shape(steps) == ["calendar:e3,e1,e2", "voiceNote:n2,n3,n1"])
    }

    @Test("the coordinator entry point returns the builder's plan")
    func coordinatorDelegates() {
        let order: [WalkthroughSection] = [.general(id: "g1"), .calendarEvents, .voiceNote]
        let generals = [section("g1")]
        let events = [event("e1")]
        let notes = [note("n1")]
        #expect(
            shape(WalkthroughCoordinator.makePlan(order: order, generals: generals, events: events, notes: notes))
                == shape(WalkthroughPlanBuilder.build(order: order, generals: generals, events: events, notes: notes))
        )
    }
}
