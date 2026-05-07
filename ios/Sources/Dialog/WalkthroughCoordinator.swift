@preconcurrency import ActivityKit
import AudioToolbox
import AVFoundation
import Foundation
import SwiftUI
import os

// Drives the evening walkthrough. The session is now a *plan* of ordered
// sections (SPEC §6) rather than a hardcoded events→closing sequence.
// Three section kinds:
//
//   * `general` — user-defined opener with title + intro. One segment.
//   * `calendarEvents` — the per-event loop; one segment per event.
//   * `driveBy` — surfaces today's drive-by seeds (each becomes a
//                 `drive_by` segment) and captures one closing
//                 free-reflection segment.
//
// The plan is built in `begin()` from `WalkthroughSettingsStore.order` plus
// the filtered calendar events plus the unsurfaced seed list. Empty
// sections are skipped so users with no general sections + an empty
// calendar still flow into the drive-by closer.

@MainActor
@Observable
public final class WalkthroughCoordinator {
    public static let shared = WalkthroughCoordinator()

    public private(set) var state: WalkthroughState = .idle
    public private(set) var events: [ServerCalendarEvent] = []
    public private(set) var lastSpoken: String = ""
    public private(set) var elapsedSeconds: Int = 0
    public private(set) var error: String?
    public private(set) var sessionID: String?
    public var selectedDate: Date = Date()
    public private(set) var previewEvents: [ServerCalendarEvent] = []
    private var previewEventsRaw: [ServerCalendarEvent] = []
    public private(set) var isPreviewing: Bool = false
    public private(set) var previewError: String?
    public private(set) var recordedDates: Set<String> = []
    public private(set) var statusHint: String = ""
    public private(set) var isEnriching: Bool = false
    /// True from the moment a TTS line starts being synthesized until
    /// audio playback finishes. Mirrors the lifetime of the in-flight
    /// `speak(_:language:)` call. Apple voices flip it briefly (sub-ms
    /// synth, then for the audible duration); Piper voices hold it
    /// during the noticeable ~400–800 ms synthesis pause too, which is
    /// the silent gap the user previously had no signal for.
    public private(set) var isSpeaking: Bool = false
    /// The most recent silence-threshold the user has crossed without
    /// speaking, in seconds (one of 0 / 3 / 6 / 15). Set by
    /// `handleLull(threshold:…)` and cleared whenever the AI starts
    /// speaking, the user advances/skips, or playback is cancelled.
    /// Surfaces in the bottom status row so the user can see WHY the
    /// follow-up prompt fires after a few seconds of quiet.
    public private(set) var silenceLevel: Int = 0
    /// True while the 3 s wake-word listen window is open (after the
    /// ping plays, until match / timeout). Surfaced in the bottom
    /// status row so the user knows the assistant is listening for
    /// "weiter" / "next" specifically.
    public private(set) var isWakeListening: Bool = false

    private let engine = AudioEngine()
    // Resolve the TTS engine fresh on every utterance via `speak(_:language:)`.
    // The previous code cached `VoiceRegistry.engine(for: "de")` here, which
    // meant a voice picked in Settings (Apple ↔ Piper, or Thorsten ↔ Cori)
    // had no effect until the coordinator was rebuilt — typically requiring
    // an app restart. The hardcoded "de" also routed every English line
    // through the German bucket. `speak(_:language:)` below resolves per
    // call with the actual language, so changes take effect on the next
    // line spoken.
    private let lullDetector = LullDetector()
    private var sessionDir: URL?
    private var segmentURLs: [String: URL] = [:]    // multipart name → on-disk URL
    private var segments: [Segment] = []
    private var aiPrompts: [AiPrompt] = []
    private var timer: Timer?
    private var followUpUsed: [Int: Bool] = [:]
    private var followUpRotation: Int = 0
    private var segmentByID: [String: Int] = [:]
    private var pendingFinalisation: [Task<Void, Never>] = []
    public private(set) var pendingImplicitTodos: [Todo] = []
    private var confirmedImplicit: [Todo] = []
    public var confirmedImplicitCount: Int { confirmedImplicit.count }
    private var rejectedImplicit: [TodoRejected] = []
    private var confirmationLanguage: OpenerLanguage = .de
    public private(set) var isAwaitingTodoAnswer: Bool = false
    private var todoAnswerTask: Task<Void, Never>?
    /// Tracks the in-flight 6 s follow-up so we can abort it when the
    /// user resumes speaking before the AI finishes preparing/playing.
    /// Cancelling propagates through the LLM generation step *and*
    /// the Piper synth boundary; if audio is already playing the
    /// AVAudioPlayer is left alone (we don't cut the AI off mid-word).
    private var followUpTask: Task<Void, Never>?
    /// Tracks the in-flight 3 s wake-word listen window. Cancelled by
    /// any state transition that ends the listening phase
    /// (advance / skip / finishEarly / cancel) so the streaming ASR
    /// is torn down promptly and the audio fan-out sink is cleared.
    private var wakeWordTask: Task<Void, Never>?
    /// Segment IDs whose recording was advanced by a wake-word match.
    /// Their audio file gets a tail trim before upload so the matched
    /// command word ("weiter" etc.) doesn't end up in the reflection.
    private var wakeMatchedSegmentIDs: Set<String> = []
    /// Length to lop off the end of a wake-matched segment. Covers the
    /// command word itself (~500 ms), the streaming ASR latency
    /// (~300–500 ms), and a small buffer. Errs on the side of dropping
    /// a hair too much rather than leaking the wake word.
    private static let wakeMatchTrimSeconds: TimeInterval = 1.5
    private let answerLullDetector = LullDetector()
    private static let todoAnswerMaxSeconds: TimeInterval = 7.0
    private var interruptInFlight: Bool = false

    /// Built in `begin()` from settings.order + events + seeds. Each entry
    /// drives exactly one opener+listen cycle, except `.calendar` which
    /// owns the inner event loop.
    private var plan: [PlanStep] = []
    /// Surfaced drive-by seeds for the current session (mirror of the
    /// drive-by step's payload). Used to write the index file at upload.
    private var surfacedSeedIDs: [String] = []

    private var liveActivity: Any?
    private var liveActivityStartedAt: Date?

    private init() {
        observeStateForIsland()
    }

    // MARK: - Plan model -----------------------------------------------

    /// One scheduled section. The calendar block is a single step that
    /// expands at runtime into per-event sub-states.
    private enum PlanStep: Sendable {
        case general(GeneralSection)
        case calendar(events: [ServerCalendarEvent])
        case driveBy(seeds: [DriveBySeed])
    }

    // MARK: - Public commands -----------------------------------------

    public func begin(today: Date? = nil, language: OpenerLanguage = .de) async {
        guard case .idle = state else { return }
        let targetDate = today ?? selectedDate
        state = .briefing
        error = nil
        events = previewEvents
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
        liveActivityStartedAt = Date()
        plan = []
        surfacedSeedIDs = []
        syncLiveActivity()
        Task { await ParakeetManager.shared.warmUp() }
        // Pre-arm the AVAudioSession in the foreground. Without this, the
        // first event's `engine.start()` happens *after* the AI's opener
        // — and if the user has locked the phone during the opener, the
        // session's `setCategory(.playAndRecord, …)` then fires from
        // background and silently fails (`Failed to set properties,
        // error: '!int'`), leaving the input tap unable to deliver
        // buffers. With the session already configured + active here,
        // every later transition between TTS and recording is allowed
        // even from a locked screen.
        do { try await engine.prepareSession() }
        catch { Log.audio.warning("audio session preflight: \(String(describing: error), privacy: .public)") }
        do {
            try makeSessionDir()
            try await fetchCalendar(date: targetDate)
            plan = await buildPlan(forDate: targetDate)
            if plan.isEmpty {
                await finishUploadOrConfirmTodos()
                return
            }
            await runStep(at: 0, language: language)
        } catch {
            self.error = "\(error)"
            state = .failed("\(error)")
            await endLiveActivity()
        }
    }

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
            previewEventsRaw = parsed.events
            previewEvents = parsed.events.filtered(by: WalkthroughSettingsStore.current)
        } catch {
            previewError = "\(error)"
            previewEventsRaw = []
            previewEvents = []
        }
    }

    public func reapplyPreviewFilter() {
        previewEvents = previewEventsRaw.filtered(by: WalkthroughSettingsStore.current)
    }

    public func loadRecordedDates(around anchor: Date = Date()) async {
        let cal = Calendar.current
        let lo = cal.date(byAdding: .day, value: -60, to: anchor) ?? anchor
        let hi = cal.date(byAdding: .day, value: 60, to: anchor) ?? anchor
        let f = Self.dateFormatter
        do {
            let dates = try await ServerClient.shared.recordedDates(
                from: f.string(from: lo),
                to: f.string(from: hi),
            )
            recordedDates = Set(dates)
        } catch {
            // best-effort
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

    /// Advance to the next plan step (or the next event inside the
    /// calendar block).
    public func advance(language: OpenerLanguage = .de) async {
        // Drop the wake-word window + its in-flight follow-up before
        // transitioning. Without these, a stale `wakeWordTask` from
        // the previous event would block `handleLull(case 3)` on the
        // next event (the `wakeWordTask?.cancel()` guard there only
        // helps if the field is non-nil but cancelled — clearing here
        // makes the whole pipeline self-resetting).
        wakeWordTask?.cancel(); wakeWordTask = nil
        isWakeListening = false
        followUpTask?.cancel(); followUpTask = nil
        switch state {
        case .eventListening(let stepIdx, let eventIdx):
            await stopSegmentCapture()
            await advanceFromCalendar(stepIndex: stepIdx, eventIndex: eventIdx, language: language)
        case .eventOpener(let stepIdx, let eventIdx):
            interruptInFlight = true
            await cancelTTS()
            await advanceFromCalendar(stepIndex: stepIdx, eventIndex: eventIdx, language: language)
        case .generalListening(let stepIdx, _):
            await stopSegmentCapture()
            await runStep(at: stepIdx + 1, language: language)
        case .generalOpener(let stepIdx, _):
            interruptInFlight = true
            await cancelTTS()
            await runStep(at: stepIdx + 1, language: language)
        case .driveByListening(let stepIdx):
            await stopSegmentCapture()
            await runStep(at: stepIdx + 1, language: language)
        case .driveByOpener(let stepIdx):
            interruptInFlight = true
            await cancelTTS()
            await runStep(at: stepIdx + 1, language: language)
        default:
            return
        }
    }

    /// Skip the current step's segment without recording it.
    public func skip(language: OpenerLanguage = .de) async {
        wakeWordTask?.cancel(); wakeWordTask = nil
        isWakeListening = false
        followUpTask?.cancel(); followUpTask = nil
        switch state {
        case .eventListening(let stepIdx, let eventIdx):
            await dropStagedSegment(forStepIndex: stepIdx, eventIndex: eventIdx)
            await advanceFromCalendar(stepIndex: stepIdx, eventIndex: eventIdx, language: language)
        case .eventOpener(let stepIdx, let eventIdx):
            interruptInFlight = true
            await cancelTTS()
            await advanceFromCalendar(stepIndex: stepIdx, eventIndex: eventIdx, language: language)
        case .generalListening(let stepIdx, _):
            await dropStagedSegment(forStepIndex: stepIdx, eventIndex: nil)
            await runStep(at: stepIdx + 1, language: language)
        case .generalOpener(let stepIdx, _):
            interruptInFlight = true
            await cancelTTS()
            await runStep(at: stepIdx + 1, language: language)
        case .driveByListening(let stepIdx):
            await dropStagedSegment(forStepIndex: stepIdx, eventIndex: nil)
            // Don't mark seeds as surfaced if user skipped the closing.
            surfacedSeedIDs = []
            await runStep(at: stepIdx + 1, language: language)
        case .driveByOpener(let stepIdx):
            interruptInFlight = true
            await cancelTTS()
            surfacedSeedIDs = []
            await runStep(at: stepIdx + 1, language: language)
        default:
            return
        }
    }

    /// Jump straight to ingest from any in-event/in-section state.
    public func finishEarly(language: OpenerLanguage = .de) async {
        wakeWordTask?.cancel(); wakeWordTask = nil
        isWakeListening = false
        followUpTask?.cancel(); followUpTask = nil
        switch state {
        case .eventListening, .generalListening, .driveByListening:
            await stopSegmentCapture()
            await ingestAndUpload()
        case .briefing, .eventOpener, .generalOpener, .driveByOpener:
            interruptInFlight = true
            await cancelTTS()
            await ingestAndUpload()
        default:
            break
        }
    }

    public func cancel() async {
        // Set the abort flag FIRST, before any await. The runEvent /
        // runGeneral / runDriveBy chains all check `interruptInFlight`
        // after each `await speak(...)` — without setting it here, a
        // suspended chain would resume after `cancelTTS()` returns and
        // happily call `startEventCapture()` + `state = .eventListening`
        // again, which is what was causing the walkthrough screen to
        // re-appear and audio to keep playing after the X tap. The
        // existing advance() / skip() / finishEarly() paths already use
        // this signal — cancel() just wasn't joining the protocol.
        interruptInFlight = true
        // Halt the lull detector so a buffered threshold callback can't
        // fire `handleLull` → `speakFollowUp` after we've torn down.
        // (The detector also auto-pauses when the engine stops feeding
        // it, but stopping it explicitly closes the timing race.)
        lullDetector.stop()
        // Cancel any in-flight follow-up Task spawned by handleLull.
        // Without this, an LLM call that started just before the user
        // tapped X would still resolve later and call `speak()` on the
        // already-torn-down coordinator.
        followUpTask?.cancel(); followUpTask = nil
        // Same for the 3 s wake-word window. Cancellation makes the
        // task drop out of `withTaskGroup`, after which it tears down
        // the streaming ASR + clears the audio fan-out sink itself.
        wakeWordTask?.cancel(); wakeWordTask = nil
        isWakeListening = false
        timer?.invalidate(); timer = nil
        await cancelTodoAnswerCapture()
        // Engine.stop() finalises the in-flight segment file on disk —
        // that's what "recordings until this point shall be stored"
        // depends on. The local session dir survives; it just won't be
        // ingested + uploaded to the server, since the user explicitly
        // aborted rather than reached DONE.
        try? await engine.stop()
        // Now tear the AVAudioEngine down. We kept it alive across the
        // walkthrough's TTS ↔ recording transitions so iOS wouldn't
        // reject `kAUStartIO` from a locked screen — but at cancel we
        // genuinely want the audio session released.
        await engine.shutdown()
        await cancelTTS()
        state = .idle
        await endLiveActivity()
    }

    // MARK: - Plan building --------------------------------------------

    private func buildPlan(forDate target: Date) async -> [PlanStep] {
        let order = WalkthroughSettingsStore.order
        let generals = WalkthroughSettingsStore.generals
        let generalsByID: [String: GeneralSection] = Dictionary(
            uniqueKeysWithValues: generals.map { ($0.id, $0) }
        )

        var steps: [PlanStep] = []
        for entry in order {
            switch entry {
            case .general(let id):
                if let g = generalsByID[id] {
                    steps.append(.general(g))
                }
            case .calendarEvents:
                if !events.isEmpty {
                    steps.append(.calendar(events: events))
                }
            case .driveBy:
                let seeds = await loadUnsurfacedSeeds(forDate: target)
                steps.append(.driveBy(seeds: seeds))
            }
        }
        return steps
    }

    /// Seeds captured on or before the session's target day that haven't
    /// been surfaced in a prior session yet.
    private func loadUnsurfacedSeeds(forDate target: Date) async -> [DriveBySeed] {
        let surfaced = LocalStore.surfacedSeedIDs()
        let cutoff = Calendar.current.date(
            byAdding: .day, value: 1,
            to: Calendar.current.startOfDay(for: target)
        ) ?? target
        return SessionHistoryStore.unsurfacedDriveBys(before: cutoff, surfaced: surfaced)
    }

    // MARK: - Step dispatch --------------------------------------------

    private func runStep(at index: Int, language: OpenerLanguage) async {
        guard index >= 0, index < plan.count else {
            await ingestAndUpload()
            return
        }
        switch plan[index] {
        case .general(let section):
            await runGeneral(stepIndex: index, section: section, language: language)
        case .calendar(let evts):
            // First event in this calendar block.
            await runEvent(stepIndex: index, eventIndex: 0,
                           events: evts, language: language)
        case .driveBy(let seeds):
            await runDriveBy(stepIndex: index, seeds: seeds, language: language)
        }
    }

    private func advanceFromCalendar(
        stepIndex: Int,
        eventIndex: Int,
        language: OpenerLanguage
    ) async {
        guard stepIndex >= 0, stepIndex < plan.count,
              case .calendar(let evts) = plan[stepIndex] else {
            await runStep(at: stepIndex + 1, language: language)
            return
        }
        let next = eventIndex + 1
        if next < evts.count {
            await runEvent(stepIndex: stepIndex, eventIndex: next,
                           events: evts, language: language)
        } else {
            await runStep(at: stepIndex + 1, language: language)
        }
    }

    // MARK: - Calendar event step --------------------------------------

    private func runEvent(
        stepIndex: Int,
        eventIndex: Int,
        events evts: [ServerCalendarEvent],
        language: OpenerLanguage
    ) async {
        guard eventIndex < evts.count else { return }
        interruptInFlight = false
        state = .eventOpener(stepIndex: stepIndex, eventIndex: eventIndex)
        statusHint = ""
        let line = OpenerTemplates.line(
            for: evts[eventIndex],
            index: eventIndex,
            of: evts.count,
            language: language
        )
        lastSpoken = line
        let segID = makeEventSegmentID(stepIndex: stepIndex, eventIndex: eventIndex)
        recordAiPrompt(role: "opener", segmentID: segID, text: line)
        await speak(line, language: language.rawValue)
        // State-tuple guard: if the user tapped Weiter mid-opener and
        // advance() kicked off runEvent(N+1), `state` will already be
        // `.eventOpener(N+1)` by the time our `await speak` returns.
        // The legacy `interruptInFlight` check broke down because the
        // newer runEvent invocation resets that flag at its own entry
        // (line above), so this older chain would happily proceed to
        // startEventCapture on N — double-starting the audio engine on
        // a segment that the later chain is also recording, which is
        // the `File exists` error you saw on `s01e05.m4a.tmp`.
        guard case .eventOpener(let liveStep, let liveEvt) = state,
              liveStep == stepIndex, liveEvt == eventIndex else { return }
        if interruptInFlight { return }
        do {
            try await startEventCapture(
                segmentID: segID,
                event: evts[eventIndex]
            )
            // Re-check after startEventCapture too — that's an async
            // hop where another advance could fire.
            guard case .eventOpener(let liveStep2, let liveEvt2) = state,
                  liveStep2 == stepIndex, liveEvt2 == eventIndex else { return }
            state = .eventListening(stepIndex: stepIndex, eventIndex: eventIndex)
            startTimer()
            startLullDetection(eventIndex: eventIndex, language: language,
                               step: stepIndex, evts: evts)
        } catch {
            self.error = "\(error)"
            state = .failed("\(error)")
        }
    }

    private func makeEventSegmentID(stepIndex: Int, eventIndex: Int) -> String {
        // Step prefix + per-event suffix keeps ids unique even when the
        // user has multiple calendar blocks (currently the model allows
        // only one, but the encoding is forward-compatible).
        "s\(zeroPad(stepIndex + 1))e\(zeroPad(eventIndex + 1))"
    }

    // MARK: - General section step -------------------------------------

    private func runGeneral(
        stepIndex: Int,
        section: GeneralSection,
        language: OpenerLanguage
    ) async {
        interruptInFlight = false
        state = .generalOpener(stepIndex: stepIndex, sectionID: section.id)
        statusHint = ""
        let line = section.introText.trimmingCharacters(in: .whitespacesAndNewlines)
        lastSpoken = line
        let segID = "s\(zeroPad(stepIndex + 1))"
        recordAiPrompt(role: "general_opener", segmentID: segID, text: line)
        if !line.isEmpty {
            await speak(line, language: language.rawValue)
        }
        // Same state-tuple guard as runEvent — if a concurrent advance
        // moved on (state is now .generalOpener(N+1) or .eventOpener(...) or .idle),
        // bail rather than double-start the engine on this section's segment.
        guard case .generalOpener(let liveStep, let liveID) = state,
              liveStep == stepIndex, liveID == section.id else { return }
        if interruptInFlight { return }
        do {
            try await startGeneralCapture(segmentID: segID, section: section)
            guard case .generalOpener(let liveStep2, let liveID2) = state,
                  liveStep2 == stepIndex, liveID2 == section.id else { return }
            state = .generalListening(stepIndex: stepIndex, sectionID: section.id)
            startTimer()
        } catch {
            self.error = "\(error)"
            state = .failed("\(error)")
        }
    }

    // MARK: - Drive-by section step ------------------------------------

    private func runDriveBy(
        stepIndex: Int,
        seeds: [DriveBySeed],
        language: OpenerLanguage
    ) async {
        interruptInFlight = false
        state = .driveByOpener(stepIndex: stepIndex)
        statusHint = ""
        confirmationLanguage = language

        // Surface seeds first (if any), then ask the closing question.
        // Both halves go into the same `free_reflection` segment.
        let segID = "s\(zeroPad(stepIndex + 1))"
        let intro = composeDriveByIntro(seeds: seeds, language: language)
        if !intro.isEmpty {
            recordAiPrompt(role: "drive_by_recap", segmentID: segID, text: intro)
            lastSpoken = intro
            await speak(intro, language: language.rawValue)
            // State-tuple guard against a concurrent advance() spawning
            // the next step while we were mid-speak. See runEvent for
            // the full reasoning.
            guard case .driveByOpener(let liveStep) = state,
                  liveStep == stepIndex else { return }
            if interruptInFlight { return }
        }

        let closing = language == .de
            ? "Willst du noch etwas zum ganzen Tag sagen?"
            : "Anything else you want to say about the day overall?"
        recordAiPrompt(role: "closing_prompt", segmentID: segID, text: closing)
        lastSpoken = closing
        await speak(closing, language: language.rawValue)
        guard case .driveByOpener(let liveStep) = state,
              liveStep == stepIndex else { return }
        if interruptInFlight { return }

        do {
            try await startDriveByCapture(segmentID: segID, seeds: seeds)
            guard case .driveByOpener(let liveStep2) = state,
                  liveStep2 == stepIndex else { return }
            state = .driveByListening(stepIndex: stepIndex)
            startTimer()
        } catch {
            self.error = "\(error)"
            await ingestAndUpload()
        }
    }

    private func composeDriveByIntro(
        seeds: [DriveBySeed],
        language: OpenerLanguage
    ) -> String {
        guard !seeds.isEmpty else { return "" }
        let count = seeds.count
        switch language {
        case .de:
            switch count {
            case 1: return "Du hast heute eine Notiz aufgenommen. Ich nehme sie mit in den Eintrag."
            default: return "Du hast heute \(count) Notizen aufgenommen. Ich nehme sie mit in den Eintrag."
            }
        case .en:
            switch count {
            case 1: return "You captured one note earlier. I'll fold it into the entry."
            default: return "You captured \(count) notes earlier. I'll fold them into the entry."
            }
        }
    }

    // MARK: - Enrichment (M7) -------------------------------------------

    public func askEnrichment(
        query: String,
        language: OpenerLanguage = .de
    ) async {
        guard !isEnriching else { return }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isEnriching = true
        defer { isEnriching = false }

        let segmentID: String? = currentRecordingSegmentID
        recordAiPrompt(role: "enrichment_query", segmentID: segmentID, text: trimmed)

        let cue = language == .de
            ? "Einen Moment, ich schaue nach."
            : "One moment, let me check."
        await speak(cue, language: language.rawValue)

        do {
            let result = try await EnrichmentService.shared.enrich(
                query: trimmed,
                responseLanguage: language.rawValue
            )
            recordAiPrompt(role: "enrichment_answer", segmentID: segmentID, text: result.summary)
            await speak(result.summary, language: language.rawValue)
        } catch {
            Log.app.warning(
                "enrichment failed: \(String(describing: error), privacy: .public)"
            )
            let fallback = language == .de
                ? "Ich konnte die Frage gerade nicht beantworten."
                : "I couldn't answer that just now."
            recordAiPrompt(role: "enrichment_failed", segmentID: segmentID, text: "\(error)")
            await speak(fallback, language: language.rawValue)
        }
    }

    private var currentRecordingSegmentID: String? {
        switch state {
        case .eventListening(let s, let e):
            return makeEventSegmentID(stepIndex: s, eventIndex: e)
        case .generalListening(let s, _), .driveByListening(let s):
            return "s\(zeroPad(s + 1))"
        default:
            return nil
        }
    }

    // MARK: - Capture --------------------------------------------------

    private func startEventCapture(
        segmentID: String,
        event: ServerCalendarEvent
    ) async throws {
        guard let sessionDir else { throw NSError(domain: "Walkthrough", code: 1) }
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

    private func startGeneralCapture(
        segmentID: String,
        section: GeneralSection
    ) async throws {
        guard let sessionDir else { throw NSError(domain: "Walkthrough", code: 1) }
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
        let seg = GeneralSectionSegment(
            segment_id: segmentID,
            section_id: section.id,
            title: section.title,
            prompt_text: section.introText,
            audio_file: path
        )
        segments.append(.generalSection(seg))
        segmentByID[segmentID] = segments.count - 1
    }

    private func startDriveByCapture(
        segmentID: String,
        seeds: [DriveBySeed]
    ) async throws {
        guard let sessionDir else { throw NSError(domain: "Walkthrough", code: 1) }
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

        // Attach each surfaced seed as its own `drive_by` segment so the
        // server has the audio + transcript already available. Files are
        // copied into the session dir to keep the upload bundle
        // self-contained.
        var surfaced: [String] = []
        for seed in seeds {
            let copyName = "seed_\(sanitize(seed.seed_id)).m4a"
            let copyPath = "segments/\(copyName)"
            let copyURL = sessionDir.appending(path: copyPath)
            do {
                try FileManager.default.copyItem(at: seed.audio_file_url, to: copyURL)
            } catch {
                Log.app.warning(
                    "drive-by seed copy failed (\(seed.seed_id, privacy: .public)): \(String(describing: error), privacy: .public)"
                )
                continue
            }
            segmentURLs[copyPath] = copyURL
            let dbSeg = DriveBySegment(
                segment_id: "db_\(sanitize(seed.seed_id))",
                captured_at: ISO8601DateFormatter().string(from: seed.captured_at),
                audio_file: copyPath,
                transcript: seed.transcript,
                language: seed.language,
                seed_id: seed.seed_id
            )
            segments.append(.driveBy(dbSeg))
            surfaced.append(seed.seed_id)
        }
        surfacedSeedIDs = surfaced
    }

    private func dropStagedSegment(forStepIndex stepIdx: Int, eventIndex: Int?) async {
        try? await engine.stop()
        let segID: String = {
            if let eIdx = eventIndex {
                return makeEventSegmentID(stepIndex: stepIdx, eventIndex: eIdx)
            }
            return "s\(zeroPad(stepIdx + 1))"
        }()
        let path = mediaPath(for: segID)
        if let url = segmentURLs[path] {
            try? FileManager.default.removeItem(at: url)
            segmentURLs.removeValue(forKey: path)
        }
        segments.removeAll { seg in
            switch seg {
            case .calendarEvent(let v):  return v.segment_id == segID
            case .freeReflection(let v): return v.segment_id == segID
            case .generalSection(let v): return v.segment_id == segID
            case .driveBy, .emptyBlock:  return false
            }
        }
    }

    private func stopSegmentCapture() async {
        timer?.invalidate(); timer = nil
        elapsedSeconds = 0
        lullDetector.stop()

        let finishingSegmentID: String? = currentRecordingSegmentID
        let finishingURL = finishingSegmentID.flatMap { segmentURLs[mediaPath(for: $0)] }

        do { _ = try await engine.stop() } catch {
            Log.audio.warning("walkthrough engine stop: \(String(describing: error), privacy: .public)")
        }

        // Tail-trim the segment file if it was advanced by a wake-word
        // match. We do this *before* spawning the finalise task so
        // Parakeet sees the cleaned file. Server-side Whisper picks
        // up the same trimmed audio at upload time. The trim runs
        // synchronously on this code path because the file is small
        // (a few minutes of AAC at 64 kbps) and the export-passthrough
        // preset just rewrites the moov atom.
        if let segmentID = finishingSegmentID,
           let url = finishingURL,
           wakeMatchedSegmentIDs.contains(segmentID) {
            do {
                try await AudioMerger.trimTail(of: url, removingLastSeconds: Self.wakeMatchTrimSeconds)
                Log.audio.notice(
                    "wake-word trim: \(segmentID, privacy: .public) (-\(Self.wakeMatchTrimSeconds)s)"
                )
            } catch {
                Log.audio.warning(
                    "wake-word trim failed for \(segmentID, privacy: .public): \(String(describing: error), privacy: .public)"
                )
            }
            wakeMatchedSegmentIDs.remove(segmentID)
        }

        if let segmentID = finishingSegmentID, let url = finishingURL {
            let task = Task { [weak self] in
                guard let self else { return }
                await self.finalise(segmentID: segmentID, url: url)
            }
            pendingFinalisation.append(task)
        }
        try? await Task.sleep(nanoseconds: 300_000_000)
    }

    /// Per-segment finaliser: runs Parakeet on the captured M4A, parses
    /// explicit todo triggers, surfaces implicit candidates, and writes the
    /// results back onto the segment in `segments[]`.
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
        case .generalSection(var gs):
            gs.transcript = transcript.text
            gs.language = transcript.language
            segments[idx] = .generalSection(gs)
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

    // MARK: - Ingest ----------------------------------------------------

    private func ingestAndUpload() async {
        timer?.invalidate(); timer = nil
        do {
            try await stopSegmentCaptureNoTranscribe()
            for task in pendingFinalisation { await task.value }
            pendingFinalisation.removeAll()
            await finishUploadOrConfirmTodos()
        } catch {
            self.error = "\(error)"
            state = .failed("\(error)")
        }
    }

    private func finishUploadOrConfirmTodos() async {
        if !pendingImplicitTodos.isEmpty {
            await beginTodoConfirmation()
            return
        }
        do { try await finishUpload() }
        catch {
            self.error = "\(error)"
            state = .failed("\(error)")
        }
    }

    private func finishUpload() async throws {
        state = .ingesting
        await endLiveActivity()
        let manifest = try buildManifest()
        sessionID = manifest.session_id
        if let dir = sessionDir {
            do { try LocalStore.writeManifest(manifest, to: dir) }
            catch { Log.app.warning("manifest snapshot failed: \(String(describing: error), privacy: .public)") }
        }
        // Mark surfaced seeds *now* so a successful enqueue doesn't leave
        // them in the unsurfaced pool — the upload itself retries with
        // exponential backoff and we don't want to re-surface across
        // retries.
        if !surfacedSeedIDs.isEmpty {
            LocalStore.markSeedsSurfaced(ids: surfacedSeedIDs)
        }
        await SessionUploader.shared.enqueue(
            manifest: manifest,
            audioFiles: segmentURLs
        )
        recordedDates.insert(manifest.date)
        state = .done
        // Walkthrough is over — release the always-running audio engine
        // and let the audio session deactivate cleanly. The next
        // walkthrough will pre-arm again from foreground.
        await engine.shutdown()
        Task { await loadRecordedDates(around: selectedDate) }
    }

    // MARK: - Follow-up logic ------------------------------------------

    private func startLullDetection(
        eventIndex: Int,
        language: OpenerLanguage,
        step: Int,
        evts: [ServerCalendarEvent]
    ) {
        // Loop timing: 3 s → ping + wake-word window opens. 6 s → wake
        // window closes (if still open) and the AI fires the follow-up
        // remark. 15 s → silence indicator updates. 20 s → auto-advance
        // to the next meeting (the user has clearly finished).
        lullDetector.thresholds = [3, 6, 15, 20]
        lullDetector.start(
            onThresholdCrossed: { [weak self] threshold in
                guard let self else { return }
                Task { @MainActor in
                    guard case .eventListening(let s, let e) = self.state,
                          s == step, e == eventIndex else {
                        return
                    }
                    await self.handleLull(
                        threshold: threshold,
                        eventIndex: eventIndex,
                        language: language,
                        evts: evts
                    )
                }
            },
            onSpeechResumed: { [weak self] in
                guard let self else { return }
                Task { @MainActor in
                    await self.handleSpeechResumed()
                }
            }
        )
    }

    /// User started speaking again after at least one lull threshold
    /// had fired. Reset the silence-level UI hint and abort any
    /// follow-up TTS that's still being prepared (LLM gen + Piper
    /// synth) so the AI doesn't speak over the user. Audio that's
    /// already playing audibly is left alone — Task cancellation only
    /// propagates through the pre-playback path in `PiperTTS`.
    private func handleSpeechResumed() async {
        silenceLevel = 0
        statusHint = ""
        if let task = followUpTask {
            task.cancel()
            followUpTask = nil
        }
    }

    /// Per-silence-run loop, identical for every silence cycle within
    /// an event:
    ///
    /// ```
    ///                       ┌── user speaks ──┐
    ///                       ▼                 │  resets all of below
    ///   t=0   ── quiet listening, no UI ──    │
    ///   t=3   ── wake-window opens ───────────│
    ///                "Höre auf „Weiter"…" ───►│
    ///                ASR streaming on PCM ──► │
    ///   t=6   ── wake-window CLOSES ─────────►│   ALWAYS, regardless of run #
    ///                "Stille seit 6s" ───────►│
    ///                + AI follow-up question ─│   ONLY on first silence run
    ///                                          │   of this event (gated by
    ///                                          │   `followUpUsed[eventIndex]`)
    ///   t=15  ── "Stille seit 15s" ──────────►│
    ///   t=20  ── auto-advance to next event ──┘
    /// ```
    ///
    /// Earlier the wake-cancel + follow-up dispatch were both wrapped
    /// in the `followUpUsed` guard — meaning the second silence run
    /// (where `followUpUsed = true`) hit `return` before cancelling the
    /// wake task, so the wake window stayed visually open until its own
    /// 8 s timeout. The user perceived this as "no 3-second indicator
    /// on the second run, only the 6-second indicator a few seconds
    /// late". Splitting the two responsibilities fixes the loop.
    private func handleLull(
        threshold: Int,
        eventIndex: Int,
        language: OpenerLanguage,
        evts: [ServerCalendarEvent]
    ) async {
        silenceLevel = threshold
        switch threshold {

        case 3:
            // Open the wake-word listen window. Spawned as a tracked
            // Task so handleLull returns promptly; the wake task
            // plays the ping, opens a streaming ASR, listens until
            // either a wake word matches (`advance`/`finishEarly`),
            // the 6 s threshold cancels it, or its own ~8 s timeout
            // closes it.
            //
            // If a stale task is hanging around (cancelled but the
            // body hadn't yet hit its `wakeWordTask = nil` line) we
            // cancel it explicitly so it can't shadow the new window.
            wakeWordTask?.cancel(); wakeWordTask = nil
            let lang = language
            wakeWordTask = Task { [weak self] in
                await self?.runWakeWordWindow(language: lang)
            }

        case 6:
            // Branch on output route. With headphones (or any non-
            // speaker output) we LEAVE the wake-word window open so
            // the user can interrupt the AI's follow-up question with
            // "weiter" / "fertig" — the speaker→mic feedback that
            // makes this dangerous on the built-in speaker isn't a
            // factor when audio is going into AirPods / a wired headset
            // / Bluetooth / CarPlay. The wake-window timeout was bumped
            // to 15 s at window-open time precisely to survive the AI
            // follow-up TTS (~7 s) plus a small post-TTS buffer.
            let extendThroughFollowUp = Self.isHeadphonesOutputActive()
            if !extendThroughFollowUp {
                wakeWordTask?.cancel(); wakeWordTask = nil
                isWakeListening = false
            }

            // Only fire the AI follow-up question once per event.
            // After the first time, subsequent silence runs simply
            // show "Stille seit 6s" and let the lull keep ticking.
            guard followUpUsed[eventIndex] != true else {
                Diag.log("lull case=6 follow-up already used, no AI prompt")
                return
            }
            followUpUsed[eventIndex] = true

            // Spawn the follow-up as a *cancellable* Task and stash
            // the handle. `handleSpeechResumed` cancels it if the
            // user starts talking again before the AI finishes
            // preparing. A wake-word match (in headphones mode)
            // cancels it too — see `runWakeWordWindow`'s match path.
            // Don't `await` here — the lull callback path needs to
            // return promptly so the main actor stays responsive to a
            // concurrent speech-resumed event.
            Diag.log("lull case=6 spawning follow-up task headphones=\(extendThroughFollowUp)")
            let captured = (eventIndex: eventIndex, language: language, evts: evts)
            followUpTask = Task { [weak self] in
                guard let self else { return }
                await self.speakFollowUp(
                    eventIndex: captured.eventIndex,
                    language: captured.language,
                    evts: captured.evts
                )
            }

        case 15:
            // No coordinator-side action — the silence row's
            // "Stille seit 15s" message is enough on its own.
            break

        case 20:
            // The user has been silent for 20 s straight. Auto-advance
            // to the next meeting — they're clearly done with this
            // one.
            Diag.log("lull case=20 auto-advance")
            wakeWordTask?.cancel(); wakeWordTask = nil
            isWakeListening = false
            await advance(language: language)

        default:
            break
        }
    }

    private func speakFollowUp(
        eventIndex: Int,
        language: OpenerLanguage,
        evts: [ServerCalendarEvent]
    ) async {
        guard eventIndex < evts.count else { return }
        let event = evts[eventIndex]
        let attendeeNames = event.attendees.map(\.name).filter { !$0.isEmpty }

        var line: String?
        let llm = AppleFoundationLLM.shared
        if await llm.isAvailable {
            do {
                line = try await llm.generateFollowUp(
                    eventTitle: event.subject,
                    attendees: attendeeNames,
                    userTranscript: "",
                    language: language.rawValue
                )
                Log.app.info("follow-up via FoundationModels for event \(eventIndex, privacy: .public)")
            } catch {
                Log.app.warning(
                    "FoundationModels follow-up failed: \(String(describing: error), privacy: .public)"
                )
            }
        }
        // First cancellation gate: bail if the user resumed speech
        // while the LLM was generating. Prevents the AI from speaking
        // over the user just because they paused for 6 seconds.
        if Task.isCancelled { return }

        if line == nil || line?.isEmpty == true {
            line = OpenerTemplates.followUp(language: language, rotation: followUpRotation)
            followUpRotation += 1
        }
        guard let spoken = line, !spoken.isEmpty else { return }

        lastSpoken = spoken
        let segID: String? = {
            if case .eventListening(let s, let e) = state {
                return makeEventSegmentID(stepIndex: s, eventIndex: e)
            }
            return nil
        }()
        recordAiPrompt(role: "follow_up", segmentID: segID, text: spoken)
        // Second cancellation gate: skip the speak entirely if the
        // user spoke during prompt-template selection. PiperTTS's own
        // serial queue checks `Task.isCancelled` between synth and
        // play too, so even if `speak` was called we still have one
        // more bailout before audio reaches the speaker.
        if Task.isCancelled { return }
        await speak(spoken, language: language.rawValue)
    }

    // MARK: - Implicit-todo confirmation (M8 phase B) -----------------

    public var currentTodoCandidate: Todo? {
        guard case .confirmingTodos(let i) = state,
              i >= 0, i < pendingImplicitTodos.count else { return nil }
        return pendingImplicitTodos[i]
    }

    public var todoCandidateProgress: (index: Int, total: Int)? {
        guard case .confirmingTodos(let i) = state else { return nil }
        return (i, pendingImplicitTodos.count)
    }

    public func confirmCurrentTodo() async {
        await cancelTodoAnswerCapture()
        guard case .confirmingTodos(let i) = state,
              i >= 0, i < pendingImplicitTodos.count else { return }
        let candidate = pendingImplicitTodos[i]
        confirmedImplicit.append(candidate)
        recordAiPrompt(role: "todo_confirmed",
                       segmentID: candidate.source_segment_id,
                       text: candidate.text)
        await advanceTodoConfirmation()
    }

    public func rejectCurrentTodo() async {
        await cancelTodoAnswerCapture()
        guard case .confirmingTodos(let i) = state,
              i >= 0, i < pendingImplicitTodos.count else { return }
        let candidate = pendingImplicitTodos[i]
        rejectedImplicit.append(TodoRejected(
            text: candidate.text,
            source_segment_id: candidate.source_segment_id
        ))
        recordAiPrompt(role: "todo_rejected",
                       segmentID: candidate.source_segment_id,
                       text: candidate.text)
        await advanceTodoConfirmation()
    }

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
        recordAiPrompt(role: "todo_refined",
                       segmentID: original.source_segment_id,
                       text: trimmed)
        await advanceTodoConfirmation()
    }

    private func beginTodoConfirmation() async {
        let lang = confirmationLanguage
        let intro = lang == .de
            ? "Mir sind ein paar mögliche Aufgaben aufgefallen. Lass uns kurz drüber gehen."
            : "I noticed a few possible to-dos. Let's run through them quickly."
        lastSpoken = intro
        await speak(intro, language: lang.rawValue)
        await advanceTodoConfirmation(initial: true)
    }

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
        recordAiPrompt(role: "todo_prompt",
                       segmentID: candidate.source_segment_id,
                       text: line)
        await speak(line, language: lang.rawValue)
        await beginTodoAnswerCapture(forCandidateIndex: i)
    }

    // MARK: - Voice answer capture (M8 phase B-2) ----------------------

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
            path: "segments/confirm_\(zeroPad(index)).m4a"
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

        let maxSeconds = Self.todoAnswerMaxSeconds
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for await crossed in lullStream where crossed >= 2 { _ = crossed; break }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(maxSeconds * 1e9))
            }
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

        guard case .confirmingTodos(let nowIndex) = state, nowIndex == index else { return }

        let transcript: ParakeetManager.Transcript
        do {
            transcript = try await ParakeetManager.shared.transcribe(audioURL: url)
        } catch {
            Log.app.warning(
                "todo answer transcribe failed: \(String(describing: error), privacy: .public)"
            )
            return
        }

        recordAiPrompt(role: "todo_answer_voice",
                       segmentID: pendingImplicitTodos[index].source_segment_id,
                       text: transcript.text)

        let outcome = TodoAnswerParser.parse(transcript.text)
        Log.app.info(
            "todo answer (\(index, privacy: .public)) → \(String(describing: outcome), privacy: .public) raw=\(transcript.text, privacy: .public)"
        )

        switch outcome {
        case .confirm:        await confirmCurrentTodo()
        case .reject:         await rejectCurrentTodo()
        case .refine(let text): await refineCurrentTodo(text)
        case .unknown:        break
        }
    }

    private func cancelTodoAnswerCapture() async {
        if let task = todoAnswerTask {
            task.cancel()
            todoAnswerTask = nil
        }
        if isAwaitingTodoAnswer {
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
        events = response.events.filtered(by: WalkthroughSettingsStore.current)
    }

    private func buildManifest() throws -> Manifest {
        guard let sessionID else { throw NSError(domain: "Walkthrough", code: 2) }
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
            drive_by_seeds_surfaced: surfacedSeedIDs,
            ai_prompts: aiPrompts,
            response_language_setting: "match_input"
        )
    }

    private func sanitize(_ s: String) -> String {
        s.replacingOccurrences(of: ":", with: "-")
         .replacingOccurrences(of: "+", with: "_")
    }

    private func zeroPad(_ n: Int) -> String { String(format: "%02d", n) }

    private func startTimer() {
        timer?.invalidate()
        elapsedSeconds = 0
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.elapsedSeconds += 1
                self.syncLiveActivity()
            }
        }
    }

    // MARK: - UI helpers (consumed by WalkthroughView) -----------------

    /// Title shown in the page header for the current state. The view
    /// previously poked into `events[currentIndex]` directly; that still
    /// works for calendar events, but generals + drive-by need their own
    /// labels. Falls back to the generic "Abend".
    public var currentSectionTitle: String? {
        switch state {
        case .generalOpener(_, let id), .generalListening(_, let id):
            return WalkthroughSettingsStore.generals.first { $0.id == id }?.title
        case .driveByOpener, .driveByListening:
            return confirmationLanguage == .de ? "Tagesabschluss" : "Day close"
        default:
            return nil
        }
    }

    /// Convenience used by the header: the (1-based) event index inside the
    /// calendar block, plus its total. Returns `nil` outside the block.
    public var calendarProgress: (current: Int, total: Int)? {
        switch state {
        case .eventOpener(_, let e), .eventListening(_, let e):
            return (e + 1, events.count)
        default:
            return nil
        }
    }

    public var currentCalendarEvent: ServerCalendarEvent? {
        switch state {
        case .eventOpener(_, let e), .eventListening(_, let e):
            return e < events.count ? events[e] : nil
        case .briefing where !events.isEmpty:
            return events[0]
        default:
            return nil
        }
    }

    // MARK: - Live activity (Dynamic Island state indicator) ---------

    private var liveActivityKind: CaptureActivityAttributes.Kind? {
        switch state {
        case .briefing, .eventOpener, .generalOpener, .driveByOpener: return .speaking
        case .eventListening, .generalListening, .driveByListening:   return .listening
        case .confirmingTodos:                                        return .listening
        case .idle, .ingesting, .done, .failed:                       return nil
        }
    }

    private func syncLiveActivity() {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        guard let kind = liveActivityKind else {
            Task { await endLiveActivity() }
            return
        }
        let started = liveActivityStartedAt ?? Date()
        liveActivityStartedAt = started
        // Counter shows the *current segment's* elapsed seconds, mirror
        // of the in-app `ListeningTimer`. During speaking states we send
        // 0 (the lock-screen UI also hides the counter for `.speaking`).
        // Previously this computed `Date() - liveActivityStartedAt`,
        // which is a wall-clock since `begin()` — that's why the counter
        // never zeroed and ticked during speaking.
        let elapsed = (kind == .speaking) ? 0 : self.elapsedSeconds
        let content = CaptureActivityAttributes.ContentState(
            startedAt: started,
            elapsedSeconds: elapsed,
            kind: kind
        )
        if let activity = liveActivity as? Activity<CaptureActivityAttributes> {
            Task { await activity.update(.init(state: content, staleDate: nil)) }
        } else {
            do {
                liveActivity = try Activity.request(
                    attributes: CaptureActivityAttributes(),
                    content: .init(state: content, staleDate: nil)
                )
            } catch {
                Log.app.warning("Walkthrough live activity start failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    private func endLiveActivity() async {
        guard let activity = liveActivity as? Activity<CaptureActivityAttributes> else { return }
        await activity.end(nil, dismissalPolicy: .immediate)
        liveActivity = nil
        liveActivityStartedAt = nil
    }

    private func observeStateForIsland() {
        withObservationTracking {
            _ = self.state
        } onChange: {
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.syncLiveActivity()
                self.observeStateForIsland()
            }
        }
    }

    // MARK: - TTS routing

    /// Resolve and speak through whichever engine the user has currently
    /// picked for `language`. Called per-utterance (not cached) so a voice
    /// change in Settings takes effect on the very next line.
    ///
    /// Sets `isSpeaking` for the lifetime of the underlying `speak()`
    /// call so the UI can render a "Stimme spricht…" indicator. The
    /// flag covers both the synthesis phase (Piper's ~400–800 ms
    /// silent gap) and the audible playback phase, since the engines
    /// don't expose them separately and the user's request was for any
    /// "TTS process running" cue.
    private func speak(_ text: String, language: String) async {
        isSpeaking = true
        // Clear any silence indicator when the AI takes over — by the
        // time playback ends the user has heard the prompt and can
        // resume speaking, so the previously-crossed threshold is no
        // longer the relevant signal.
        silenceLevel = 0
        defer { isSpeaking = false }
        await VoiceRegistry.engine(for: language).speak(text, language: language)
    }

    /// Cancel any in-flight playback. Broadcasts to both engines because
    /// we don't track which one spoke the most recent line — and calling
    /// `cancel()` on an idle engine is a cheap no-op. This matters when
    /// the user switches engines mid-walkthrough: the previous engine's
    /// queued utterance must still be silenced even though the *next*
    /// `speak(_:language:)` will resolve to the new engine.
    private func cancelTTS() async {
        await AppleSpeechTTS.shared.cancel()
        await PiperTTS.shared.cancel()
        isSpeaking = false
        silenceLevel = 0
    }

    // MARK: - Wake-word listen window (M7 phase B)
    //
    // Sendable-bridge helpers for the audio-thread → actor handoff.
    // Both are reference types marked `@unchecked Sendable` because
    // they're produced fresh per buffer / per window, immediately
    // handed off to a Task, and never mutated after construction —
    // exactly the contract `@unchecked Sendable` is meant to express.

    /// One-buffer transport across the audio-thread → actor boundary.
    /// `AVAudioPCMBuffer` itself isn't `Sendable`; wrapping it in a
    /// class lets the Task closure capture a Sendable handle.
    private final class WakeWordPCMFrame: @unchecked Sendable {
        let buffer: AVAudioPCMBuffer
        init(buffer: AVAudioPCMBuffer) { self.buffer = buffer }
    }

    /// Stable reference to the existential `any StreamingASR` so the
    /// audio-tap closure doesn't capture an existential whose Sendable
    /// witness the compiler can't verify.
    private final class WakeWordASRRef: @unchecked Sendable {
        let asr: any StreamingASR
        init(asr: any StreamingASR) { self.asr = asr }
    }


    /// Open a wake-word listen window. Plays a soft ping, fans out PCM
    /// from the running `AudioEngine` into a streaming ASR backend
    /// (Apple `SFSpeechRecognizer` for DE, FluidAudio's 120 M
    /// `parakeet-realtime-eou` for EN), runs the partials through
    /// `WakeWordDetector`, and either calls `advance()` /
    /// `finishEarly()` on a match or closes the window after ~5 s
    /// without one. Idempotent on cancellation: if the parent Task is
    /// cancelled mid-window the streaming ASR is torn down and the
    /// fan-out sink is cleared.
    private func runWakeWordWindow(language: OpenerLanguage) async {
        // Don't keep the window open across a state change. If the
        // user already advanced manually (or the X tap moved us to
        // .idle) we just bail.
        guard isInListeningState else {
            Diag.log("wake-word: aborted, not in listening state")
            wakeWordTask = nil
            return
        }

        // Two-gate pre-flight before we touch ASR or the UI indicator.
        //
        //   1. User toggle. WakeWordSettingsView writes this; the
        //      default is true so existing devices behave as before.
        //   2. Capability. SFSpeechRecognizer's on-device asset for
        //      `language` must be installed. Apple downloads it lazily
        //      after the user enables Dictation in Settings — until
        //      then, `start()` would throw `.onDeviceUnsupported` and
        //      the wake-listen indicator would briefly flash for
        //      nothing. Silently no-op instead.
        //
        // Lull thresholds 6/15/20 still fire normally; we're only
        // suppressing the listen-window phase of the cycle.
        guard WakeWordPreferences.isEnabled else {
            Diag.log("wake-word: skipped — user disabled in Settings")
            wakeWordTask = nil
            return
        }
        guard AppleStreamingRecognizer.supportsOnDeviceRecognition(language: language.rawValue) else {
            Diag.log("wake-word: skipped — on-device asset not installed for \(language.rawValue)")
            wakeWordTask = nil
            return
        }

        // Pick the backend by active language. The streaming Parakeet
        // model is English-only; German falls back to Apple's
        // on-device SFSpeechRecognizer (which the Info.plist's
        // NSSpeechRecognitionUsageDescription gates).
        let asr: any StreamingASR
        let phrases: [WakeWordDetector.Phrase]
        switch language {
        case .de:
            // Pre-flight permission. The system caches the answer
            // after the first prompt so this is cheap on subsequent
            // runs. If denied, skip the wake window entirely rather
            // than open a recogniser that won't deliver partials.
            do {
                try await AppleStreamingRecognizer.requestAuthorization()
            } catch {
                Diag.log("wake-word: SFSpeech permission denied/unavailable — open Settings → Voice Diary → Speech Recognition. (\(String(describing: error)))")
                wakeWordTask = nil
                return
            }
            asr = AppleStreamingRecognizer()
            phrases = WakeWordDetector.german
        case .en:
            asr = FluidAudioStreaming()
            phrases = WakeWordDetector.english
        }

        // Match arrives via the detector's callback; we surface it as
        // an AsyncStream element. `finish()` from the timeout side
        // closes the loop without emitting an action.
        let (matchStream, matchContinuation) = AsyncStream<WakeWordDetector.Action>.makeStream()
        let detector = WakeWordDetector(phrases: phrases) { action, matched in
            Diag.log("wake-word match: \(matched) → \(action.rawValue)")
            matchContinuation.yield(action)
            matchContinuation.finish()
        }
        detector.resetForNewWindow()
        // Each partial is now logged inside `AppleStreamingRecognizer`
        // (the recogniser logs the raw text + isFinal flag) and inside
        // `WakeWordDetector.consume(partial:)` (which logs the
        // tail tokens it actually checks). We just feed straight in.
        let partialHandler: @Sendable (String) -> Void = { partial in
            detector.consume(partial: partial)
        }

        // Audible + haptic confirmation that listening is open. The
        // ping is a synthesised AVAudioPlayer tone (Piper's audio
        // path) — `AudioServicesPlaySystemSound` was inaudible while
        // the `.playAndRecord` session was hot. The haptic is a
        // belt-and-suspenders cue for silent-mode hands-off use.
        await MainActor.run { WakePing.shared.playListenOpen() }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        Diag.log("wake-word window open lang=\(language.rawValue)")
        isWakeListening = true

        // Open the streaming ASR. If init fails we never set the
        // fan-out sink so the rest of the system stays untouched.
        // Common DE failure: `sfr_no_on_device:de-DE` — Apple's
        // on-device de_DE pack isn't installed (Settings → General →
        // Language & Region → ensure German is added) or hasn't
        // downloaded yet. We refuse to fall back to Apple's servers
        // because the project's no-telemetry rule.
        do {
            try await asr.start(language: language.rawValue, onPartial: partialHandler)
        } catch {
            Diag.log("wake-word: ASR start failed: \(String(describing: error))")
            isWakeListening = false
            wakeWordTask = nil
            return
        }

        // Hook the AudioEngine's third sink. Each PCM buffer arrives
        // on the audio thread; we hop into a Task to call the
        // actor-isolated `append`. Two concurrency wrinkles:
        //   • `AVAudioPCMBuffer` is not `Sendable`, so it can't be
        //     captured directly into a Task. We box it in a tiny
        //     class marked `@unchecked Sendable` — sound here because
        //     the audio thread allocates each buffer fresh, hands it
        //     off, and never touches it again.
        //   • `asr` is an `any StreamingASR` existential. Wrapping it
        //     in a captured local that's pre-bound and Sendable keeps
        //     the Task's `sending`-parameter check happy.
        let asrRef = WakeWordASRRef(asr: asr)
        await engine.setWakeWordSink { buffer in
            let frame = WakeWordPCMFrame(buffer: buffer)
            Task { await asrRef.asr.append(buffer: frame.buffer) }
        }

        // Race: first wins between match callback and a timeout.
        // Speaker mode: 8 s — enough breathing room for the ping to
        // play and the user to articulate a wake word, but bounded so
        // the recogniser doesn't sit idle forever. With the built-in
        // speaker, case=6 cancels this window explicitly anyway.
        // Headphones mode: 15 s — survives the AI's ~7 s follow-up
        // TTS plus a few seconds of post-TTS buffer, so the user can
        // interrupt the AI mid-question with "weiter" / "fertig".
        // `withTaskGroup` cleans both tasks up on early return.
        let timeoutNs: UInt64 = Self.isHeadphonesOutputActive()
            ? 15_000_000_000
            : 8_000_000_000
        let resolvedAction: WakeWordDetector.Action? = await withTaskGroup(of: WakeWordDetector.Action?.self) { group -> WakeWordDetector.Action? in
            group.addTask {
                for await action in matchStream {
                    return action
                }
                return nil
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: timeoutNs)
                matchContinuation.finish()
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        Diag.log("wake-word window closed action=\(resolvedAction?.rawValue ?? "none")")

        // Tear down regardless of outcome.
        await engine.setWakeWordSink(nil)
        await asr.stop()
        isWakeListening = false

        // Trigger the matched action on the main actor. The
        // `wakeWordTask = nil` clear has to happen *before* dispatch —
        // advance() itself nils the task ref to avoid double-cancel,
        // and our local Task is the one calling advance, which would
        // re-enter the cancellation path for itself otherwise.
        wakeWordTask = nil
        if let action = resolvedAction {
            // If the AI's follow-up was speaking when the wake word
            // matched (only possible in headphones mode where the
            // wake-window is kept alive through case=6), cut it off so
            // the user isn't talked over while we advance. The cancel
            // also tears down the in-flight TTS at the next checkpoint
            // inside speakFollowUp.
            if let task = followUpTask {
                task.cancel()
                followUpTask = nil
            }
            // Audible confirmation: hands-off users need to know the
            // word was heard before the next event's opener starts
            // talking over the silence. Fires *after* cancelling the
            // follow-up TTS so the pip doesn't overlap the AI's voice.
            await MainActor.run { WakePing.shared.playMatch() }
            // Mark the active segment so `stopSegmentCapture` knows to
            // tail-trim the audio file. The matched command word
            // (`weiter` / `next` / etc.) was just spoken into the mic
            // and is sitting at the end of the M4A; without the trim
            // it would show up verbatim in both the client-side
            // Parakeet transcript and the server-side Whisper output.
            if let segID = currentRecordingSegmentID {
                wakeMatchedSegmentIDs.insert(segID)
            }
            switch action {
            case .advance:     await advance()
            case .finishEarly: await finishEarly()
            }
        }
    }

    /// True while we're in any listening segment-capture state. Used
    /// by `runWakeWordWindow` as a pre-flight to bail if the user
    /// already advanced before the lull callback fired.
    private var isInListeningState: Bool {
        switch state {
        case .eventListening, .generalListening, .driveByListening:
            return true
        default:
            return false
        }
    }

    /// True when audio is currently routed to anything *other* than the
    /// device's own loudspeaker / earpiece — i.e. wired headphones,
    /// AirPods, Bluetooth, CarPlay, AirPlay, USB. Used to gate the
    /// "keep wake-word listening alive through the AI follow-up TTS"
    /// behaviour: with headphones there's no acoustic feedback loop
    /// between speaker and mic, so the wake-word ASR can safely run
    /// while the AI is speaking. With the built-in speaker the AI's
    /// own voice would bleed into the mic and risk false matches.
    ///
    /// Read via the **active** audio session, not the AVAudioEngine
    /// node graph — those don't always agree mid-session, but the
    /// `currentRoute` is what the OS will actually output on next
    /// playback, which is what matters for feedback risk.
    private static func isHeadphonesOutputActive() -> Bool {
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        guard !outputs.isEmpty else { return false }
        return outputs.contains { output in
            switch output.portType {
            case .builtInSpeaker, .builtInReceiver:
                return false
            default:
                // Anything else (.headphones, .bluetoothA2DP, .bluetoothHFP,
                // .bluetoothLE, .airPlay, .carAudio, .usbAudio, .lineOut, …)
                // is fine — speaker→mic feedback is unlikely.
                return true
            }
        }
    }
}
