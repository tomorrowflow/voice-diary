import Testing
@testable import VoiceDiary

// Duration label on a calendar event row in the walkthrough. The view
// passes the event's whole minutes; these tests pin the text shown.

@Suite("CalendarEventDurationText")
struct CalendarEventDurationTextTests {
    @Test("nonpositive minutes show nothing", arguments: [-30, -1, 0])
    func nonpositiveIsEmpty(minutes: Int) {
        #expect(CalendarEventDurationText.label(minutes: minutes) == "")
    }

    @Test("under an hour shows minutes", arguments: [(1, "1 min"), (59, "59 min")])
    func minutesOnly(minutes: Int, expected: String) {
        #expect(CalendarEventDurationText.label(minutes: minutes) == expected)
    }

    @Test("whole hours show hours only", arguments: [(60, "1 h"), (120, "2 h")])
    func wholeHours(minutes: Int, expected: String) {
        #expect(CalendarEventDurationText.label(minutes: minutes) == expected)
    }

    @Test("hours with a remainder zero-pad the minutes", arguments: [(61, "1 h 01"), (90, "1 h 30"), (121, "2 h 01")])
    func hoursAndMinutes(minutes: Int, expected: String) {
        #expect(CalendarEventDurationText.label(minutes: minutes) == expected)
    }
}
