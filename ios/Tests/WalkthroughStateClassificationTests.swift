import Foundation
import Testing
@testable import VoiceDiary

// IOS-A73: `isSpeaking`, `isListening` and `isInEventLoop` drive the shared
// walkthrough chrome (timer, StatusIndicator, single "Weiter" button). The
// expectations below are written out per state rather than derived from the
// getters, so a state moving between classes shows up as a failing row.

private struct Classification: Equatable, CustomStringConvertible {
    let speaking: Bool
    let listening: Bool
    let inEventLoop: Bool

    init(_ state: WalkthroughState) {
        speaking = state.isSpeaking
        listening = state.isListening
        inEventLoop = state.isInEventLoop
    }

    init(speaking: Bool, listening: Bool, inEventLoop: Bool) {
        self.speaking = speaking
        self.listening = listening
        self.inEventLoop = inEventLoop
    }

    var description: String {
        "speaking=\(speaking) listening=\(listening) inEventLoop=\(inEventLoop)"
    }

    static let speakingInLoop = Classification(speaking: true, listening: false, inEventLoop: true)
    static let listeningInLoop = Classification(speaking: false, listening: true, inEventLoop: true)
    static let silentInLoop = Classification(speaking: false, listening: false, inEventLoop: true)
    static let outsideLoop = Classification(speaking: false, listening: false, inEventLoop: false)
}

private let diagnosis = ConnectionDiagnosis(
    kind: .unreachable, title: "Offline", hint: "", detail: nil, systemImage: "wifi.slash"
)

@Suite("Walkthrough state classification")
struct WalkthroughStateClassificationTests {
    @Test("every state falls into exactly its expected speaking / listening / event-loop class")
    func classificationMatrix() {
        let expected: [(WalkthroughState, Classification)] = [
            (.idle, .outsideLoop),
            (.briefing, .speakingInLoop),
            (.eventOpener(stepIndex: 1, eventIndex: 0), .speakingInLoop),
            (.eventListening(stepIndex: 1, eventIndex: 0), .listeningInLoop),
            (.generalOpener(stepIndex: 2, sectionID: "gen-a"), .speakingInLoop),
            (.generalListening(stepIndex: 2, sectionID: "gen-a"), .listeningInLoop),
            (.noteReview(stepIndex: 3, noteIndex: 0), .silentInLoop),
            (.voiceNoteOpener(stepIndex: 4), .speakingInLoop),
            (.voiceNoteListening(stepIndex: 4), .listeningInLoop),
            (.confirmingTodos(index: 0), .silentInLoop),
            (.calendarUnavailable(diagnosis), .outsideLoop),
            (.ingesting, .outsideLoop),
            (.done, .outsideLoop),
            (.failed("boom"), .outsideLoop),
        ]
        for (state, classification) in expected {
            #expect(Classification(state) == classification, "\(state)")
        }
    }

    @Test("only the three listening variants listen")
    func onlyListeningVariantsListen() {
        let listening: [WalkthroughState] = [
            .eventListening(stepIndex: 0, eventIndex: 0),
            .generalListening(stepIndex: 0, sectionID: "g"),
            .voiceNoteListening(stepIndex: 0),
        ]
        let notListening: [WalkthroughState] = [
            .idle, .briefing,
            .eventOpener(stepIndex: 0, eventIndex: 0),
            .generalOpener(stepIndex: 0, sectionID: "g"),
            .noteReview(stepIndex: 0, noteIndex: 0),
            .voiceNoteOpener(stepIndex: 0),
            .confirmingTodos(index: 0),
            .calendarUnavailable(diagnosis),
            .ingesting, .done, .failed("x"),
        ]
        for state in listening { #expect(state.isListening, "\(state)") }
        for state in notListening { #expect(!state.isListening, "\(state)") }
    }

    @Test("only the briefing and the three openers speak")
    func onlyBriefingAndOpenersSpeak() {
        let speaking: [WalkthroughState] = [
            .briefing,
            .eventOpener(stepIndex: 0, eventIndex: 0),
            .generalOpener(stepIndex: 0, sectionID: "g"),
            .voiceNoteOpener(stepIndex: 0),
        ]
        let silent: [WalkthroughState] = [
            .idle,
            .eventListening(stepIndex: 0, eventIndex: 0),
            .generalListening(stepIndex: 0, sectionID: "g"),
            .noteReview(stepIndex: 0, noteIndex: 0),
            .voiceNoteListening(stepIndex: 0),
            .confirmingTodos(index: 0),
            .calendarUnavailable(diagnosis),
            .ingesting, .done, .failed("x"),
        ]
        for state in speaking { #expect(state.isSpeaking, "\(state)") }
        for state in silent { #expect(!state.isSpeaking, "\(state)") }
    }

    @Test("the event loop is the speaking and listening states plus noteReview and confirmingTodos")
    func eventLoopMembership() {
        let inLoop: [WalkthroughState] = [
            .briefing,
            .eventOpener(stepIndex: 0, eventIndex: 0),
            .eventListening(stepIndex: 0, eventIndex: 0),
            .generalOpener(stepIndex: 0, sectionID: "g"),
            .generalListening(stepIndex: 0, sectionID: "g"),
            .noteReview(stepIndex: 0, noteIndex: 0),
            .voiceNoteOpener(stepIndex: 0),
            .voiceNoteListening(stepIndex: 0),
            .confirmingTodos(index: 0),
        ]
        let outside: [WalkthroughState] = [
            .idle, .calendarUnavailable(diagnosis), .ingesting, .done, .failed("x"),
        ]
        for state in inLoop { #expect(state.isInEventLoop, "\(state)") }
        for state in outside { #expect(!state.isInEventLoop, "\(state)") }
    }

    @Test("classification does not depend on step, event, note or todo indices or section IDs")
    func independentOfIndexPayloads() {
        for index in [0, 1, 7, 42, Int.max] {
            #expect(Classification(.eventOpener(stepIndex: index, eventIndex: index)) == .speakingInLoop)
            #expect(Classification(.eventListening(stepIndex: index, eventIndex: 0)) == .listeningInLoop)
            #expect(Classification(.eventListening(stepIndex: 0, eventIndex: index)) == .listeningInLoop)
            #expect(Classification(.noteReview(stepIndex: index, noteIndex: index)) == .silentInLoop)
            #expect(Classification(.voiceNoteOpener(stepIndex: index)) == .speakingInLoop)
            #expect(Classification(.voiceNoteListening(stepIndex: index)) == .listeningInLoop)
            #expect(Classification(.confirmingTodos(index: index)) == .silentInLoop)
        }
        for sectionID in ["", "general-1", "ünïcode ✓", String(repeating: "x", count: 500)] {
            #expect(Classification(.generalOpener(stepIndex: 5, sectionID: sectionID)) == .speakingInLoop)
            #expect(Classification(.generalListening(stepIndex: 5, sectionID: sectionID)) == .listeningInLoop)
        }
    }

    @Test("classification does not depend on the failure message or diagnosis")
    func independentOfFailurePayloads() {
        for message in ["", "boom", "Timeout — Kalender", String(repeating: "e", count: 500)] {
            #expect(Classification(.failed(message)) == .outsideLoop)
        }
        let kinds: [ConnectionDiagnosis.Kind] = [
            .notConfigured, .unreachable, .offline, .timeout, .unauthorised,
            .upstreamFailure, .serverError, .clientError, .malformedResponse, .unknown,
        ]
        for kind in kinds {
            let state = WalkthroughState.calendarUnavailable(
                ConnectionDiagnosis(kind: kind, title: "t", hint: "h", detail: "d", systemImage: "wifi.slash")
            )
            #expect(Classification(state) == .outsideLoop, "\(kind)")
        }
    }
}
