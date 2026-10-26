import Foundation
import Testing
@testable import VoiceDiary

// `ServerCalendarEvent` parses the server's ISO-8601 strings and derives a
// whole-minute duration. These tests pin that seam with fixed timestamps;
// nothing depends on the current time or the device's time zone.

@Suite("ServerCalendarEvent dates and duration")
struct ServerCalendarEventDateTests {
    /// 2026-01-15 09:00:00 UTC.
    private static let nineUTC: TimeInterval = 1_768_467_600

    private static func event(start: String, end: String) -> ServerCalendarEvent {
        ServerCalendarEvent(
            graph_event_id: "evt", subject: "Sync", start: start, end: end,
            is_all_day: false, show_as: "busy", rsvp_status: "accepted",
            organizer: ServerAttendee(name: "A", email: "a@example.com"),
            attendees: [], body_preview: "", is_recurring: false, web_link: ""
        )
    }

    /// An event starting at 09:00:00Z that ends at the given timestamp.
    private static func event(endingAt end: String) -> ServerCalendarEvent {
        event(start: "2026-01-15T09:00:00Z", end: end)
    }

    // MARK: - Parsing

    @Test("whole-second timestamp parses to its instant")
    func wholeSecond() {
        let event = Self.event(start: "2026-01-15T09:00:00Z", end: "2026-01-15T09:30:00Z")
        #expect(event.startDate == Date(timeIntervalSince1970: Self.nineUTC))
        #expect(event.endDate == Date(timeIntervalSince1970: Self.nineUTC + 1800))
    }

    @Test("fractional-second timestamp parses to its instant")
    func fractionalSecond() {
        let event = Self.event(start: "2026-01-15T09:00:00.500Z", end: "2026-01-15T09:30:00.250Z")
        #expect(event.startDate == Date(timeIntervalSince1970: Self.nineUTC + 0.5))
        #expect(event.endDate == Date(timeIntervalSince1970: Self.nineUTC + 1800.25))
    }

    @Test("equivalent instants with different offsets are equal")
    func offsets() {
        let utc = Self.event(start: "2026-01-15T09:00:00Z", end: "2026-01-15T10:00:00Z")
        let berlin = Self.event(start: "2026-01-15T10:00:00+01:00", end: "2026-01-15T11:00:00+01:00")
        let newYork = Self.event(start: "2026-01-15T04:00:00-05:00", end: "2026-01-15T05:00:00-05:00")
        #expect(berlin.startDate == utc.startDate)
        #expect(newYork.startDate == utc.startDate)
        #expect(berlin.endDate == utc.endDate)
        #expect(newYork.endDate == utc.endDate)
        #expect(berlin.durationMinutes == 60)
        #expect(newYork.durationMinutes == 60)
    }

    @Test("an offset shifts the instant by exactly that offset")
    func offsetShiftsInstant() {
        let event = Self.event(start: "2026-01-15T09:00:00+02:00", end: "2026-01-15T09:00:00-02:00")
        #expect(event.startDate == Date(timeIntervalSince1970: Self.nineUTC - 7200))
        #expect(event.endDate == Date(timeIntervalSince1970: Self.nineUTC + 7200))
        #expect(event.durationMinutes == 240)
    }

    @Test("malformed start leaves startDate nil and end intact")
    func malformedStart() {
        let event = Self.event(start: "not a date", end: "2026-01-15T09:30:00Z")
        #expect(event.startDate == nil)
        #expect(event.endDate == Date(timeIntervalSince1970: Self.nineUTC + 1800))
    }

    @Test("malformed end leaves endDate nil and start intact")
    func malformedEnd() {
        let event = Self.event(start: "2026-01-15T09:00:00Z", end: "2026-13-45T25:61:00Z")
        #expect(event.startDate == Date(timeIntervalSince1970: Self.nineUTC))
        #expect(event.endDate == nil)
    }

    @Test("empty strings are malformed")
    func empty() {
        let event = Self.event(start: "", end: "")
        #expect(event.startDate == nil)
        #expect(event.endDate == nil)
    }

    // MARK: - Duration

    @Test("duration is zero when the start is malformed")
    func durationMalformedStart() {
        #expect(Self.event(start: "garbage", end: "2026-01-15T10:00:00Z").durationMinutes == 0)
    }

    @Test("duration is zero when the end is malformed")
    func durationMalformedEnd() {
        #expect(Self.event(start: "2026-01-15T09:00:00Z", end: "garbage").durationMinutes == 0)
    }

    @Test("duration is zero when both dates are malformed")
    func durationBothMalformed() {
        #expect(Self.event(start: "", end: "").durationMinutes == 0)
    }

    @Test("reversed interval clamps to zero")
    func reversed() {
        let event = Self.event(start: "2026-01-15T10:00:00Z", end: "2026-01-15T09:00:00Z")
        #expect(event.durationMinutes == 0)
    }

    @Test("zero-length interval is zero minutes")
    func zeroLength() {
        #expect(Self.event(endingAt: "2026-01-15T09:00:00Z").durationMinutes == 0)
    }

    @Test("59, 60 and 61 seconds truncate to whole minutes")
    func minuteBoundary() {
        #expect(Self.event(endingAt: "2026-01-15T09:00:59Z").durationMinutes == 0)
        #expect(Self.event(endingAt: "2026-01-15T09:01:00Z").durationMinutes == 1)
        #expect(Self.event(endingAt: "2026-01-15T09:01:01Z").durationMinutes == 1)
    }

    @Test("119 and 120 seconds truncate rather than round")
    func secondMinuteBoundary() {
        #expect(Self.event(endingAt: "2026-01-15T09:01:59Z").durationMinutes == 1)
        #expect(Self.event(endingAt: "2026-01-15T09:02:00Z").durationMinutes == 2)
    }

    @Test("a 90-minute interval is 90 minutes")
    func ninetyMinutes() {
        #expect(Self.event(endingAt: "2026-01-15T10:30:00Z").durationMinutes == 90)
    }
}
