import Foundation
import Testing
@testable import VoiceDiary

@Suite("OpenerTemplates")
struct OpenerTemplatesTests {

    @Test("first-event slot wins regardless of attendees")
    func firstEvent() {
        let event = makeEvent(attendees: [], duration: 60, recurring: true)
        let slot = OpenerTemplates.slot(for: event, positionInDay: .first)
        #expect(slot == .firstEvent)
    }

    @Test("last-event slot wins regardless of duration")
    func lastEvent() {
        let event = makeEvent(attendees: [], duration: 30, recurring: false)
        #expect(OpenerTemplates.slot(for: event, positionInDay: .last) == .lastEvent)
    }

    @Test("zero attendees → deep_work_block")
    func deepWork() {
        let event = makeEvent(attendees: [], duration: 90, recurring: false)
        #expect(OpenerTemplates.slot(for: event, positionInDay: .middle) == .deepWorkBlock)
    }

    @Test("recurring instance → recurring_ritual")
    func recurring() {
        let event = makeEvent(attendees: ["a"], duration: 30, recurring: true)
        #expect(OpenerTemplates.slot(for: event, positionInDay: .middle) == .recurringRitual)
    }

    @Test(
        "duration thresholds",
        arguments: [
            (29, OpenerSlot.shortMeeting),
            (89, OpenerSlot.oneOnOne),
            (90, OpenerSlot.longMeeting),
            (180, OpenerSlot.longMeeting),
        ]
    )
    func durationBranches(durationMinutes: Int, expected: OpenerSlot) {
        let event = makeEvent(attendees: ["one"], duration: durationMinutes, recurring: false)
        #expect(OpenerTemplates.slot(for: event, positionInDay: .middle) == expected)
    }

    @Test("3+ attendees → group_meeting")
    func group() {
        let event = makeEvent(attendees: ["a", "b", "c"], duration: 60, recurring: false)
        #expect(OpenerTemplates.slot(for: event, positionInDay: .middle) == .groupMeeting)
    }

    @Test("template renders {title} + {time}")
    func renderTemplate() {
        let event = ServerCalendarEvent(
            graph_event_id: "id",
            subject: "Sync mit Monica",
            start: "2026-04-28T10:00:00+02:00",
            end: "2026-04-28T10:30:00+02:00",
            is_all_day: false,
            show_as: "busy",
            rsvp_status: "accepted",
            organizer: ServerAttendee(name: "Florian", email: "florian@example.com"),
            attendees: [ServerAttendee(name: "Monica", email: "monica@example.com")],
            body_preview: "",
            is_recurring: false,
            web_link: ""
        )
        let line = OpenerTemplates.line(for: event, index: 1, of: 4, language: .de)
        #expect(line.contains("Sync mit Monica"))
        #expect(line.contains("10:00"))
    }

    // MARK: - helpers

    private func makeEvent(attendees: [String], duration: Int, recurring: Bool) -> ServerCalendarEvent {
        let start = Date(timeIntervalSince1970: 1_715_600_000)
        let end = start.addingTimeInterval(TimeInterval(duration * 60))
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return ServerCalendarEvent(
            graph_event_id: "id",
            subject: "Subject",
            start: f.string(from: start),
            end: f.string(from: end),
            is_all_day: false,
            show_as: "busy",
            rsvp_status: "accepted",
            organizer: ServerAttendee(name: "Org", email: "org@example.com"),
            attendees: attendees.map { ServerAttendee(name: $0, email: "\($0)@example.com") },
            body_preview: "",
            is_recurring: recurring,
            web_link: ""
        )
    }
}
