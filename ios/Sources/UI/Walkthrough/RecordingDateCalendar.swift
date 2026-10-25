import Foundation

/// Calendar math behind the recording-date picker grid. Pure: the view
/// supplies the `Calendar` (ISO, Monday first, app locale) and the current
/// time, and owns layout, styling and the selection/dismiss behaviour.
struct RecordingDateCalendar {
    /// How a single day cell should be treated.
    struct DayState: Equatable {
        let isSelected: Bool
        let isToday: Bool
        let isFuture: Bool
    }

    let calendar: Calendar
    let now: Date

    /// Short standalone weekday symbols starting at the calendar's first
    /// weekday.
    var orderedWeekdaySymbols: [String] {
        let symbols = calendar.shortStandaloneWeekdaySymbols
        let firstIdx = (calendar.firstWeekday - 1) % 7
        return (0..<7).map { symbols[(firstIdx + $0) % 7] }
    }

    /// First instant of the month containing `date`.
    func monthStart(containing date: Date) -> Date? {
        calendar.date(from: calendar.dateComponents([.year, .month], from: date))
    }

    /// `month` moved by `delta` months, or nil if the calendar can't.
    func steppedMonth(from month: Date, by delta: Int) -> Date? {
        calendar.date(byAdding: .month, value: delta, to: month)
    }

    /// True when the month after `month` has already started.
    func canStepForward(from month: Date) -> Bool {
        guard let next = steppedMonth(from: month, by: 1) else { return false }
        let startOfNext = monthStart(containing: next) ?? next
        return startOfNext <= now
    }

    /// Returns 7-aligned cells for the month containing `month`: leading
    /// nils for days before the 1st, then each day, padded with trailing
    /// nils so the grid is rectangular.
    func monthCells(for month: Date) -> [Date?] {
        guard
            let monthStart = monthStart(containing: month),
            let range = calendar.range(of: .day, in: .month, for: monthStart)
        else { return [] }
        let weekdayOfFirst = calendar.component(.weekday, from: monthStart)
        let leading = (weekdayOfFirst - calendar.firstWeekday + 7) % 7
        var cells: [Date?] = Array(repeating: nil, count: leading)
        for day in range {
            if let d = calendar.date(byAdding: .day, value: day - 1, to: monthStart) {
                cells.append(d)
            }
        }
        while cells.count % 7 != 0 { cells.append(nil) }
        return cells
    }

    func classify(day: Date, selectedDate: Date) -> DayState {
        let isToday = calendar.isDate(day, inSameDayAs: now)
        return DayState(
            isSelected: calendar.isDate(day, inSameDayAs: selectedDate),
            isToday: isToday,
            isFuture: day > calendar.startOfDay(for: now) && !isToday
        )
    }
}
