import Foundation
import Testing
@testable import VoiceDiary

// Sequencing of the implicit-todo confirmation (candidate progression,
// verdicts, voice answers) against a fake host — no audio, TTS or network.

@MainActor
private final class FakeTodoHost: TodoConfirmationHost {
    struct Prompt: Equatable {
        let role: String
        let segmentID: String?
        let text: String
    }

    struct Rejected: Equatable {
        let text: String
        let sourceSegmentID: String?
    }

    /// What the next `recordTodoAnswer` call does.
    enum Answer {
        /// Resolves with this recording and transcript.
        case spoken(String)
        case silent
        case hardTimeout
        /// Transcription fails after a recording.
        case transcribeFails
        /// Moves the dialog on to another candidate while recording.
        case staleAfterMove(to: Int)
        /// Waits until the flow cancels the capture.
        case hangUntilCancelled
    }

    var confirmationLanguage: OpenerLanguage = .de
    var confirmingTodoIndex: Int?
    var answers: [Answer] = []
    var pendingTranscript: String?

    private(set) var spoken: [String] = []
    private(set) var prompts: [Prompt] = []
    private(set) var confirmed: [Todo] = []
    private(set) var rejected: [Rejected] = []
    private(set) var finishCount = 0
    private(set) var settleCount = 0
    private(set) var recordingCancelCount = 0
    private(set) var answerRequests: [Int] = []

    func showTodoCandidate(at index: Int) { confirmingTodoIndex = index }

    func recordTodoConfirmed(_ todo: Todo) { confirmed.append(todo) }

    func recordTodoRejected(text: String, sourceSegmentID: String?) {
        rejected.append(Rejected(text: text, sourceSegmentID: sourceSegmentID))
    }

    func recordTodoPrompt(role: String, segmentID: String?, text: String) {
        prompts.append(Prompt(role: role, segmentID: segmentID, text: text))
    }

    func settleSpeechBeforeIntro() async { settleCount += 1 }

    func speakTodoLine(_ text: String, language: OpenerLanguage) async { spoken.append(text) }

    func recordTodoAnswer(forCandidateIndex index: Int) async -> TodoAnswerRecording {
        answerRequests.append(index)
        guard !answers.isEmpty else { return .aborted }
        switch answers.removeFirst() {
        case .spoken(let transcript):
            pendingTranscript = transcript
            return .recorded(URL(fileURLWithPath: "/tmp/confirm_\(index).m4a"))
        case .silent:
            return .silent
        case .hardTimeout:
            return .hardTimeout
        case .transcribeFails:
            pendingTranscript = nil
            return .recorded(URL(fileURLWithPath: "/tmp/confirm_\(index).m4a"))
        case .staleAfterMove(let target):
            confirmingTodoIndex = target
            pendingTranscript = "ja"
            return .recorded(URL(fileURLWithPath: "/tmp/confirm_\(index).m4a"))
        case .hangUntilCancelled:
            while !Task.isCancelled { await Task.yield() }
            return .aborted
        }
    }

    struct TranscribeFailure: Error {}

    func transcribeTodoAnswer(at url: URL) async throws -> String {
        guard let text = pendingTranscript else { throw TranscribeFailure() }
        return text
    }

    func cancelTodoAnswerRecording() async { recordingCancelCount += 1 }

    func finishAfterTodoConfirmation() async {
        finishCount += 1
        confirmingTodoIndex = nil
    }
}

@MainActor
private func makeFlow(
    texts: [String] = ["Stephan anrufen", "Bericht senden", "Doku prüfen"],
    answers: [FakeTodoHost.Answer] = []
) -> (flow: TodoConfirmationFlow, host: FakeTodoHost) {
    let host = FakeTodoHost()
    host.answers = answers
    let flow = TodoConfirmationFlow()
    flow.host = host
    flow.add(texts.enumerated().map { i, text in
        Todo(text: text, type: "implicit", source_segment_id: "s0\(i)", source_quote: "quote \(i)")
    })
    return (flow, host)
}

@MainActor
@Suite("TodoConfirmationFlow")
struct TodoConfirmationFlowTests {

    // MARK: Progression

    @Test("begin speaks the intro, then prompts the first candidate")
    func beginSpeaksIntroThenFirstPrompt() async {
        let (flow, host) = makeFlow()
        await flow.begin()
        #expect(host.settleCount == 1)
        #expect(host.spoken == [
            TodoConfirmationFlow.introLine(language: .de),
            "1 von 3: Soll ich \u{201E}Stephan anrufen\u{201C} übernehmen?",
        ])
        #expect(host.confirmingTodoIndex == 0)
        #expect(flow.progress?.index == 0)
        #expect(flow.progress?.total == 3)
        #expect(flow.currentCandidate?.text == "Stephan anrufen")
        #expect(host.finishCount == 0)
    }

    @Test("each verdict moves to the next candidate; the last hands off to the upload once")
    func progressionEndsInSingleUploadHandoff() async {
        let (flow, host) = makeFlow()
        await flow.begin()
        await flow.confirmCurrent()
        #expect(host.confirmingTodoIndex == 1)
        #expect(flow.currentCandidate?.text == "Bericht senden")
        await flow.rejectCurrent()
        #expect(host.confirmingTodoIndex == 2)
        #expect(host.finishCount == 0)
        await flow.confirmCurrent()
        #expect(host.finishCount == 1)
        #expect(flow.currentCandidate == nil)
        #expect(flow.progress == nil)
        // A late verdict after the hand-off does nothing.
        await flow.confirmCurrent()
        await flow.rejectCurrent()
        #expect(host.finishCount == 1)
        #expect(host.confirmed.count == 2)
        #expect(host.rejected.count == 1)
    }

    @Test("a single candidate is prompted without a progress anchor and ends in the upload")
    func singleCandidate() async {
        let (flow, host) = makeFlow(texts: ["Stephan anrufen"])
        await flow.begin()
        #expect(host.spoken.last == "Soll ich \u{201E}Stephan anrufen\u{201C} übernehmen?")
        await flow.confirmCurrent()
        #expect(host.finishCount == 1)
    }

    @Test("reset drops the candidates")
    func resetDropsCandidates() {
        let (flow, _) = makeFlow()
        #expect(flow.hasCandidates)
        flow.reset()
        #expect(!flow.hasCandidates)
        #expect(flow.candidates.isEmpty)
    }

    // MARK: Verdicts

    @Test("confirm keeps the candidate as extracted and records the verdict prompt")
    func confirmKeepsCandidate() async {
        let (flow, host) = makeFlow()
        await flow.begin()
        await flow.confirmCurrent()
        #expect(host.confirmed.count == 1)
        #expect(host.confirmed[0].text == "Stephan anrufen")
        #expect(host.confirmed[0].source_segment_id == "s00")
        #expect(host.confirmed[0].source_quote == "quote 0")
        #expect(host.rejected.isEmpty)
        #expect(host.prompts.contains(.init(role: "todo_confirmed", segmentID: "s00", text: "Stephan anrufen")))
    }

    @Test("reject records the rejected text and its segment")
    func rejectRecordsRejection() async {
        let (flow, host) = makeFlow()
        await flow.begin()
        await flow.rejectCurrent()
        #expect(host.confirmed.isEmpty)
        #expect(host.rejected == [.init(text: "Stephan anrufen", sourceSegmentID: "s00")])
        #expect(host.prompts.contains(.init(role: "todo_rejected", segmentID: "s00", text: "Stephan anrufen")))
    }

    @Test("refine confirms the trimmed text as an implicit todo from the same segment")
    func refineConfirmsTrimmedText() async {
        let (flow, host) = makeFlow()
        await flow.begin()
        await flow.refineCurrent("  Stephan morgen anrufen \n")
        #expect(host.rejected.isEmpty)
        #expect(host.confirmed.count == 1)
        let todo = host.confirmed[0]
        #expect(todo.text == "Stephan morgen anrufen")
        #expect(todo.type == "implicit")
        #expect(todo.status == "Offen")
        #expect(todo.source_segment_id == "s00")
        #expect(todo.source_quote == nil)
        #expect(todo.due == TodoExtractor.parseDueDate(in: "Stephan morgen anrufen", language: "de"))
        #expect(todo.due != nil)
        #expect(host.prompts.contains(.init(role: "todo_refined", segmentID: "s00", text: "Stephan morgen anrufen")))
        #expect(host.confirmingTodoIndex == 1)
    }

    @Test("refine parses the due date in the confirmation language")
    func refineUsesConfirmationLanguage() async {
        let (flow, host) = makeFlow()
        host.confirmationLanguage = .en
        await flow.begin()
        await flow.refineCurrent("Call Stephan tomorrow")
        #expect(host.confirmed[0].due == TodoExtractor.parseDueDate(in: "Call Stephan tomorrow", language: "en"))
    }

    @Test("an empty or blank refinement rejects the candidate instead")
    func emptyRefinementRejects() async {
        let (flow, host) = makeFlow()
        await flow.begin()
        await flow.refineCurrent("   \n ")
        #expect(host.confirmed.isEmpty)
        #expect(host.rejected == [.init(text: "Stephan anrufen", sourceSegmentID: "s00")])
        #expect(host.prompts.contains(.init(role: "todo_rejected", segmentID: "s00", text: "Stephan anrufen")))
        #expect(!host.prompts.contains { $0.role == "todo_refined" })
        #expect(host.confirmingTodoIndex == 1)
    }

    @Test("skip (Weiter) is a rejection and moves on")
    func skipRejectsAndAdvances() async {
        let (flow, host) = makeFlow()
        await flow.begin()
        await flow.rejectCurrent()
        #expect(host.rejected.count == 1)
        #expect(host.confirmingTodoIndex == 1)
        #expect(host.spoken.last == "2 von 3: Soll ich \u{201E}Bericht senden\u{201C} übernehmen?")
    }

    @Test("verdicts outside the confirmation pass are ignored")
    func verdictsOutsideConfirmationAreIgnored() async {
        let (flow, host) = makeFlow()
        await flow.confirmCurrent()
        await flow.rejectCurrent()
        await flow.refineCurrent("anders")
        #expect(host.confirmed.isEmpty)
        #expect(host.rejected.isEmpty)
        #expect(host.prompts.isEmpty)
        #expect(host.finishCount == 0)
    }

    // MARK: Voice answers

    @Test("a spoken yes confirms the candidate")
    func spokenYesConfirms() async {
        let (flow, host) = makeFlow(answers: [.spoken("ja")])
        await flow.begin()
        await flow.awaitAnswerCapture()
        #expect(host.answerRequests.first == 0)
        #expect(host.confirmed.map(\.text) == ["Stephan anrufen"])
        #expect(host.prompts.contains(.init(role: "todo_answer_voice", segmentID: "s00", text: "ja")))
        #expect(host.confirmingTodoIndex == 1)
    }

    @Test("a spoken no rejects the candidate")
    func spokenNoRejects() async {
        let (flow, host) = makeFlow(answers: [.spoken("nein")])
        await flow.begin()
        await flow.awaitAnswerCapture()
        #expect(host.rejected.map(\.text) == ["Stephan anrufen"])
        #expect(host.confirmed.isEmpty)
    }

    @Test("a spoken refinement confirms the refined text")
    func spokenRefinementConfirmsRefinedText() async {
        let (flow, host) = makeFlow(answers: [.spoken("Stephan morgen früh anrufen wegen der Demo")])
        await flow.begin()
        await flow.awaitAnswerCapture()
        #expect(host.confirmed.map(\.text) == ["Stephan morgen früh anrufen wegen der demo"])
        #expect(host.confirmed.first?.type == "implicit")
        #expect(host.rejected.isEmpty)
    }

    @Test("an unclassifiable answer rejects the candidate")
    func unknownAnswerRejects() async {
        let (flow, host) = makeFlow(answers: [.spoken("anders")])
        await flow.begin()
        await flow.awaitAnswerCapture()
        #expect(host.rejected.map(\.text) == ["Stephan anrufen"])
        #expect(host.confirmed.isEmpty)
    }

    @Test("silence, a hard timeout and a failed transcription each reject")
    func silenceTimeoutAndTranscribeFailureReject() async {
        let (flow, host) = makeFlow(answers: [.silent, .hardTimeout, .transcribeFails])
        await flow.begin()
        await flow.awaitAnswerCapture()
        #expect(host.rejected.map(\.text) == ["Stephan anrufen", "Bericht senden", "Doku prüfen"])
        #expect(host.confirmed.isEmpty)
        #expect(host.finishCount == 1)
    }

    @Test("each candidate gets its own answer capture, in order, until the upload")
    func answersWalkAllCandidates() async {
        let (flow, host) = makeFlow(answers: [.spoken("ja"), .spoken("nein"), .spoken("ja")])
        await flow.begin()
        await flow.awaitAnswerCapture()
        #expect(host.answerRequests == [0, 1, 2])
        #expect(host.confirmed.map(\.text) == ["Stephan anrufen", "Doku prüfen"])
        #expect(host.rejected.map(\.text) == ["Bericht senden"])
        #expect(host.finishCount == 1)
    }

    @Test("an answer that arrives after the dialog moved on is dropped")
    func staleAnswerIsDropped() async {
        let (flow, host) = makeFlow(answers: [.staleAfterMove(to: 2)])
        await flow.begin()
        await flow.awaitAnswerCapture()
        #expect(host.confirmed.isEmpty)
        #expect(host.rejected.isEmpty)
        #expect(!host.prompts.contains { $0.role == "todo_answer_voice" })
        #expect(host.confirmingTodoIndex == 2)
        #expect(host.finishCount == 0)
    }

    @Test("cancelling the capture yields no verdict")
    func cancelledAnswerYieldsNoVerdict() async {
        let (flow, host) = makeFlow(answers: [.hangUntilCancelled])
        await flow.begin()
        await flow.cancelAnswerCapture()
        await flow.awaitAnswerCapture()
        #expect(host.recordingCancelCount >= 1)
        #expect(host.confirmed.isEmpty)
        #expect(host.rejected.isEmpty)
        #expect(host.confirmingTodoIndex == 0)
        #expect(host.finishCount == 0)
    }

    @Test("a manual verdict cancels the capture that was listening")
    func manualVerdictCancelsCapture() async {
        let (flow, host) = makeFlow(answers: [.hangUntilCancelled])
        await flow.begin()
        await flow.confirmCurrent()
        #expect(host.recordingCancelCount >= 1)
        #expect(host.confirmed.map(\.text) == ["Stephan anrufen"])
        #expect(host.confirmingTodoIndex == 1)
        #expect(host.rejected.isEmpty)
    }

    @Test("a capture that cannot record leaves the candidate waiting")
    func abortedRecordingLeavesCandidate() async {
        let (flow, host) = makeFlow()
        await flow.begin()
        await flow.awaitAnswerCapture()
        #expect(host.answerRequests == [0])
        #expect(host.confirmed.isEmpty)
        #expect(host.rejected.isEmpty)
        #expect(host.confirmingTodoIndex == 0)
    }

    // MARK: Prompt data

    @Test("prompt and intro wording is unchanged in German")
    func germanWording() {
        let todo = Todo(text: "Stephan anrufen")
        #expect(TodoConfirmationFlow.introLine(language: .de)
            == "Mir sind ein paar mögliche Aufgaben aufgefallen. Lass uns kurz drüber gehen.")
        #expect(TodoConfirmationFlow.promptLine(for: todo, index: 1, total: 3, language: .de)
            == "2 von 3: Soll ich \u{201E}Stephan anrufen\u{201C} übernehmen?")
        #expect(TodoConfirmationFlow.promptLine(for: todo, index: 0, total: 1, language: .de)
            == "Soll ich \u{201E}Stephan anrufen\u{201C} übernehmen?")
    }

    @Test("prompt and intro wording is unchanged in English")
    func englishWording() {
        let todo = Todo(text: "Call Stephan")
        #expect(TodoConfirmationFlow.introLine(language: .en)
            == "I noticed a few possible to-dos. Let's run through them quickly.")
        #expect(TodoConfirmationFlow.promptLine(for: todo, index: 1, total: 3, language: .en)
            == "2 of 3: Should I keep \u{201E}Call Stephan\u{201C}?")
        #expect(TodoConfirmationFlow.promptLine(for: todo, index: 0, total: 1, language: .en)
            == "Should I keep \u{201E}Call Stephan\u{201C}?")
    }

    @Test("the intro and every prompt are recorded with their roles and segments")
    func promptsAreRecorded() async {
        let (flow, host) = makeFlow(texts: ["Stephan anrufen", "Bericht senden"])
        await flow.begin()
        await flow.confirmCurrent()
        #expect(host.prompts == [
            .init(role: "todo_intro", segmentID: nil, text: TodoConfirmationFlow.introLine(language: .de)),
            .init(role: "todo_prompt", segmentID: "s00",
                  text: "1 von 2: Soll ich \u{201E}Stephan anrufen\u{201C} übernehmen?"),
            .init(role: "todo_confirmed", segmentID: "s00", text: "Stephan anrufen"),
            .init(role: "todo_prompt", segmentID: "s01",
                  text: "2 von 2: Soll ich \u{201E}Bericht senden\u{201C} übernehmen?"),
        ])
    }
}
