import Foundation

/// Day comparison behind the note review card's "Older" badge and
/// "Für später" button. Pure: the view supplies the `Calendar`, and owns
/// the badge copy, layout and what the buttons do.
enum NoteReviewOrphanDay {
    /// True when the note was captured on a different calendar day than
    /// the one being reviewed. A note captured after `selectedDate`'s day
    /// counts too.
    static func isOrphan(capturedAt: Date, selectedDate: Date, calendar: Calendar) -> Bool {
        !calendar.isDate(capturedAt, inSameDayAs: selectedDate)
    }
}
