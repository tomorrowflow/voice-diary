import Foundation

// "09:00 – 09:30" line on the walkthrough's calendar event card. Pure over
// optional dates and a time zone so the rule can be tested without a view;
// `EventCard` passes the current default zone.

enum CalendarEventTimeRange {
    /// "HH:mm – HH:mm" in `timeZone`, or "" when either date is missing.
    /// Overnight and reversed ranges render as given.
    static func text(start: Date?, end: Date?, timeZone: TimeZone) -> String {
        guard let start, let end else { return "" }
        // Built per call because the zone is an input; a card shows one range.
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "de_DE")
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH:mm"
        return "\(formatter.string(from: start)) – \(formatter.string(from: end))"
    }
}
