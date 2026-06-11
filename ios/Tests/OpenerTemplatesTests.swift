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
        // Spoken time, never a digital clock (Voxtral glitches on "10:00").
        #expect(line.contains("10 Uhr"))
        #expect(!line.contains("10:00"))
        #expect(!line.contains(":"))
    }

    // MARK: - Spoken time (Voxtral-safe, no digital clock)
    //
    // spokenTime renders in Calendar.current's timezone (matching the
    // old timeString), so these build wall-clock dates via local
    // components — deterministic regardless of the test runner's TZ.

    @Test("spokenTime renders hour + Uhr, never a colon")
    func spokenTimeDE() {
        #expect(OpenerTemplates.spokenTime(localDate(10), language: .de) == "10 Uhr")
        #expect(OpenerTemplates.spokenTime(localDate(14, 30), language: .de) == "14 Uhr 30")
        #expect(!OpenerTemplates.spokenTime(localDate(14, 30), language: .de).contains(":"))
    }

    @Test("spokenTimeRange is bare (no leading von/from) so templates own the preposition")
    func spokenTimeRangeBare() {
        let de = OpenerTemplates.spokenTimeRange(localDate(10), localDate(11), language: .de)
        #expect(de == "10 bis 11 Uhr")
        #expect(!de.hasPrefix("von"))
        let en = OpenerTemplates.spokenTimeRange(localDate(10), localDate(11), language: .en)
        #expect(en == "ten to eleven")
        #expect(!en.contains(":"))
    }

    @Test("deep_work_block template does not double the preposition")
    func deepWorkNoDoubleVon() {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        let event = ServerCalendarEvent(
            graph_event_id: "id",
            subject: "Reporting",
            start: f.string(from: localDate(14)),
            end: f.string(from: localDate(16)),
            is_all_day: false,
            show_as: "busy",
            rsvp_status: "accepted",
            organizer: ServerAttendee(name: "Florian", email: "florian@example.com"),
            attendees: [],
            body_preview: "",
            is_recurring: false,
            web_link: ""
        )
        let line = OpenerTemplates.render(slot: .deepWorkBlock, event: event, language: .de)
        #expect(line.contains("Von 14 bis 16 Uhr"))
        #expect(!line.lowercased().contains("von von"))
    }

    /// A Date at `hour:minute` wall-clock on a fixed day in the current
    /// calendar, so spokenTime's TZ-local rendering is deterministic.
    private func localDate(_ hour: Int, _ minute: Int = 0) -> Date {
        var c = DateComponents()
        c.year = 2026; c.month = 4; c.day = 28
        c.hour = hour; c.minute = minute
        return Calendar.current.date(from: c)!
    }

    // MARK: - Continue prompt (silent-path 15s)

    @Test("continue prompt is non-empty per language and quote-free")
    func continuePrompt() {
        for lang in [OpenerLanguage.de, .en] {
            let line = OpenerTemplates.continuePrompt(language: lang)
            #expect(!line.isEmpty)
            // Quote-free so Piper doesn't read stray punctuation.
            #expect(!line.contains("\""))
            #expect(!line.contains("\u{201E}"))
            #expect(!line.contains("\u{201C}"))
        }
        // Each language invites its own command word.
        #expect(OpenerTemplates.continuePrompt(language: .de).contains("weiter"))
        #expect(OpenerTemplates.continuePrompt(language: .en).contains("next"))
    }

    // MARK: - Mixed-language script

    @Test("English title in German template emits an EN span for the title")
    func mixedLanguageScript() {
        let event = ServerCalendarEvent(
            graph_event_id: "id",
            subject: "Quarterly Business Review",
            start: "2026-04-28T14:00:00+02:00",
            end: "2026-04-28T15:00:00+02:00",
            is_all_day: false,
            show_as: "busy",
            rsvp_status: "accepted",
            organizer: ServerAttendee(name: "Florian", email: "florian@example.com"),
            attendees: [
                ServerAttendee(name: "Florian", email: "florian@example.com"),
                ServerAttendee(name: "Alex", email: "alex@example.com"),
                ServerAttendee(name: "Sam", email: "sam@example.com"),
            ],
            body_preview: "",
            is_recurring: false,
            web_link: ""
        )
        let spans = OpenerTemplates.script(
            slot: .groupMeeting,
            event: event,
            language: .de,
            mixedLanguage: true
        )
        // German frame surrounds the English title — at minimum we
        // expect one span with the title, tagged "en".
        let titleSpan = spans.first { $0.text.contains("Quarterly Business Review") }
        #expect(titleSpan != nil)
        #expect(titleSpan?.language == "en")
        // And at least one German span for the surrounding frame.
        #expect(spans.contains { $0.language == "de" })
    }

    @Test("German title stays in one DE span")
    func sameLanguageScript() {
        let event = ServerCalendarEvent(
            graph_event_id: "id",
            subject: "Quartalsbesprechung",
            start: "2026-04-28T14:00:00+02:00",
            end: "2026-04-28T15:00:00+02:00",
            is_all_day: false,
            show_as: "busy",
            rsvp_status: "accepted",
            organizer: ServerAttendee(name: "Florian", email: "florian@example.com"),
            attendees: [
                ServerAttendee(name: "Florian", email: "florian@example.com"),
                ServerAttendee(name: "Sabine", email: "sabine@example.com"),
                ServerAttendee(name: "Markus", email: "markus@example.com"),
            ],
            body_preview: "",
            is_recurring: false,
            web_link: ""
        )
        let spans = OpenerTemplates.script(
            slot: .groupMeeting,
            event: event,
            language: .de,
            mixedLanguage: true
        )
        // Coalesced: every span ends up tagged "de", regardless of
        // span count (placeholder boundaries may or may not survive
        // coalescing depending on detector verdict for the title).
        #expect(spans.allSatisfy { $0.language == "de" })
    }

    @Test("toggle off → single DE span even with English title")
    func mixedLanguageDisabled() {
        let event = ServerCalendarEvent(
            graph_event_id: "id",
            subject: "Quarterly Business Review",
            start: "2026-04-28T14:00:00+02:00",
            end: "2026-04-28T15:00:00+02:00",
            is_all_day: false,
            show_as: "busy",
            rsvp_status: "accepted",
            organizer: ServerAttendee(name: "Florian", email: "florian@example.com"),
            attendees: [ServerAttendee(name: "Alex", email: "alex@example.com")],
            body_preview: "",
            is_recurring: false,
            web_link: ""
        )
        let spans = OpenerTemplates.script(
            slot: .oneOnOne,
            event: event,
            language: .de,
            mixedLanguage: false
        )
        #expect(spans.count == 1)
        #expect(spans.first?.language == "de")
    }

    // MARK: - Closing prompt (SPEC §6 CLOSING state)

    @Test("closing prompt returns correct DE string")
    func closingPromptDE() {
        let line = OpenerTemplates.closingPrompt(language: .de)
        #expect(line == "Willst du noch etwas zum ganzen Tag sagen?")
    }

    @Test("closing prompt returns correct EN string")
    func closingPromptEN() {
        let line = OpenerTemplates.closingPrompt(language: .en)
        #expect(line == "Anything else you want to say about the day overall?")
    }

    @Test("closing prompt strings are non-empty per language")
    func closingPromptNonEmpty() {
        for lang in [OpenerLanguage.de, .en] {
            #expect(!OpenerTemplates.closingPrompt(language: lang).isEmpty)
        }
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
