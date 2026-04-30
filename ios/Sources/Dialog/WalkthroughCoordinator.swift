import AVFoundation
import Foundation
import SwiftUI
import os

// Drives the evening walkthrough: pulls the day's calendar from the
// server, walks through the events one by one, captures a per-event audio
// segment, finishes with a free-reflection segment, then enqueues the
// session for upload.
//
// Voice command detection is **not** wired in M5 — the user advances via
// explicit "Weiter / Überspringen / Ich bin fertig" buttons. M6 brings
// lull detection + Apple Foundation Models follow-ups; M7 adds the wake-
// word path.
//
// Audio capture path: `AudioEngine.start(outputURL:)` per segment, files
// staged under `Application Support/VoiceDiary/sessions/staging/{slug}/segments/sNN.m4a`.

@MainActor
@Observable
public final class WalkthroughCoordinator {
    public static let shared = WalkthroughCoordinator()

    public private(set) var state: WalkthroughState = .idle
    public private(set) var events: [ServerCalendarEvent] = []
    public private(set) var lastSpoken: String = ""
    public private(set) var elapsedSeconds: Int = 0
    public private(set) var error: String?
    /// Set when the manifest has been queued. Useful for the UI summary.
    public private(set) var sessionID: String?
    /// Day the upcoming session is FOR (calendar lookup + manifest.date).
    /// Defaults to today. The user can pick a past date to catch up on
    /// a missed day; recording itself still happens now.
    public var selectedDate: Date = Date()
    /// Pre-flight events for the selected day, fetched before `begin()`
    /// so the UI can render the day overview. Filled by `previewDay()`.
    public private(set) var previewEvents: [ServerCalendarEvent] = []
    /// True while `previewDay()` is in flight.
    public private(set) var isPreviewing: Bool = false
    public private(set) var previewError: String?
    /// Surfaced in the UI for the 15s lull cue ("soll ich weitermachen?").
    /// SPEC §6.2 makes this a spoken prompt; M6 keeps it visual.
    public private(set) var statusHint: String = ""
    /// True while an enrichment request is in flight (server round-trip
    /// + summary playback). The UI uses this to disable advance / skip
    /// so the user doesn't move past while the AI is still answering.
    public private(set) var isEnriching: Bool = false

    private let engine = AudioEngine()
    private let tts: any TTSEngine = VoiceRegistry.engine(for: "de")
    private let lullDetector = LullDetector()
    private var sessionDir: URL?
    private var segmentURLs: [String: URL] = [:]    // multipart name → on-disk URL
    private var segments: [Segment] = []
    private var aiPrompts: [AiPrompt] = []
    private var timer: Timer?
    /// Per-event follow-up flag. SPEC §6.2 hard rule: at most one.
    private var followUpUsed: [Int: Bool] = [:]
    /// Rotation index for the deterministic follow-up template fallback.
    private var followUpRotation: Int = 0
    /// segment_id → index into `segments` so we can mutate the entry
    /// once todo extraction completes (which happens *after* startCapture
    /// has already appended the empty placeholder).
    private var segmentByID: [String: Int] = [:]
    /// In-flight transcription / todo-extraction tasks. `ingestAndUpload`
    /// awaits all of them so the manifest is built with full data.
    private var pendingFinalisation: [Task<Void, Never>] = []
    /// Implicit-todo candidates surfaced by Apple FM during `finalise()`.
    /// Confirmed at CLOSING via `.confirmingTodos`; never spoken
    /// mid-flow (CLAUDE.md key constraint #4).
    public private(set) var pendingImplicitTodos: [Todo] = []
    /// Confirmed implicit todos for this session (manifest field).
    private var confirmedImplicit: [Todo] = []
    /// Rejected implicit todos for this session (manifest field).
    private var rejectedImplicit: [TodoRejected] = []
    /// Drives the confirmation language for the CLOSING pass — captured
    /// when we enter `goClosing` so the same phrases keep speaking even
    /// if Settings later flips between de/en.
    private var confirmationLanguage: OpenerLanguage = .de
    /// True while the mic is open waiting for the user's spoken
    /// "ja / nein / anders" answer to the current candidate. The UI uses
    /// this to render a "höre dich…" cue alongside the buttons.
    public private(set) var isAwaitingTodoAnswer: Bool = false
    /// In-flight answer-capture task — cancelled if the user taps a
    /// button manually.
    private var todoAnswerTask: Task<Void, Never>?
    /// Lull detector dedicated to the answer window so it doesn't
    /// collide with the per-event detector.
    private let answerLullDetector = LullDetector()
    /// Hard cap for an answer capture (seconds). After this we transcribe
    /// whatever we have and let the parser fall back to .unknown.
    private static let todoAnswerMaxSeconds: TimeInterval = 7.0

    private init() {}

    // MARK: - Public commands -----------------------------------------

    public func begin(today: Date? = nil, language: OpenerLanguage = .de) async {
        guard case .idle = state else { return }
        let targetDate = today ?? selectedDate
        state = .briefing
        error = nil
        events = []
        segments = []
        segmentURLs = [:]
        aiPrompts = []
        followUpUsed = [:]
        followUpRotation = 0
        statusHint = ""
        segmentByID = [:]
        pendingFinalisation = []
        pendingImplicitTodos = []
        confirmedImplicit = []
        rejectedImplicit = []
        confirmationLanguage = language
        do {
            try makeSessionDir()
            try await fetchCalendar(date: targetDate)
            // If preview events were already loaded, the call above just
            // confirms them; we use the live result either way.
            await speakBriefing(language: language)
            if events.isEmpty {
                await goClosing(language: language)
                return
            }
            await runEvent(at: 0, language: language)
        } catch {
            self.error = "\(error)"
            state = .failed("\(error)")
        }
    }

    /// Fetch the day's events without starting a session. Drives the
    /// day-overview card on the *Abend* tab. Safe to call repeatedly
    /// (e.g. when the user changes the date picker).
    public func previewDay(_ date: Date? = nil) async {
        let target = date ?? selectedDate
        if let date { selectedDate = date }
        isPreviewing = true
        previewError = nil
        defer { isPreviewing = false }
        do {
            let dateString = Self.dateFormatter.string(from: target)
            let raw = try await ServerClient.shared.todayCalendar(date: dateString)
            let parsed = try JSONDecoder().decode(TodayCalendarResponse.self, from: raw)
            previewEvents = parsed.events
        } catch {
            previewError = "\(error)"
            previewEvents = []
        }
    }

    public func setSelectedDate(_ date: Date) {
        selectedDate = date
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// Advance from the current `eventListening` state to the next event,
    /// or to closing if the current one is the last.
    public func advance(language: OpenerLanguage = .de) async {
        guard case .eventListening(let idx) = state else { return }
        await stopSegmentCapture()
        let next = idx + 1
        if next >= events.count {
            await goClosing(language: language)
        } else {
            await runEvent(at: next, language: language)
        }
    }

    /// Skip the current event without capturing anything for it.
    public func skip(language: OpenerLanguage = .de) async {
        guard case .eventListening(let idx) = state else { return }
        // Cancel + drop the staged audio for this segment.
        try? await engine.stop()
        if let segID = "s\(String(format: "%02d", idx + 1))" as String?,
           let url = segmentURLs[mediaPath(for: segID)] {
            try? FileManager.default.removeItem(at: url)
            segmentURLs.removeValue(forKey: mediaPath(for: segID))
            segments.removeAll { $0.audioFile == mediaPath(for: segID) }
            _ = url  // silence unused warning when build flags vary
        }
        let next = idx + 1
        if next >= events.count {
            await goClosing(language: language)
        } else {
            await runEvent(at: next, language: language)
        }
    }

    /// Jump directly to closing from any listening state.
    public func finishEarly(language: OpenerLanguage = .de) async {
        switch state {
        case .eventListening:
            await stopSegmentCapture()
            await goClosing(language: language)
        case .closingListening:
            await stopSegmentCapture()
            await ingestAndUpload()
        default:
            break
        }
    }

    public func cancel() async {
        timer?.invalidate(); timer = nil
        await cancelTodoAnswerCapture()
        try? await engine.stop()
        await tts.cancel()
        state = .idle
    }

    // MARK: - Enrichment (M7) -------------------------------------------

    /// Run a single mid-walkthrough enrichment query. The caller (the
    /// modal in `WalkthroughView` for now; a wake-word path in M7
    /// phase B) supplies the typed/spoken question text.
    ///
    ///   1. Speak a short "einen Moment, ich schaue nach …" cue.
    ///   2. Classify intent + call the right server endpoint.
    ///   3. Speak the returned summary.
    ///   4. Append the full Q&A to `manifest.ai_prompts[]` so the server
    ///      side can reference what was asked when ingesting the segment.
    /// The current segment recording stays running underneath so we
    /// don't lose the user's reflection in progress.
    public func askEnrichment(
        query: String,
        language: OpenerLanguage = .de
    ) async {
        guard !isEnriching else { return }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isEnriching = true
        defer { isEnriching = false }

        let segmentID: String? = {
            if case .eventListening(let i) = state {
                return "s\(String(format: "%02d", i + 1))"
            }
            if case .closingListening = state { return "sClose" }
            return nil
        }()
        recordAiPrompt(role: "enrichment_query", segmentID: segmentID, text: trimmed)

        let cue = language == .de
            ? "Einen Moment, ich schaue nach."
            : "One moment, let me check."
        await tts.speak(cue, language: language.rawValue)

        do {
            let result = try await EnrichmentService.shared.enrich(
                query: trimmed,
                responseLanguage: language.rawValue
            )
            recordAiPrompt(
                role: "enrichment_answer",
                segmentID: segmentID,
                text: result.summary
            )
            await tts.speak(result.summary, language: language.rawValue)
        } catch {
            Log.app.warning(
                "enrichment failed: \(String(describing: error), privacy: .public)"
            )
            let fallback = language == .de
                ? "Ich konnte die Frage gerade nicht beantworten."
                : "I couldn't answer that just now."
            recordAiPrompt(role: "enrichment_failed", segmentID: segmentID, text: "\(error)")
            await tts.speak(fallback, language: language.rawValue)
        }
    }

    // MARK: - Phases ---------------------------------------------------

    private func runEvent(at index: Int, language: OpenerLanguage) async {
        guard index < events.count else { return }
        state = .eventOpener(index: index)
        statusHint = ""
        let line = OpenerTemplates.line(
            for: events[index],
            index: index,
            of: events.count,
            language: language
        )
        lastSpoken = line
        recordAiPrompt(role: "opener",
                       segmentID: "s\(String(format: "%02d", index + 1))",
                       text: line)
        await tts.speak(line, language: language.rawValue)
        // Move to listening — start capturing this event's segment.
        do {
            try await startSegmentCapture(forEventAt: index)
            state = .eventListening(index: index)
            startTimer()
            startLullDetection(forEventAt: index, language: language)
        } catch {
            self.error = "\(error)"
            state = .failed("\(error)")
        }
    }

    private func goClosing(language: OpenerLanguage) async {
        state = .closingPrompt
        confirmationLanguage = language
        let line = language == .de
            ? "Willst du noch etwas zum ganzen Tag sagen?"
            : "Anything else you want to say about the day overall?"
        lastSpoken = line
        await tts.speak(line, language: language.rawValue)
        do {
            try await startSegmentCapture(closing: true)
            state = .closingListening
            startTimer()
        } catch {
            self.error = "\(error)"
            await ingestAndUpload()
        }
    }

    private func ingestAndUpload() async {
        timer?.invalidate(); timer = nil
        do {
            try await stopSegmentCaptureNoTranscribe()
            // Wait for any in-flight per-segment transcription + todo
            // extraction to finish so we know exactly which implicit
            // candidates need confirming.
            for task in pendingFinalisation { await task.value }
            pendingFinalisation.removeAll()

            // SPEC §8: walk through the implicit-todo candidates one by
            // one at CLOSING. UI buttons drive the confirm / reject /
            // refine state machine. Voice-driven confirmation is phase B-2.
            if !pendingImplicitTodos.isEmpty {
                await beginTodoConfirmation()
                return
            }

            try await finishUpload()
        } catch {
            self.error = "\(error)"
            state = .failed("\(error)")
        }
    }

    private func finishUpload() async throws {
        state = .ingesting
        let manifest = try buildManifest()
        sessionID = manifest.session_id
        await SessionUploader.shared.enqueue(
            manifest: manifest,
            audioFiles: segmentURLs
        )
        state = .done
    }

    private func speakBriefing(language: OpenerLanguage) async {
        let count = events.count
        let line: String
        if count == 0 {
            line = language == .de
                ? "Heute hattest du keine Termine. Willst du frei reflektieren?"
                : "You had no meetings today. Want to reflect freely?"
        } else {
            line = language == .de
                ? "Heute hattest du \(count) Termine. Los geht's mit dem ersten."
                : "You had \(count) meetings today. Let's start with the first."
        }
        lastSpoken = line
        await tts.speak(line, language: language.rawValue)
    }

    // MARK: - Capture --------------------------------------------------

    private func startSegmentCapture(forEventAt index: Int) async throws {
        guard let sessionDir else { throw NSError(domain: "Walkthrough", code: 1) }
        let segmentID = "s\(String(format: "%02d", index + 1))"
        let path = mediaPath(for: segmentID)
        let url = sessionDir.appending(path: path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let detector = lullDetector
        try await engine.start(outputURL: url) { @Sendable buffer in
            detector.feed(buffer)
        }
        segmentURLs[path] = url

        // Build the manifest segment now; transcript stays empty (server
        // re-transcribes via Whisper on ingest).
        let event = events[index]
        let calRef = CalendarRef(
            graph_event_id: event.graph_event_id,
            title: event.subject,
            start: event.start,
            end: event.end,
            attendees: event.attendees.map { $0.email.isEmpty ? $0.name : $0.email },
            rsvp_status: event.rsvp_status
        )
        let seg = CalendarEventSegment(
            segment_id: segmentID,
            calendar_ref: calRef,
            audio_file: path
        )
        segments.append(.calendarEvent(seg))
        segmentByID[segmentID] = segments.count - 1
    }

    private func startSegmentCapture(closing: Bool) async throws {
        guard let sessionDir else { throw NSError(domain: "Walkthrough", code: 1) }
        let segmentID = "sClose"
        let path = mediaPath(for: segmentID)
        let url = sessionDir.appending(path: path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let detector = lullDetector
        try await engine.start(outputURL: url) { @Sendable buffer in
            detector.feed(buffer)
        }
        segmentURLs[path] = url
        let seg = FreeReflectionSegment(
            segment_id: segmentID,
            audio_file: path,
            captured_at: ISO8601DateFormatter().string(from: Date())
        )
        segments.append(.freeReflection(seg))
        segmentByID[segmentID] = segments.count - 1
    }

    private func stopSegmentCapture() async {
        timer?.invalidate(); timer = nil
        elapsedSeconds = 0
        lullDetector.stop()

        // Capture which segment just finished + its file URL while we
        // still know — the state may change before the post-stop task
        // runs.
        let finishingSegmentID: String? = {
            switch state {
            case .eventListening(let i): return "s\(String(format: "%02d", i + 1))"
            case .closingListening:      return "sClose"
            default:                     return nil
            }
        }()
        let finishingURL = finishingSegmentID.flatMap { segmentURLs[mediaPath(for: $0)] }

        do { _ = try await engine.stop() } catch {
            Log.audio.warning("walkthrough engine stop: \(String(describing: error), privacy: .public)")
        }

        // Kick off transcription + explicit-todo extraction in the
        // background. We don't block the next opener on it — the result
        // mutates `segments[]` in place and `ingestAndUpload` awaits all
        // outstanding tasks before building the manifest.
        if let segmentID = finishingSegmentID, let url = finishingURL {
            let task = Task { [weak self] in
                guard let self else { return }
                await self.finalise(segmentID: segmentID, url: url)
            }
            pendingFinalisation.append(task)
        }

        // AVAudioEngine deactivation isn't synchronous — give CoreAudio a
        // moment to fully release the audio unit before the next start().
        try? await Task.sleep(nanoseconds: 300_000_000)
    }

    /// Per-segment finaliser: runs Parakeet on the captured M4A, parses
    /// explicit todo triggers (SPEC §8), and writes the results onto
    /// the segment that's already in `segments[]`. Idempotent — if the
    /// transcription fails we just leave the segment as-is and let the
    /// server's Whisper produce the canonical transcript on ingest.
    private func finalise(segmentID: String, url: URL) async {
        let transcript: ParakeetManager.Transcript
        do {
            transcript = try await ParakeetManager.shared.transcribe(audioURL: url)
        } catch {
            Log.audio.warning(
                "segment \(segmentID, privacy: .public) finalise: transcribe failed — \(String(describing: error), privacy: .public)"
            )
            return
        }

        let todos = TodoExtractor.extractExplicit(
            text: transcript.text,
            language: transcript.language,
            sourceSegmentID: segmentID
        )
        if !todos.isEmpty {
            Log.app.info(
                "segment \(segmentID, privacy: .public): \(todos.count, privacy: .public) explicit todo(s) detected"
            )
        }

        // Implicit-todo pass via Apple Foundation Models. Failures are
        // non-fatal — we just don't surface candidates from this segment.
        // SPEC §8: candidates accumulate across segments and are confirmed
        // one-by-one at CLOSING.
        let llm = AppleFoundationLLM.shared
        if await llm.isAvailable {
            do {
                let candidates = try await llm.extractImplicit(
                    transcript: transcript.text,
                    language: transcript.language
                )
                let novel = self.dedupeImplicit(
                    candidates: candidates,
                    againstExplicit: todos,
                    forSegmentID: segmentID,
                    transcriptLanguage: transcript.language
                )
                if !novel.isEmpty {
                    Log.app.info(
                        "segment \(segmentID, privacy: .public): \(novel.count, privacy: .public) implicit todo candidate(s)"
                    )
                    self.pendingImplicitTodos.append(contentsOf: novel)
                }
            } catch {
                Log.app.warning(
                    "implicit-todo extraction failed for \(segmentID, privacy: .public): \(String(describing: error), privacy: .public)"
                )
            }
        }

        // Mutate the segment in place.
        guard let idx = segmentByID[segmentID] else { return }
        switch segments[idx] {
        case .calendarEvent(var ce):
            ce.transcript = transcript.text
            ce.todos_detected = todos
            ce.language = transcript.language
            segments[idx] = .calendarEvent(ce)
        case .freeReflection(var fr):
            fr.transcript = transcript.text
            fr.language = transcript.language
            segments[idx] = .freeReflection(fr)
            // Free-reflection segments don't carry their own todos
            // array, but anything detected goes into the session-level
            // implicit-confirmed bucket since the server expects it
            // there for narrative ingestion.
            // (todos[i].source_segment_id stays = sClose so the diary
            // attribution is correct.)
            // — left for Phase B once implicit detection is wired.
        default:
            break
        }
    }

    private func stopSegmentCaptureNoTranscribe() async throws {
        timer?.invalidate(); timer = nil
        elapsedSeconds = 0
        lullDetector.stop()
        _ = try? await engine.stop()
        try? await Task.sleep(nanoseconds: 300_000_000)
    }

    // MARK: - Follow-up logic ------------------------------------------

    private func startLullDetection(forEventAt index: Int, language: OpenerLanguage) {
        lullDetector.start { [weak self] threshold in
            guard let self else { return }
            Task { @MainActor in
                guard case .eventListening(let current) = self.state, current == index else {
                    return
                }
                await self.handleLull(threshold: threshold, eventIndex: index, language: language)
            }
        }
    }

    private func handleLull(threshold: Int, eventIndex: Int, language: OpenerLanguage) async {
        switch threshold {
        case 6:
            guard followUpUsed[eventIndex] != true else { return }
            followUpUsed[eventIndex] = true
            await speakFollowUp(forEventAt: eventIndex, language: language)
        case 15:
            statusHint = language == .de
                ? "Tippe Weiter, wenn du fertig bist."
                : "Tap Continue when you're done."
        default:
            break
        }
    }

    private func speakFollowUp(forEventAt index: Int, language: OpenerLanguage) async {
        let event = events[index]
        let attendeeNames = event.attendees.map(\.name).filter { !$0.isEmpty }

        var line: String?
        let llm = AppleFoundationLLM.shared
        if await llm.isAvailable {
            do {
                line = try await llm.generateFollowUp(
                    eventTitle: event.subject,
                    attendees: attendeeNames,
                    userTranscript: "",   // M7 wires live partials in
                    language: language.rawValue
                )
                Log.app.info("follow-up via FoundationModels for event \(index, privacy: .public)")
            } catch {
                Log.app.warning(
                    "FoundationModels follow-up failed: \(String(describing: error), privacy: .public)"
                )
            }
        }
        if line == nil || line?.isEmpty == true {
            line = OpenerTemplates.followUp(language: language, rotation: followUpRotation)
            followUpRotation += 1
        }
        guard let spoken = line, !spoken.isEmpty else { return }

        lastSpoken = spoken
        recordAiPrompt(
            role: "follow_up",
            segmentID: "s\(String(format: "%02d", index + 1))",
            text: spoken
        )
        await tts.speak(spoken, language: language.rawValue)
    }

    // MARK: - Implicit-todo confirmation (M8 phase B) -----------------

    /// True when the coordinator is currently in `.confirmingTodos` and
    /// `pendingImplicitTodos[index]` is the one being asked about.
    public var currentTodoCandidate: Todo? {
        guard case .confirmingTodos(let i) = state,
              i >= 0, i < pendingImplicitTodos.count else { return nil }
        return pendingImplicitTodos[i]
    }

    public var todoCandidateProgress: (index: Int, total: Int)? {
        guard case .confirmingTodos(let i) = state else { return nil }
        return (i, pendingImplicitTodos.count)
    }

    /// Confirm the current candidate as-is. Moves to the next candidate
    /// or finishes the session.
    public func confirmCurrentTodo() async {
        await cancelTodoAnswerCapture()
        guard case .confirmingTodos(let i) = state,
              i >= 0, i < pendingImplicitTodos.count else { return }
        let candidate = pendingImplicitTodos[i]
        confirmedImplicit.append(candidate)
        recordAiPrompt(
            role: "todo_confirmed",
            segmentID: candidate.source_segment_id,
            text: candidate.text
        )
        await advanceTodoConfirmation()
    }

    /// Reject the current candidate. Records it in `todos_implicit_rejected`
    /// so the server can learn from past rejections (future work) and
    /// doesn't re-suggest the same phrasing.
    public func rejectCurrentTodo() async {
        await cancelTodoAnswerCapture()
        guard case .confirmingTodos(let i) = state,
              i >= 0, i < pendingImplicitTodos.count else { return }
        let candidate = pendingImplicitTodos[i]
        rejectedImplicit.append(TodoRejected(
            text: candidate.text,
            source_segment_id: candidate.source_segment_id
        ))
        recordAiPrompt(
            role: "todo_rejected",
            segmentID: candidate.source_segment_id,
            text: candidate.text
        )
        await advanceTodoConfirmation()
    }

    /// Replace the current candidate's text with the user's refined
    /// version, then confirm it. Empty/whitespace input rejects instead.
    public func refineCurrentTodo(_ refined: String) async {
        await cancelTodoAnswerCapture()
        guard case .confirmingTodos(let i) = state,
              i >= 0, i < pendingImplicitTodos.count else { return }
        let trimmed = refined.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            await rejectCurrentTodo()
            return
        }
        let original = pendingImplicitTodos[i]
        let due = TodoExtractor.parseDueDate(in: trimmed, language: confirmationLanguage.rawValue)
        confirmedImplicit.append(Todo(
            text: trimmed,
            type: "implicit",
            due: due,
            status: "Offen",
            source_segment_id: original.source_segment_id
        ))
        recordAiPrompt(
            role: "todo_refined",
            segmentID: original.source_segment_id,
            text: trimmed
        )
        await advanceTodoConfirmation()
    }

    private func beginTodoConfirmation() async {
        let lang = confirmationLanguage
        let intro = lang == .de
            ? "Mir sind ein paar mögliche Aufgaben aufgefallen. Lass uns kurz drüber gehen."
            : "I noticed a few possible to-dos. Let's run through them quickly."
        lastSpoken = intro
        await tts.speak(intro, language: lang.rawValue)
        await advanceTodoConfirmation(initial: true)
    }

    /// Move to the next pending candidate, or finish the session if
    /// there are none left.
    private func advanceTodoConfirmation(initial: Bool = false) async {
        let nextIndex: Int = {
            if initial { return 0 }
            if case .confirmingTodos(let i) = state { return i + 1 }
            return 0
        }()

        guard nextIndex < pendingImplicitTodos.count else {
            do { try await finishUpload() }
            catch {
                self.error = "\(error)"
                state = .failed("\(error)")
            }
            return
        }

        state = .confirmingTodos(index: nextIndex)
        await speakCurrentTodoPrompt()
    }

    private func speakCurrentTodoPrompt() async {
        guard case .confirmingTodos(let i) = state,
              i >= 0, i < pendingImplicitTodos.count else { return }
        let candidate = pendingImplicitTodos[i]
        let lang = confirmationLanguage
        let total = pendingImplicitTodos.count
        let line: String
        if lang == .de {
            line = total > 1
                ? "\(i + 1) von \(total): \(candidate.text). Ja, nein, oder anders?"
                : "\(candidate.text). Ja, nein, oder anders?"
        } else {
            line = total > 1
                ? "\(i + 1) of \(total): \(candidate.text). Yes, no, or rephrase?"
                : "\(candidate.text). Yes, no, or rephrase?"
        }
        lastSpoken = line
        recordAiPrompt(
            role: "todo_prompt",
            segmentID: candidate.source_segment_id,
            text: line
        )
        await tts.speak(line, language: lang.rawValue)
        // Phase B-2: open the mic for a short window and listen for the
        // spoken answer. Buttons in the UI cancel the task if the user
        // taps before we finish.
        await beginTodoAnswerCapture(forCandidateIndex: i)
    }

    // MARK: - Voice answer capture (M8 phase B-2) ----------------------

    /// Open the mic for a short answer window, transcribe, and dispatch
    /// to confirm/reject/refine based on `TodoAnswerParser`. Designed to
    /// be cancelled via `cancelTodoAnswerCapture()` when the user opts
    /// for a button instead.
    private func beginTodoAnswerCapture(forCandidateIndex index: Int) async {
        await cancelTodoAnswerCapture()
        guard case .confirmingTodos(let i) = state, i == index else { return }

        let task = Task { [weak self] in
            guard let self else { return }
            await self.runTodoAnswerCapture(forCandidateIndex: index)
        }
        todoAnswerTask = task
    }

    private func runTodoAnswerCapture(forCandidateIndex index: Int) async {
        guard let sessionDir else { return }
        let url = sessionDir.appending(
            path: "segments/confirm_\(String(format: "%02d", index)).m4a"
        )
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            Log.app.warning(
                "todo answer dir create failed: \(String(describing: error), privacy: .public)"
            )
            return
        }

        let detector = answerLullDetector
        // Tighter thresholds than the per-event detector — the user's
        // ja/nein answer is short.
        detector.thresholds = [2, 4, 7]
        let lullStream = AsyncStream<Int> { continuation in
            detector.start { threshold in
                continuation.yield(threshold)
            }
            continuation.onTermination = { _ in detector.stop() }
        }

        do {
            try await engine.start(outputURL: url) { @Sendable buffer in
                detector.feed(buffer)
            }
        } catch {
            Log.app.warning(
                "todo answer engine start failed: \(String(describing: error), privacy: .public)"
            )
            detector.stop()
            return
        }

        isAwaitingTodoAnswer = true
        defer { isAwaitingTodoAnswer = false }

        // Wait for the first lull ≥ 2s (treat as end-of-utterance) OR
        // the hard timeout, whichever fires first. Buttons cancel the
        // outer Task and we exit early via Task.isCancelled below.
        let maxSeconds = Self.todoAnswerMaxSeconds
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for await crossed in lullStream where crossed >= 2 { _ = crossed; break }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(maxSeconds * 1e9))
            }
            // First branch wins; cancel the rest so the AsyncStream
            // terminates cleanly.
            await group.next()
            group.cancelAll()
            await group.waitForAll()
        }
        detector.stop()

        if Task.isCancelled {
            try? await engine.stop()
            detector.stop()
            return
        }

        do { _ = try await engine.stop() }
        catch {
            Log.audio.warning(
                "todo answer engine stop: \(String(describing: error), privacy: .public)"
            )
        }
        detector.stop()
        try? await Task.sleep(nanoseconds: 200_000_000)

        // Re-check we're still on the same candidate (user may have
        // tapped a button while we were closing the engine).
        guard case .confirmingTodos(let nowIndex) = state, nowIndex == index else { return }

        // Transcribe — short clip, fast.
        let transcript: ParakeetManager.Transcript
        do {
            transcript = try await ParakeetManager.shared.transcribe(audioURL: url)
        } catch {
            Log.app.warning(
                "todo answer transcribe failed: \(String(describing: error), privacy: .public)"
            )
            return
        }

        recordAiPrompt(
            role: "todo_answer_voice",
            segmentID: pendingImplicitTodos[index].source_segment_id,
            text: transcript.text
        )

        let outcome = TodoAnswerParser.parse(transcript.text)
        Log.app.info(
            "todo answer (\(index, privacy: .public)) → \(String(describing: outcome), privacy: .public) raw=\(transcript.text, privacy: .public)"
        )

        switch outcome {
        case .confirm:
            await confirmCurrentTodo()
        case .reject:
            await rejectCurrentTodo()
        case .refine(let text):
            await refineCurrentTodo(text)
        case .unknown:
            // Voice answer was ambiguous — leave the buttons + refine
            // editor open so the user can tap. No advancement.
            break
        }
    }

    private func cancelTodoAnswerCapture() async {
        if let task = todoAnswerTask {
            task.cancel()
            todoAnswerTask = nil
        }
        if isAwaitingTodoAnswer {
            // Force-stop the engine so the next prompt's capture starts
            // clean. Tolerant of a no-op stop.
            _ = try? await engine.stop()
            answerLullDetector.stop()
            isAwaitingTodoAnswer = false
        }
    }

    private func dedupeImplicit(
        candidates: [String],
        againstExplicit explicit: [Todo],
        forSegmentID segmentID: String,
        transcriptLanguage language: String
    ) -> [Todo] {
        // Already-known keys (from explicit + previously-collected
        // implicit). Comparison is lowercased + whitespace-stripped so
        // "Stephan anrufen" and "stephan anrufen" collapse.
        var seen: Set<String> = []
        for t in explicit { seen.insert(normaliseTodoKey(t.text)) }
        for t in pendingImplicitTodos { seen.insert(normaliseTodoKey(t.text)) }

        var out: [Todo] = []
        for raw in candidates {
            let key = normaliseTodoKey(raw)
            guard !key.isEmpty, !seen.contains(key) else { continue }
            seen.insert(key)
            let due = TodoExtractor.parseDueDate(in: raw, language: language)
            out.append(Todo(
                text: raw,
                type: "implicit",
                due: due,
                status: "Offen",
                source_segment_id: segmentID
            ))
        }
        return out
    }

    private func normaliseTodoKey(_ s: String) -> String {
        s.lowercased()
         .trimmingCharacters(in: .whitespacesAndNewlines)
         .replacingOccurrences(of: "  ", with: " ")
    }

    private func recordAiPrompt(role: String, segmentID: String?, text: String) {
        aiPrompts.append(AiPrompt(
            at: ISO8601DateFormatter().string(from: Date()),
            role: role,
            segment_id: segmentID,
            text: text
        ))
    }

    // MARK: - Helpers --------------------------------------------------

    private func makeSessionDir() throws {
        let stagingRoot = try LocalStore.sessionsStagingDir()
        let sessionID = ISO8601DateFormatter().string(from: Date())
        let dir = stagingRoot.appending(
            path: sanitize(sessionID),
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: dir.appending(path: "segments"),
                                                withIntermediateDirectories: true)
        sessionDir = dir
        self.sessionID = sessionID
    }

    private func mediaPath(for segmentID: String) -> String {
        "segments/\(segmentID).m4a"
    }

    private func fetchCalendar(date: Date) async throws {
        let dateString = Self.dateFormatter.string(from: date)
        let raw = try await ServerClient.shared.todayCalendar(date: dateString)
        let response = try JSONDecoder().decode(TodayCalendarResponse.self, from: raw)
        events = response.events
    }

    private func buildManifest() throws -> Manifest {
        guard let sessionID else { throw NSError(domain: "Walkthrough", code: 2) }
        // The session is *for* `selectedDate`, but the recording happened
        // now (`sessionID` is the wall-clock timestamp). Server sees both:
        // `manifest.date` drives diary attribution + LightRAG temporal
        // anchoring; `session_id` keeps uploads ordered chronologically.
        return Manifest(
            session_id: sessionID,
            date: Self.dateFormatter.string(from: selectedDate),
            audio_codec: AudioCodec(
                codec: "aac-lc",
                sample_rate: 44_100,
                channels: 1,
                bitrate: 64_000
            ),
            segments: segments,
            todos_implicit_confirmed: confirmedImplicit,
            todos_implicit_rejected: rejectedImplicit,
            ai_prompts: aiPrompts,
            response_language_setting: "match_input"
        )
    }

    private func sanitize(_ s: String) -> String {
        s.replacingOccurrences(of: ":", with: "-")
         .replacingOccurrences(of: "+", with: "_")
    }

    private func startTimer() {
        timer?.invalidate()
        elapsedSeconds = 0
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.elapsedSeconds += 1
            }
        }
    }
}

