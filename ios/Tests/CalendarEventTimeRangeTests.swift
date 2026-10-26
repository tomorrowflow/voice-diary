import Foundation
import Testing
@testable import VoiceDiary

// The calendar event card's "09:00 – 09:30" line. The rule is optional
// dates in, text out, with an explicit time zone; these tests pin it with
// synthetic dates and explicit zones. Only the last test uses the device's
// default zone.

@Suite("CalendarEventTimeRange")
struct CalendarEventTimeRangeTests {
    private static let utc = TimeZone(identifier: "UTC")!
    private static let berlin = TimeZone(identifier: "Europe/Berlin")!

    /// 2026-01-15 `hour`:`minute` UTC (Berlin is UTC+1 on that date).
    private static func winter(_ hour: Int, _ minute: Int = 0) -> Date {
        Date(timeIntervalSince1970: 1_768_435_200 + TimeInterval(hour * 3600 + minute * 60))
    }

    private static func text(_ start: Date?, _ end: Date?, _ zone: TimeZone = utc) -> String {
        CalendarEventTimeRange.text(start: start, end: end, timeZone: zone)
    }

    @Test("both dates missing renders nothing")
    func bothMissing() {
        #expect(Self.text(nil, nil) == "")
    }

    @Test("start missing renders nothing")
    func startMissing() {
        #expect(Self.text(nil, Self.winter(10)) == "")
    }

    @Test("end missing renders nothing")
    func endMissing() {
        #expect(Self.text(Self.winter(9), nil) == "")
    }

    @Test("same start and end renders the same time twice")
    func sameTime() {
        #expect(Self.text(Self.winter(9, 30), Self.winter(9, 30)) == "09:30 – 09:30")
    }

    @Test("morning range")
    func morning() {
        #expect(Self.text(Self.winter(9), Self.winter(9, 30)) == "09:00 – 09:30")
    }

    @Test("evening range uses 24-hour time")
    func evening() {
        #expect(Self.text(Self.winter(18, 15), Self.winter(21, 45)) == "18:15 – 21:45")
    }

    @Test("minutes and hours are zero-padded")
    func padding() {
        #expect(Self.text(Self.winter(0, 5), Self.winter(1, 0)) == "00:05 – 01:00")
        #expect(Self.text(Self.winter(7, 9), Self.winter(8, 1)) == "07:09 – 08:01")
    }

    @Test("overnight range is not normalised")
    func overnight() {
        #expect(Self.text(Self.winter(22), Self.winter(25, 30)) == "22:00 – 01:30")
    }

    @Test("reversed range is not normalised")
    func reversed() {
        #expect(Self.text(Self.winter(11), Self.winter(10)) == "11:00 – 10:00")
    }

    @Test("the same instants render per the given time zone")
    func timeZones() {
        let start = Self.winter(8)
        let end = Self.winter(9, 30)
        #expect(Self.text(start, end, Self.utc) == "08:00 – 09:30")
        #expect(Self.text(start, end, Self.berlin) == "09:00 – 10:30")
    }

    @Test("Berlin follows daylight saving time")
    func berlinSummer() {
        // 2026-07-01 08:00 UTC is 10:00 in Berlin (UTC+2).
        let start = Date(timeIntervalSince1970: 1_782_892_800)
        let end = start.addingTimeInterval(1800)
        #expect(Self.text(start, end, Self.berlin) == "10:00 – 10:30")
    }

    @Test("range crossing midnight in the zone, not in UTC")
    func zoneMidnight() {
        // 22:30 UTC to 23:30 UTC is 23:30 to 00:30 in Berlin in winter.
        #expect(Self.text(Self.winter(22, 30), Self.winter(23, 30), Self.berlin) == "23:30 – 00:30")
    }

    @Test("default zone matches the card's former formatter")
    func matchesFormerFormatter() {
        // The formatter the card used before extraction, at the default
        // zone. Depends on the host zone by design; the other tests don't.
        let former = DateFormatter()
        former.locale = Locale(identifier: "de_DE")
        former.dateFormat = "HH:mm"
        // Epoch, a winter day, a summer day and an autumn day.
        let days: [TimeInterval] = [0, 1_768_435_200, 1_782_864_000, 1_790_000_000]
        let twelveFortyFive: TimeInterval = 12 * 3600 + 45 * 60
        let oneHourOneMinute: TimeInterval = 3600 + 60
        for day in days {
            let start = Date(timeIntervalSince1970: day + twelveFortyFive)
            let end = start.addingTimeInterval(oneHourOneMinute)
            let expected = "\(former.string(from: start)) – \(former.string(from: end))"
            #expect(Self.text(start, end, .current) == expected)
        }
    }
}
