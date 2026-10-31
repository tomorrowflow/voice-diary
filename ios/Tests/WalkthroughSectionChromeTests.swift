import Foundation
import Testing
@testable import VoiceDiary

// IOS-A76: `isInEventLoop` decides whether WalkthroughView shows the
// persistent session chrome (timer, StatusIndicator, "Weiter"). It is a
// separate question from `isPausable`: note review and todo confirmation
// have the chrome but no Pause. The pause and speaking/listening matrices
// are covered elsewhere; this suite only pins section-chrome eligibility.

private let failedDiagnosis = ConnectionDiagnosis(
    kind: .unreachable, title: "Offline", hint: "", detail: nil, systemImage: "wifi.slash"
)

@Suite("Walkthrough section chrome eligibility")
struct WalkthroughSectionChromeTests {
    /// Distinct step, event, note and todo indices plus differing section
    /// IDs, so a payload value can never be what gates the chrome.
    private static let insideSection: [(name: String, state: WalkthroughState)] = [
        ("briefing", .briefing),
        ("calendar opener", .eventOpener(stepIndex: 1, eventIndex: 4)),
        ("calendar listening", .eventListening(stepIndex: 2, eventIndex: 5)),
        ("general opener", .generalOpener(stepIndex: 3, sectionID: "gen-a")),
        ("general listening", .generalListening(stepIndex: 4, sectionID: "gen-b")),
        ("note review", .noteReview(stepIndex: 5, noteIndex: 7)),
        ("closing opener", .voiceNoteOpener(stepIndex: 6)),
        ("closing listening", .voiceNoteListening(stepIndex: 7)),
        ("todo confirmation", .confirmingTodos(index: 2)),
    ]

    private static let outsideSection: [(name: String, state: WalkthroughState)] = [
        ("idle", .idle),
        ("calendar failure", .calendarUnavailable(failedDiagnosis)),
        ("ingesting", .ingesting),
        ("done", .done),
        ("failed", .failed("boom")),
    ]

    @Test("every stage inside a section keeps the session chrome")
    func insideSectionHasChrome() {
        for (name, state) in Self.insideSection {
            #expect(state.isInEventLoop, "\(name)")
        }
    }

    @Test("idle, calendar failure and the terminal stages have no session chrome")
    func outsideSectionHasNoChrome() {
        for (name, state) in Self.outsideSection {
            #expect(!state.isInEventLoop, "\(name)")
        }
    }

    @Test("indices and section IDs never gate the chrome")
    func payloadDoesNotGateChrome() {
        for index in [0, 1, 99, Int.max] {
            #expect(WalkthroughState.eventOpener(stepIndex: index, eventIndex: index).isInEventLoop)
            #expect(WalkthroughState.eventListening(stepIndex: index, eventIndex: index).isInEventLoop)
            #expect(WalkthroughState.noteReview(stepIndex: index, noteIndex: index).isInEventLoop)
            #expect(WalkthroughState.voiceNoteOpener(stepIndex: index).isInEventLoop)
            #expect(WalkthroughState.voiceNoteListening(stepIndex: index).isInEventLoop)
            #expect(WalkthroughState.confirmingTodos(index: index).isInEventLoop)
        }
        for sectionID in ["", "gen-a", "calendar", "ingesting"] {
            #expect(WalkthroughState.generalOpener(stepIndex: 0, sectionID: sectionID).isInEventLoop)
            #expect(WalkthroughState.generalListening(stepIndex: 0, sectionID: sectionID).isInEventLoop)
        }
        for message in ["", "boom", "briefing"] {
            #expect(!WalkthroughState.failed(message).isInEventLoop)
        }
    }

    @Test("note review and todo confirmation have the chrome without a Pause")
    func chromeIsIndependentOfPause() {
        let chromeWithoutPause: [WalkthroughState] = [
            .noteReview(stepIndex: 5, noteIndex: 7),
            .confirmingTodos(index: 2),
        ]
        for state in chromeWithoutPause {
            #expect(state.isInEventLoop, "\(state)")
            #expect(!state.isPausable, "\(state)")
        }
    }
}
