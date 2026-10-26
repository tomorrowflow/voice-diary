import Foundation

// Duration label on a calendar event row in the walkthrough. Pure over
// whole minutes so it can be tested without a view; the spoken form
// lives in `OpenerTemplates.spokenDuration`.

enum CalendarEventDurationText {
    /// "" for nonpositive minutes, "45 min" under an hour, "2 h" on the
    /// hour, otherwise "1 h 05" (minutes zero-padded).
    static func label(minutes m: Int) -> String {
        if m <= 0 { return "" }
        if m < 60 { return "\(m) min" }
        if m % 60 == 0 { return "\(m / 60) h" }
        return String(format: "%d h %02d", m / 60, m % 60)
    }
}
