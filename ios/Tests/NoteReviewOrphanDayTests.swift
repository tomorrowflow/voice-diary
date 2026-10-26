import Foundation
import Testing
@testable import VoiceDiary

// The "Older" badge and the "Für später" button on the note
// review card show only for a note captured on a different calendar day
// than the day being reviewed. These tests pin that day comparison in
// isolation, with explicit calendars and time zones.

@Suite("NoteReviewOrphanDay")
struct NoteReviewOrphanDayTests {
    private static func calendar(_ identifier: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: identifier)!
        return calendar
    }

    private static let utc = calendar("UTC")
    private static let berlin = calendar("Europe/Berlin")

    private static func instant(_ iso: String) -> Date {
        ISO8601DateFormatter().date(from: iso)!
    }

    private static func isOrphan(
        captured: String, selected: String, in calendar: Calendar
    ) -> Bool {
        NoteReviewOrphanDay.isOrphan(
            capturedAt: instant(captured),
            selectedDate: instant(selected),
            calendar: calendar
        )
    }

    @Test("same day at different times is not an orphan",
          arguments: [
            ("2026-06-02T00:00:00Z", "2026-06-02T23:59:59Z"),
            ("2026-06-02T23:59:59Z", "2026-06-02T00:00:00Z"),
            ("2026-06-02T09:14:22Z", "2026-06-02T09:14:22Z"),
          ])
    func sameDay(captured: String, selected: String) {
        #expect(!Self.isOrphan(captured: captured, selected: selected, in: Self.utc))
    }

    @Test("adjacent days are orphans in both directions",
          arguments: [
            ("2026-06-01T23:59:59Z", "2026-06-02T00:00:00Z"),
            ("2026-06-02T00:00:00Z", "2026-06-01T23:59:59Z"),
          ])
    func adjacentDays(captured: String, selected: String) {
        #expect(Self.isOrphan(captured: captured, selected: selected, in: Self.utc))
    }

    @Test("month and year boundaries separate days",
          arguments: [
            ("2026-01-31T23:59:59Z", "2026-02-01T00:00:00Z"),
            ("2026-02-28T23:59:59Z", "2026-03-01T00:00:00Z"),
            // 2028 is a leap year.
            ("2028-02-28T23:59:59Z", "2028-02-29T00:00:00Z"),
            ("2025-12-31T23:59:59Z", "2026-01-01T00:00:00Z"),
          ])
    func calendarBoundaries(captured: String, selected: String) {
        #expect(Self.isOrphan(captured: captured, selected: selected, in: Self.utc))
        #expect(Self.isOrphan(captured: selected, selected: captured, in: Self.utc))
    }

    @Test("same day number in another month or year is an orphan",
          arguments: [
            ("2026-05-02T10:00:00Z", "2026-06-02T10:00:00Z"),
            ("2025-06-02T10:00:00Z", "2026-06-02T10:00:00Z"),
          ])
    func sameDayNumberElsewhere(captured: String, selected: String) {
        #expect(Self.isOrphan(captured: captured, selected: selected, in: Self.utc))
    }

    @Test("a note captured after the selected day is an orphan")
    func futureCapturedDate() {
        #expect(Self.isOrphan(
            captured: "2026-06-03T08:00:00Z", selected: "2026-06-02T08:00:00Z", in: Self.utc))
        #expect(Self.isOrphan(
            captured: "2027-06-02T08:00:00Z", selected: "2026-06-02T08:00:00Z", in: Self.utc))
    }

    @Test("the calendar's time zone decides which day an instant falls on")
    func timeZoneDecidesTheDay() {
        // 23:30Z on 1 June is 01:30 on 2 June in Berlin (CEST, UTC+2).
        let captured = "2026-06-01T23:30:00Z"
        let selected = "2026-06-02T00:30:00Z"
        #expect(Self.isOrphan(captured: captured, selected: selected, in: Self.utc))
        #expect(!Self.isOrphan(captured: captured, selected: selected, in: Self.berlin))

        // 21:30Z and 22:30Z on 2 June are 23:30 on 2 June and 00:30 on 3 June in Berlin.
        let lateCaptured = "2026-06-02T21:30:00Z"
        let lateSelected = "2026-06-02T22:30:00Z"
        #expect(!Self.isOrphan(captured: lateCaptured, selected: lateSelected, in: Self.utc))
        #expect(Self.isOrphan(captured: lateCaptured, selected: lateSelected, in: Self.berlin))
    }

    @Test("a 23-hour spring-forward day still ends at local midnight")
    func springForwardDay() {
        // Berlin skips 02:00–03:00 on 29 March 2026 (CET → CEST).
        #expect(!Self.isOrphan(
            captured: "2026-03-28T23:00:00Z",  // 00:00 CET, 29 March
            selected: "2026-03-29T21:59:59Z",  // 23:59:59 CEST, 29 March
            in: Self.berlin))
        #expect(Self.isOrphan(
            captured: "2026-03-28T23:00:00Z",
            selected: "2026-03-29T22:00:00Z",  // 00:00 CEST, 30 March
            in: Self.berlin))
        // 24 elapsed hours from 00:30 CET lands on 30 March at 01:30 CEST.
        #expect(Self.isOrphan(
            captured: "2026-03-28T23:30:00Z",
            selected: "2026-03-29T23:30:00Z",
            in: Self.berlin))
    }

    @Test("a 25-hour fall-back day still ends at local midnight")
    func fallBackDay() {
        // Berlin repeats 02:00–03:00 on 25 October 2026 (CEST → CET).
        #expect(!Self.isOrphan(
            captured: "2026-10-24T22:00:00Z",  // 00:00 CEST, 25 October
            selected: "2026-10-25T22:59:59Z",  // 23:59:59 CET, 25 October
            in: Self.berlin))
        #expect(Self.isOrphan(
            captured: "2026-10-24T22:00:00Z",
            selected: "2026-10-25T23:00:00Z",  // 00:00 CET, 26 October
            in: Self.berlin))
        // 24 elapsed hours from 00:30 CEST is still 25 October (23:30 CET).
        #expect(!Self.isOrphan(
            captured: "2026-10-24T22:30:00Z",
            selected: "2026-10-25T22:30:00Z",
            in: Self.berlin))
    }
}
