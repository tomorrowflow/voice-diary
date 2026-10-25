import Foundation
import Testing
@testable import VoiceDiary

@Suite("HistoryGrouping")
struct HistoryGroupingTests {

    private struct Entry: Equatable {
        let name: String
        let date: Date
    }

    private let de = Locale(identifier: "de_DE")
    private let en = Locale(identifier: "en_US")

    private func berlin() -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return cal
    }

    private func date(_ cal: Calendar, _ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    private func group(
        _ entries: [Entry],
        calendar: Calendar,
        now: Date,
        locale: Locale
    ) -> [HistoryGrouping.Section<Entry>] {
        HistoryGrouping.group(entries, sortDate: \.date, calendar: calendar, now: now, locale: locale)
    }

    @Test("empty input yields no sections")
    func empty() {
        let cal = berlin()
        let sections = group([], calendar: cal, now: date(cal, 2026, 5, 20, 12), locale: en)
        #expect(sections.isEmpty)
    }

    @Test("days descend and items keep their input order within a day")
    func descendingDaysStableOrder() {
        let cal = berlin()
        let now = date(cal, 2026, 5, 20, 12)
        let entries = [
            Entry(name: "a", date: date(cal, 2026, 5, 10, 9)),
            Entry(name: "b", date: date(cal, 2026, 5, 12, 8)),
            Entry(name: "c", date: date(cal, 2026, 5, 10, 18)),
            Entry(name: "d", date: date(cal, 2026, 5, 12, 20)),
            Entry(name: "e", date: date(cal, 2026, 5, 11, 7)),
        ]
        let sections = group(entries, calendar: cal, now: now, locale: en)
        #expect(sections.map(\.dayKey) == [
            date(cal, 2026, 5, 12), date(cal, 2026, 5, 11), date(cal, 2026, 5, 10),
        ])
        #expect(sections.map { $0.items.map(\.name) } == [["b", "d"], ["e"], ["a", "c"]])
    }

    @Test("today and yesterday are labelled relative to the injected now, in German")
    func todayYesterdayGerman() {
        let cal = berlin()
        let now = date(cal, 2026, 5, 20, 12)
        let entries = [
            Entry(name: "today", date: date(cal, 2026, 5, 20, 8)),
            Entry(name: "yesterday", date: date(cal, 2026, 5, 19, 22)),
            Entry(name: "older", date: date(cal, 2026, 5, 18, 10)),
        ]
        let sections = group(entries, calendar: cal, now: now, locale: de)
        #expect(sections.map(\.label) == ["Heute", "Gestern", "Montag, 18. Mai"])
    }

    @Test("today and yesterday are labelled in English")
    func todayYesterdayEnglish() {
        let cal = berlin()
        let now = date(cal, 2026, 5, 20, 12)
        let entries = [
            Entry(name: "today", date: date(cal, 2026, 5, 20, 8)),
            Entry(name: "yesterday", date: date(cal, 2026, 5, 19, 22)),
            Entry(name: "older", date: date(cal, 2026, 5, 18, 10)),
        ]
        let sections = group(entries, calendar: cal, now: now, locale: en)
        #expect(sections.map(\.label) == ["Today", "Yesterday", "Monday, May 18"])
    }

    @Test("older days use the locale's weekday-and-date label")
    func olderDayLabels() {
        let cal = berlin()
        let now = date(cal, 2026, 5, 20, 12)
        let entry = Entry(name: "x", date: date(cal, 2026, 1, 3, 10))
        #expect(group([entry], calendar: cal, now: now, locale: de).map(\.label) == ["Samstag, 3. Januar"])
        #expect(group([entry], calendar: cal, now: now, locale: en).map(\.label) == ["Saturday, January 3"])
    }

    @Test("grouping splits at local midnight, not UTC midnight")
    func localMidnight() {
        let cal = berlin()
        let now = date(cal, 2026, 5, 20, 12)
        // 23:59 and 00:00 Berlin are on different local days, even though
        // 00:00 CEST (22:00 UTC the day before) shares a UTC day with 23:59.
        let entries = [
            Entry(name: "after", date: date(cal, 2026, 5, 20, 0, 0)),
            Entry(name: "before", date: date(cal, 2026, 5, 19, 23, 59)),
        ]
        let sections = group(entries, calendar: cal, now: now, locale: en)
        #expect(sections.map { $0.items.map(\.name) } == [["after"], ["before"]])
        #expect(sections.map(\.label) == ["Today", "Yesterday"])
    }

    @Test("the same instant lands on a different day in a different time zone")
    func timeZoneDecidesTheDay() {
        var tokyo = Calendar(identifier: .gregorian)
        tokyo.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        let cal = berlin()
        // 2026-05-19 18:00 Berlin (16:00 UTC) is 2026-05-20 01:00 in Tokyo.
        let instant = date(cal, 2026, 5, 19, 18)
        let now = date(cal, 2026, 5, 20, 12)
        let entry = Entry(name: "x", date: instant)
        #expect(group([entry], calendar: cal, now: now, locale: en).map(\.label) == ["Yesterday"])
        #expect(group([entry], calendar: tokyo, now: now, locale: en).map(\.label) == ["Today"])
    }

    @Test("spring-forward day (23h) still groups and labels as one day")
    func springForward() {
        let cal = berlin()
        // 2026-03-29: Berlin clocks jump 02:00 -> 03:00.
        let now = date(cal, 2026, 3, 30, 12)
        let entries = [
            Entry(name: "late", date: date(cal, 2026, 3, 29, 23, 30)),
            Entry(name: "early", date: date(cal, 2026, 3, 29, 1, 30)),
            Entry(name: "prev", date: date(cal, 2026, 3, 28, 23, 30)),
        ]
        let sections = group(entries, calendar: cal, now: now, locale: en)
        #expect(sections.map { $0.items.map(\.name) } == [["late", "early"], ["prev"]])
        #expect(sections.map(\.label) == ["Yesterday", "Saturday, March 28"])
    }

    @Test("fall-back day (25h) still groups and labels as one day")
    func fallBack() {
        let cal = berlin()
        // 2026-10-25: Berlin clocks go back 03:00 -> 02:00.
        let now = date(cal, 2026, 10, 26, 9)
        let entries = [
            Entry(name: "late", date: date(cal, 2026, 10, 25, 23, 30)),
            Entry(name: "early", date: date(cal, 2026, 10, 25, 0, 15)),
            Entry(name: "prev", date: date(cal, 2026, 10, 24, 23, 59)),
        ]
        let sections = group(entries, calendar: cal, now: now, locale: de)
        #expect(sections.map { $0.items.map(\.name) } == [["late", "early"], ["prev"]])
        #expect(sections.map(\.label) == ["Gestern", "Samstag, 24. Oktober"])
    }

    @Test("yesterday is found across a DST transition")
    func yesterdayAcrossDST() {
        let cal = berlin()
        // Now is the 30th just after midnight; the 29th was only 23h long.
        let now = date(cal, 2026, 3, 30, 0, 5)
        let entry = Entry(name: "x", date: date(cal, 2026, 3, 29, 0, 5))
        #expect(group([entry], calendar: cal, now: now, locale: en).map(\.label) == ["Yesterday"])
    }
}
