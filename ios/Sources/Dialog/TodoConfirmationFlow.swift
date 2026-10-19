import Foundation
import os

/// How one voice-answer recording for a todo candidate ended.
enum TodoAnswerRecording: Equatable, Sendable {
    /// Recording could not run or was cancelled; no verdict follows.
    case aborted
    /// The user never spoke (12 s of silence); counts as "no".
    case silent
    /// The user spoke but the 20 s safety timeout fired; counts as "no".
    case hardTimeout
    /// The user answered; the audio is at this URL, ready to transcribe.
    case recorded(URL)
}

/// What the todo confirmation flow needs from the walkthrough. The
/// coordinator owns the dialog state, audio engine, TTS, upload and
/// manifest; the flow reaches them only through these calls, so its
/// sequencing is unit-testable without audio, TTS or the network.
@MainActor
protocol TodoConfirmationHost: AnyObject {
    var confirmationLanguage: OpenerLanguage { get }
    /// The candidate index when the dialog state is `.confirmingTodos`.
    var confirmingTodoIndex: Int? { get }
    /// Move the dialog state to `.confirmingTodos(index:)`.
    func showTodoCandidate(at index: Int)
    func recordTodoConfirmed(_ todo: Todo)
    func recordTodoRejected(text: String, sourceSegmentID: String?)
    func recordTodoPrompt(role: String, segmentID: String?, text: String)
    /// Silence TTS and let the audio route settle before the intro line.
    func settleSpeechBeforeIntro() async
    func speakTodoLine(_ text: String, language: OpenerLanguage) async
    /// Record the user's spoken answer to candidate `index`, including the
    /// wake-word window, lull detection and engine teardown.
    func recordTodoAnswer(forCandidateIndex index: Int) async -> TodoAnswerRecording
    func transcribeTodoAnswer(at url: URL) async throws -> String
    /// Stop an answer recording that is still in flight.
    func cancelTodoAnswerRecording() async
    /// Every candidate has a verdict: hand the session to the upload.
    func finishAfterTodoConfirmation() async
}

/// The implicit-todo confirmation sequence that runs after CLOSING: the
/// spoken intro, one prompt per candidate, the user's voice answer
/// (ja / nein / refinement) and the verdict recorded for each. Kept apart
/// from `WalkthroughCoordinator`, which stays the owner of dialog state
/// and every audio, TTS, upload and manifest interaction.
@MainActor
@Observable
final class TodoConfirmationFlow {
    private(set) var candidates: [Todo] = []
    @ObservationIgnored weak var host: (any TodoConfirmationHost)?
    @ObservationIgnored private var answerTask: Task<Void, Never>?

    var hasCandidates: Bool { !candidates.isEmpty }

    /// The candidate on screen; nil outside `.confirmingTodos`.
    var currentCandidate: Todo? {
        currentIndex.map { candidates[$0] }
    }

    var progress: (index: Int, total: Int)? {
        guard let i = host?.confirmingTodoIndex else { return nil }
        return (i, candidates.count)
    }

    private var currentIndex: Int? {
        guard let i = host?.confirmingTodoIndex, i >= 0, i < candidates.count else { return nil }
        return i
    }

    func reset() {
        candidates = []
    }

    func add(_ todos: [Todo]) {
        candidates.append(contentsOf: todos)
    }

    // MARK: - Sequence

    func begin() async {
        guard let host else { return }
        let lang = host.confirmationLanguage
        let intro = Self.introLine(language: lang)

        // Harden against the intermittent dropped-intro race. The path
        // into here is `ingestAndUpload → finishUploadOrConfirmTodos`,
        // which already awaits all per-segment finalisation tasks; in
        // practice that means the previous TTS engine state can still
        // be in a transient "stopping" tail (Apple synth right after
        // `stopSpeaking(at: .immediate)`, or Piper's serial queue with
        // a cancelled-but-not-yet-drained Task at the head). Both
        // engines occasionally swallow a `speak()` queued in that
        // window, so the host cancels TTS and pauses briefly first.
        //
        // Logged on entry + exit so a future "intro didn't play"
        // report can be confirmed against the timeline instead of
        // guessed at.
        Diag.log("todo intro begin lang=\(lang.rawValue) candidates=\(candidates.count)")
        await host.settleSpeechBeforeIntro()
        host.recordTodoPrompt(role: "todo_intro", segmentID: nil, text: intro)
        await host.speakTodoLine(intro, language: lang)
        Diag.log("todo intro spoken")
        await advance(initial: true)
    }

    func confirmCurrent() async {
        await cancelAnswerCapture()
        guard let host, let i = currentIndex else { return }
        let candidate = candidates[i]
        host.recordTodoConfirmed(candidate)
        host.recordTodoPrompt(role: "todo_confirmed",
                              segmentID: candidate.source_segment_id,
                              text: candidate.text)
        await advance()
    }

    func rejectCurrent() async {
        await cancelAnswerCapture()
        guard let host, let i = currentIndex else { return }
        let candidate = candidates[i]
        host.recordTodoRejected(text: candidate.text, sourceSegmentID: candidate.source_segment_id)
        host.recordTodoPrompt(role: "todo_rejected",
                              segmentID: candidate.source_segment_id,
                              text: candidate.text)
        await advance()
    }

    func refineCurrent(_ refined: String) async {
        await cancelAnswerCapture()
        guard let host, let i = currentIndex else { return }
        let trimmed = refined.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            await rejectCurrent()
            return
        }
        let original = candidates[i]
        let due = TodoExtractor.parseDueDate(in: trimmed, language: host.confirmationLanguage.rawValue)
        host.recordTodoConfirmed(Todo(
            text: trimmed,
            type: "implicit",
            due: due,
            status: "Offen",
            source_segment_id: original.source_segment_id
        ))
        host.recordTodoPrompt(role: "todo_refined",
                              segmentID: original.source_segment_id,
                              text: trimmed)
        await advance()
    }

    private func advance(initial: Bool = false) async {
        guard let host else { return }
        let nextIndex: Int = {
            if initial { return 0 }
            if let i = host.confirmingTodoIndex { return i + 1 }
            return 0
        }()

        guard nextIndex < candidates.count else {
            await host.finishAfterTodoConfirmation()
            return
        }

        host.showTodoCandidate(at: nextIndex)
        await speakCurrentPrompt()
    }

    private func speakCurrentPrompt() async {
        guard let host, let i = currentIndex else { return }
        let candidate = candidates[i]
        let lang = host.confirmationLanguage
        let body = Self.promptLine(for: candidate, index: i, total: candidates.count, language: lang)
        host.recordTodoPrompt(role: "todo_prompt",
                              segmentID: candidate.source_segment_id,
                              text: body)
        await host.speakTodoLine(body, language: lang)
        await beginAnswerCapture(forCandidateIndex: i)
    }

    // MARK: - Spoken lines

    static func introLine(language: OpenerLanguage) -> String {
        language == .de
            ? "Mir sind ein paar mögliche Aufgaben aufgefallen. Lass uns kurz drüber gehen."
            : "I noticed a few possible to-dos. Let's run through them quickly."
    }

    /// Framed as a question so the yes/no affordance is obvious from the
    /// spoken line alone. With multiple candidates the leading "1 von 3"
    /// anchor helps the user track progress. `TodoAnswerParser`
    /// recognises both keyword answers (ja / nein / anders) and
    /// refinements ("nimm lieber X stattdessen").
    static func promptLine(for candidate: Todo, index: Int, total: Int, language: OpenerLanguage) -> String {
        // German low/high guillemets ( U+201E … U+201C ) so the closing
        // quote isn't an ASCII " that would terminate the string literal
        // mid-interpolation.
        let openQ  = "\u{201E}"
        let closeQ = "\u{201C}"
        switch language {
        case .de:
            return total > 1
                ? "\(index + 1) von \(total): Soll ich \(openQ)\(candidate.text)\(closeQ) übernehmen?"
                : "Soll ich \(openQ)\(candidate.text)\(closeQ) übernehmen?"
        case .en:
            return total > 1
                ? "\(index + 1) of \(total): Should I keep \(openQ)\(candidate.text)\(closeQ)?"
                : "Should I keep \(openQ)\(candidate.text)\(closeQ)?"
        }
    }

    // MARK: - Voice answer capture (M8 phase B-2)

    private func beginAnswerCapture(forCandidateIndex index: Int) async {
        await cancelAnswerCapture()
        guard host?.confirmingTodoIndex == index else { return }

        answerTask = Task { [weak self] in
            await self?.runAnswerCapture(forCandidateIndex: index)
        }
    }

    /// Resolves when the in-flight answer capture, and any capture its
    /// verdict started for the next candidate, has finished.
    func awaitAnswerCapture() async {
        var awaited: Task<Void, Never>?
        while let task = answerTask, task != awaited {
            await task.value
            awaited = task
        }
    }

    func cancelAnswerCapture() async {
        if let task = answerTask {
            task.cancel()
            answerTask = nil
        }
        await host?.cancelTodoAnswerRecording()
    }

    private func runAnswerCapture(forCandidateIndex index: Int) async {
        guard let host else { return }
        let recording = await host.recordTodoAnswer(forCandidateIndex: index)
        guard host.confirmingTodoIndex == index else { return }

        let url: URL
        switch recording {
        case .aborted:
            return
        case .silent:
            // 12 s pre-speech timeout: user neither answered nor said
            // "weiter". Auto-skip this candidate. (The wake-word match
            // path doesn't reach here — advance() cancelled this task
            // before transcribe.)
            Log.app.info("todo answer (\(index, privacy: .public)) → silent timeout, auto-reject")
            await rejectCurrent()
            return
        case .hardTimeout:
            Log.app.info("todo answer (\(index, privacy: .public)) → hard timeout, auto-reject")
            await rejectCurrent()
            return
        case .recorded(let recordedURL):
            url = recordedURL
        }

        let text: String
        do {
            text = try await host.transcribeTodoAnswer(at: url)
        } catch {
            Log.app.warning(
                "todo answer transcribe failed: \(String(describing: error), privacy: .public)"
            )
            await rejectCurrent()
            return
        }

        host.recordTodoPrompt(role: "todo_answer_voice",
                              segmentID: candidates[index].source_segment_id,
                              text: text)

        let outcome = TodoAnswerParser.parse(text)
        Log.app.info(
            "todo answer (\(index, privacy: .public)) → \(String(describing: outcome), privacy: .public) raw=\(text, privacy: .public)"
        )

        switch outcome {
        case .confirm:          await confirmCurrent()
        case .reject:           await rejectCurrent()
        case .refine(let text): await refineCurrent(text)
        case .unknown:
            // Couldn't classify the answer — auto-reject rather than
            // strand the user on this candidate. The buttons that used
            // to provide a manual hedge are gone (voice-first UX), so
            // unknown answers behave like "no" to keep the walkthrough
            // moving.
            await rejectCurrent()
        }
    }
}
