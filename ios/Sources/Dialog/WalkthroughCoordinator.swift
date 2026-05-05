@preconcurrency import ActivityKit
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

    private let engine = AudioEngine()
    private let tts: any TTSEngine = VoiceRegistry.engine(for: "de")
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
        switch state {
        case .eventListening(let stepIdx, let eventIdx):
            await stopSegmentCapture()
            await advanceFromCalendar(stepIndex: stepIdx, eventIndex: eventIdx, language: language)
        case .eventOpener(let stepIdx, let eventIdx):
            interruptInFlight = true
            await tts.cancel()
            await advanceFromCalendar(stepIndex: stepIdx, eventIndex: eventIdx, language: language)
        case .generalListening(let stepIdx, _):
            await stopSegmentCapture()
            await runStep(at: stepIdx + 1, language: language)
        case .generalOpener(let stepIdx, _):
            interruptInFlight = true
            await tts.cancel()
            await runStep(at: stepIdx + 1, language: language)
        case .driveByListening(let stepIdx):
            await stopSegmentCapture()
            await runStep(at: stepIdx + 1, language: language)
        case .driveByOpener(let stepIdx):
            interruptInFlight = true
            await tts.cancel()
            await runStep(at: stepIdx + 1, language: language)
        default:
            return
        }
    }

    /// Skip the current step's segment without recording it.
    public func skip(language: OpenerLanguage = .de) async {
        switch state {
        case .eventListening(let stepIdx, let eventIdx):
            await dropStagedSegment(forStepIndex: stepIdx, eventIndex: eventIdx)
            await advanceFromCalendar(stepIndex: stepIdx, eventIndex: eventIdx, language: language)
        case .eventOpener(let stepIdx, let eventIdx):
            interruptInFlight = true
            await tts.cancel()
            await advanceFromCalendar(stepIndex: stepIdx, eventIndex: eventIdx, language: language)
        case .generalListening(let stepIdx, _):
            await dropStagedSegment(forStepIndex: stepIdx, eventIndex: nil)
            await runStep(at: stepIdx + 1, language: language)
        case .generalOpener(let stepIdx, _):
            interruptInFlight = true
            await tts.cancel()
            await runStep(at: stepIdx + 1, language: language)
        case .driveByListening(let stepIdx):
            await dropStagedSegment(forStepIndex: stepIdx, eventIndex: nil)
            // Don't mark seeds as surfaced if user skipped the closing.
            surfacedSeedIDs = []
            await runStep(at: stepIdx + 1, language: language)
        case .driveByOpener(let stepIdx):
            interruptInFlight = true
            await tts.cancel()
            surfacedSeedIDs = []
            await runStep(at: stepIdx + 1, language: language)
        default:
            return
        }
    }

    /// Jump straight to ingest from any in-event/in-section state.
    public func finishEarly(language: OpenerLanguage = .de) async {
        switch state {
        case .eventListening, .generalListening, .driveByListening:
            await stopSegmentCapture()
            await ingestAndUpload()
        case .briefing, .eventOpener, .generalOpener, .driveByOpener:
            interruptInFlight = true
            await tts.cancel()
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
        await tts.speak(line, language: language.rawValue)
        if interruptInFlight { return }
        do {
            try await startEventCapture(
                segmentID: segID,
                event: evts[eventIndex]
            )
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
            await tts.speak(line, language: language.rawValue)
        }
        if interruptInFlight { return }
        do {
            try await startGeneralCapture(segmentID: segID, section: section)
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
            await tts.speak(intro, language: language.rawValue)
            if interruptInFlight { return }
        }

        let closing = language == .de
            ? "Willst du noch etwas zum ganzen Tag sagen?"
            : "Anything else you want to say about the day overall?"
        recordAiPrompt(role: "closing_prompt", segmentID: segID, text: closing)
        lastSpoken = closing
        await tts.speak(closing, language: language.rawValue)
        if interruptInFlight { return }

        do {
            try await startDriveByCapture(segmentID: segID, seeds: seeds)
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
        await tts.speak(cue, language: language.rawValue)

        do {
            let result = try await EnrichmentService.shared.enrich(
                query: trimmed,
                responseLanguage: language.rawValue
            )
            recordAiPrompt(role: "enrichment_answer", segmentID: segmentID, text: result.summary)
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
        Task { await loadRecordedDates(around: selectedDate) }
    }

    // MARK: - Follow-up logic ------------------------------------------

    private func startLullDetection(
        eventIndex: Int,
        language: OpenerLanguage,
        step: Int,
        evts: [ServerCalendarEvent]
    ) {
        lullDetector.start { [weak self] threshold in
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
        }
    }

    private func handleLull(
        threshold: Int,
        eventIndex: Int,
        language: OpenerLanguage,
        evts: [ServerCalendarEvent]
    ) async {
        switch threshold {
        case 6:
            guard followUpUsed[eventIndex] != true else { return }
            followUpUsed[eventIndex] = true
            await speakFollowUp(eventIndex: eventIndex, language: language, evts: evts)
        case 15:
            statusHint = language == .de
                ? "Tippe Weiter, wenn du fertig bist."
                : "Tap Continue when you're done."
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
        await tts.speak(spoken, language: language.rawValue)
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
        await tts.speak(intro, language: lang.rawValue)
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
        await tts.speak(line, language: lang.rawValue)
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
        let elapsed = Int(Date().timeIntervalSince(started))
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
}
