import Foundation
import Testing
@testable import VoiceDiary

// Calendar math behind the recording-date picker. The view supplies its ISO
// calendar (Monday first) and the current time; these tests pin the month
// grid, weekday order, month stepping and day classification with fixed
// calendars and instants.

@Suite("RecordingDateCalendar")
struct RecordingDateCalendarTests {
    private static func makeCalendar(
        timeZone: String = "UTC",
        locale: String = "en_US",
        firstWeekday: Int = 2
    ) -> Calendar {
        var c = Calendar(identifier: .iso8601)
        c.timeZone = TimeZone(identifier: timeZone)!
        c.locale = Locale(identifier: locale)
        c.firstWeekday = firstWeekday
        return c
    }

    private static func date(
        _ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12, _ minute: Int = 0,
        in calendar: Calendar
    ) -> Date {
        calendar.date(from: DateComponents(
            year: year, month: month, day: day, hour: hour, minute: minute
        ))!
    }

    private static func picker(
        now: Date, calendar: Calendar = makeCalendar()
    ) -> RecordingDateCalendar {
        RecordingDateCalendar(calendar: calendar, now: now)
    }

    private func dayNumbers(_ cells: [Date?], calendar: Calendar) -> [Int?] {
        cells.map { $0.map { calendar.component(.day, from: $0) } }
    }

    // MARK: month cells

    @Test("month length, leading padding and rows", arguments: [
        // (year, month, days, leading nils, total cells)
        (2026, 1, 31, 3, 35),  // 31 days, begins Thursday
        (2026, 4, 30, 2, 35),  // 30 days, begins Wednesday
        (2026, 6, 30, 0, 35),  // begins Monday: no leading padding
        (2026, 2, 28, 6, 35),  // begins Sunday: six leading nils
        (2027, 2, 28, 0, 28),  // begins Monday, already four full rows
        (2028, 2, 29, 1, 35),  // leap February
        (2026, 8, 31, 5, 42),  // begins Saturday, six rows
    ] as [(Int, Int, Int, Int, Int)])
    func monthShape(year: Int, month: Int, days: Int, leading: Int, total: Int) {
        let calendar = Self.makeCalendar()
        let picker = Self.picker(now: Self.date(2030, 1, 1, in: calendar))
        let cells = picker.monthCells(for: Self.date(year, month, 15, in: calendar))

        #expect(cells.count == total)
        #expect(cells.count % 7 == 0)
        #expect(cells.prefix(leading).allSatisfy { $0 == nil })
        let numbers = dayNumbers(cells, calendar: calendar)
        #expect(numbers[leading] == 1)
        #expect(numbers.compactMap { $0 } == Array(1...days))
        #expect(cells[(leading + days)...].allSatisfy { $0 == nil })
        #expect(cells[(leading + days)...].count == total - leading - days)
    }

    @Test("every day cell is a distinct day of the visible month")
    func cellsAreInVisibleMonth() {
        let calendar = Self.makeCalendar()
        let picker = Self.picker(now: Self.date(2030, 1, 1, in: calendar))
        let cells = picker.monthCells(for: Self.date(2026, 5, 31, 23, 59, in: calendar))

        for case let day? in cells {
            #expect(calendar.component(.month, from: day) == 5)
            #expect(calendar.component(.year, from: day) == 2026)
            #expect(calendar.startOfDay(for: day) == day)
        }
    }

    @Test("Sunday-first calendars shift the leading padding")
    func sundayFirstPadding() {
        let calendar = Self.makeCalendar(firstWeekday: 1)
        let picker = Self.picker(now: Self.date(2030, 1, 1, in: calendar), calendar: calendar)
        // February 2026 begins on a Sunday: no padding when Sunday is first.
        let cells = picker.monthCells(for: Self.date(2026, 2, 10, in: calendar))
        #expect(dayNumbers(cells, calendar: calendar) == Array(1...28).map { Optional($0) })
    }

    @Test("months spanning a DST change keep one midnight-aligned cell per day", arguments: [
        ("Europe/Berlin", 2026, 3, 31),   // spring forward 29 March
        ("Europe/Berlin", 2026, 10, 31),  // fall back 25 October
        ("America/Sao_Paulo", 2018, 11, 30),  // DST began at midnight on 4 November
    ] as [(String, Int, Int, Int)])
    func dstMonths(zone: String, year: Int, month: Int, days: Int) {
        let calendar = Self.makeCalendar(timeZone: zone)
        let picker = Self.picker(now: Self.date(2030, 1, 1, in: calendar), calendar: calendar)
        let cells = picker.monthCells(for: Self.date(year, month, 10, in: calendar))

        #expect(dayNumbers(cells, calendar: calendar).compactMap { $0 } == Array(1...days))
        for case let day? in cells {
            #expect(calendar.component(.month, from: day) == month)
            #expect(calendar.startOfDay(for: day) == day)
        }
    }

    // MARK: weekday order

    @Test("English weekdays start on Monday")
    func englishWeekdayOrder() {
        let calendar = Self.makeCalendar(locale: "en_US")
        let picker = Self.picker(now: Self.date(2026, 5, 1, in: calendar), calendar: calendar)
        #expect(picker.orderedWeekdaySymbols == ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"])
    }

    @Test("German weekdays start on Monday")
    func germanWeekdayOrder() {
        let calendar = Self.makeCalendar(locale: "de_DE")
        let picker = Self.picker(now: Self.date(2026, 5, 1, in: calendar), calendar: calendar)
        #expect(picker.orderedWeekdaySymbols.count == 7)
        #expect(picker.orderedWeekdaySymbols.map { $0.prefix(2) }
            == ["Mo", "Di", "Mi", "Do", "Fr", "Sa", "So"])
    }

    @Test("weekday order follows the calendar's first weekday")
    func weekdayOrderRotates() {
        let calendar = Self.makeCalendar(locale: "en_US", firstWeekday: 1)
        let picker = Self.picker(now: Self.date(2026, 5, 1, in: calendar), calendar: calendar)
        #expect(picker.orderedWeekdaySymbols == ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"])
    }

    // MARK: month stepping

    @Test("stepping crosses year boundaries in both directions")
    func yearBoundaryStepping() {
        let calendar = Self.makeCalendar()
        let picker = Self.picker(now: Self.date(2030, 1, 1, in: calendar))

        let december = Self.date(2025, 12, 1, 0, 0, in: calendar)
        let january = picker.steppedMonth(from: december, by: 1)
        #expect(january == Self.date(2026, 1, 1, 0, 0, in: calendar))

        let backToDecember = picker.steppedMonth(from: january!, by: -1)
        #expect(backToDecember == december)
    }

    @Test("can step forward while the next month has started")
    func canStepForwardWhenNextMonthStarted() {
        let calendar = Self.makeCalendar()
        // now is 1 June 00:00: the June month start counts as reached.
        let picker = Self.picker(now: Self.date(2026, 6, 1, 0, 0, in: calendar))
        #expect(picker.canStepForward(from: Self.date(2026, 5, 1, 0, 0, in: calendar)))
        #expect(!picker.canStepForward(from: Self.date(2026, 6, 1, 0, 0, in: calendar)))
    }

    @Test("cannot step into a month that has not started")
    func cannotStepIntoFutureMonth() {
        let calendar = Self.makeCalendar()
        let picker = Self.picker(now: Self.date(2026, 5, 31, 23, 59, in: calendar))
        #expect(!picker.canStepForward(from: Self.date(2026, 5, 1, 0, 0, in: calendar)))
        #expect(picker.canStepForward(from: Self.date(2026, 4, 1, 0, 0, in: calendar)))
    }

    @Test("December to January is gated by the January start")
    func decemberToJanuaryCap() {
        let calendar = Self.makeCalendar()
        let december = Self.date(2025, 12, 1, 0, 0, in: calendar)
        let beforeNewYear = Self.picker(now: Self.date(2025, 12, 31, 23, 59, in: calendar))
        let afterNewYear = Self.picker(now: Self.date(2026, 1, 1, 0, 0, in: calendar))
        #expect(!beforeNewYear.canStepForward(from: december))
        #expect(afterNewYear.canStepForward(from: december))
    }

    @Test("forward cap uses the calendar's time zone")
    func forwardCapUsesCalendarTimeZone() {
        let berlin = Self.makeCalendar(timeZone: "Europe/Berlin")
        // 23:30 UTC on 31 May is already 01:30 on 1 June in Berlin.
        let instant = Self.date(2026, 5, 31, 23, 30, in: Self.makeCalendar())
        let may = Self.date(2026, 5, 1, 0, 0, in: berlin)
        #expect(Self.picker(now: instant, calendar: berlin).canStepForward(from: may))
        #expect(!Self.picker(now: instant).canStepForward(from: Self.date(2026, 5, 1, 0, 0, in: Self.makeCalendar())))
    }

    // MARK: day classification

    @Test("today is selectable, tomorrow is disabled")
    func todaySelectableFutureDisabled() {
        let calendar = Self.makeCalendar()
        let now = Self.date(2026, 5, 10, 15, 30, in: calendar)
        let picker = Self.picker(now: now)
        let selected = Self.date(2026, 5, 3, in: calendar)

        let today = picker.classify(day: calendar.startOfDay(for: now), selectedDate: selected)
        #expect(today == .init(isSelected: false, isToday: true, isFuture: false))

        let tomorrow = picker.classify(
            day: Self.date(2026, 5, 11, 0, 0, in: calendar), selectedDate: selected)
        #expect(tomorrow == .init(isSelected: false, isToday: false, isFuture: true))

        let yesterday = picker.classify(
            day: Self.date(2026, 5, 9, 0, 0, in: calendar), selectedDate: selected)
        #expect(yesterday == .init(isSelected: false, isToday: false, isFuture: false))
    }

    @Test("the last instant of today is still today")
    func endOfTodayIsToday() {
        let calendar = Self.makeCalendar()
        let now = Self.date(2026, 5, 10, 23, 59, in: calendar)
        let picker = Self.picker(now: now)
        let state = picker.classify(
            day: Self.date(2026, 5, 10, 0, 0, in: calendar), selectedDate: now)
        #expect(state == .init(isSelected: true, isToday: true, isFuture: false))
    }

    @Test("selection matches on the same day regardless of time")
    func selectionIgnoresTime() {
        let calendar = Self.makeCalendar()
        let picker = Self.picker(now: Self.date(2026, 5, 20, in: calendar))
        let day = Self.date(2026, 5, 4, 0, 0, in: calendar)
        let state = picker.classify(day: day, selectedDate: Self.date(2026, 5, 4, 22, 45, in: calendar))
        #expect(state.isSelected)
        #expect(!state.isFuture)
    }

    @Test("a selected future day is still reported as future")
    func selectedFutureDay() {
        let calendar = Self.makeCalendar()
        let picker = Self.picker(now: Self.date(2026, 5, 10, in: calendar))
        let day = Self.date(2026, 5, 12, 0, 0, in: calendar)
        let state = picker.classify(day: day, selectedDate: day)
        #expect(state == .init(isSelected: true, isToday: false, isFuture: true))
    }

    @Test("classification across the Berlin DST changes")
    func dstBoundaryClassification() {
        let berlin = Self.makeCalendar(timeZone: "Europe/Berlin")
        let selected = Self.date(2026, 1, 1, in: berlin)

        // Fall back: 25 October 2026 has 25 hours; 23:30 is still that day.
        let fallNow = Self.date(2026, 10, 25, 23, 30, in: berlin)
        let fall = Self.picker(now: fallNow, calendar: berlin)
        #expect(fall.classify(day: berlin.startOfDay(for: fallNow), selectedDate: selected)
            == .init(isSelected: false, isToday: true, isFuture: false))
        #expect(fall.classify(day: Self.date(2026, 10, 26, 0, 0, in: berlin), selectedDate: selected).isFuture)

        // Spring forward: 29 March 2026 has 23 hours; 00:30 is still that day.
        let springNow = Self.date(2026, 3, 29, 0, 30, in: berlin)
        let spring = Self.picker(now: springNow, calendar: berlin)
        #expect(spring.classify(day: berlin.startOfDay(for: springNow), selectedDate: selected)
            == .init(isSelected: false, isToday: true, isFuture: false))
        #expect(spring.classify(day: Self.date(2026, 3, 30, 0, 0, in: berlin), selectedDate: selected).isFuture)
        #expect(!spring.classify(day: Self.date(2026, 3, 28, 0, 0, in: berlin), selectedDate: selected).isFuture)
    }

    // MARK: month start

    @Test("monthStart truncates to the first of the month")
    func monthStartTruncates() {
        let calendar = Self.makeCalendar(timeZone: "Europe/Berlin")
        let picker = Self.picker(now: Self.date(2026, 5, 1, in: calendar), calendar: calendar)
        #expect(picker.monthStart(containing: Self.date(2026, 10, 25, 23, 59, in: calendar))
            == Self.date(2026, 10, 1, 0, 0, in: calendar))
    }
}
