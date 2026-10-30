import Foundation
import Testing
@testable import VoiceDiary

// `WalkthroughState.isPausable` decides whether the walkthrough shows its
// Pause button. Pause is offered where a recording may be in flight
// (briefing, openers, listening phases); `noteReview` and `confirmingTodos`
// have no recording to preserve, and the non-session states have nothing to
// pause. Indices and payloads are deliberately nonzero / non-empty so a rule
// keyed on index 0 or an empty payload would not pass.

private let diagnosis = ConnectionDiagnosis(
    kind: .unreachable,
    title: "Server nicht erreichbar",
    hint: "Prüfe Tailscale.",
    detail: "URLError -1004",
    systemImage: "wifi.slash",
    isRetryable: true
)

private let nonRetryableDiagnosis = ConnectionDiagnosis(
    kind: .upstreamFailure,
    title: "Kalender nicht eingerichtet",
    hint: "Graph ist nicht verbunden.",
    detail: nil,
    systemImage: "calendar.badge.exclamationmark",
    isRetryable: false
)

@Suite("Walkthrough pause eligibility")
struct PauseEligibilityTests {
    @Test("Briefing, openers and listening phases permit pause",
          arguments: [
              WalkthroughState.briefing,
              .eventOpener(stepIndex: 3, eventIndex: 2),
              .eventListening(stepIndex: 3, eventIndex: 2),
              .generalOpener(stepIndex: 4, sectionID: "general-7"),
              .generalListening(stepIndex: 4, sectionID: "general-7"),
              .voiceNoteOpener(stepIndex: 5),
              .voiceNoteListening(stepIndex: 5)
          ])
    func pausableStates(state: WalkthroughState) {
        #expect(state.isPausable)
    }

    @Test("States without a recording to preserve do not permit pause",
          arguments: [
              WalkthroughState.idle,
              .noteReview(stepIndex: 6, noteIndex: 2),
              .confirmingTodos(index: 3),
              .calendarUnavailable(diagnosis),
              .calendarUnavailable(nonRetryableDiagnosis),
              .ingesting,
              .done,
              .failed("Upload fehlgeschlagen"),
              .failed("")
          ])
    func nonPausableStates(state: WalkthroughState) {
        #expect(!state.isPausable)
    }

    @Test("Pause eligibility does not depend on the step or event index",
          arguments: [1, 2, 9, 42])
    func indexDoesNotChangeEligibility(index: Int) {
        #expect(WalkthroughState.eventOpener(stepIndex: index, eventIndex: index).isPausable)
        #expect(WalkthroughState.eventListening(stepIndex: index, eventIndex: index).isPausable)
        #expect(WalkthroughState.voiceNoteOpener(stepIndex: index).isPausable)
        #expect(WalkthroughState.voiceNoteListening(stepIndex: index).isPausable)
        #expect(!WalkthroughState.noteReview(stepIndex: index, noteIndex: index).isPausable)
        #expect(!WalkthroughState.confirmingTodos(index: index).isPausable)
    }
}
