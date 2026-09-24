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
//   * `voiceNote` — surfaces today's notes (each becomes a
//                 `drive_by` segment) and captures one closing
//                 free-reflection segment.
//
// The plan is built in `begin()` from `WalkthroughSettingsStore.order` plus
// the filtered calendar events plus the unsurfaced note list. Empty
// sections are skipped so users with no general sections + an empty
// calendar still flow into the note closer.

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
    public private(set) var previewError: ConnectionDiagnosis?
    public private(set) var recordedDates: Set<String> = []
    /// On-disk session dir for the currently-selected date that has
    /// segments but no `manifest.json` — i.e. a walkthrough that was
    /// aborted or interrupted before reaching the upload step. Drives
    /// the "Pick up where you left off" affordance on the start card.
    /// Nil when no such dir exists for the selected day.
    public private(set) var unfinishedSessionURL: URL?
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
    /// speaking, in seconds (one of 0 / 3 / 6 / 15 / 24). Set by
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
    /// Non-blocking notice shown at the top of the walkthrough during
    /// BRIEFING when the user has a Voxtral voice selected but the
    /// server reports `voxtral: down`. The fallback policy already
    /// handles per-utterance failure silently, so this is purely a
    /// heads-up so the voice swap doesn't surprise the user. Cleared
    /// automatically after a few seconds.
    public private(set) var voxtralPreflightWarning: String?

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
    /// Keyed by the listening segment's unique ID (e.g. `s01e02` for an
    /// event, `s02` for a general/note step). Was previously keyed by
    /// `eventIndex`, which collided once general + note sections grew
    /// their own follow-up loops. Reset in `begin()`.
    private var followUpUsed: [String: Bool] = [:]
    private var followUpRotation: Int = 0
    private var segmentByID: [String: Int] = [:]
    private var pendingFinalisation: [Task<Void, Never>] = []
    public private(set) var pendingImplicitTodos: [Todo] = []
    private var confirmedImplicit: [Todo] = []
    public var confirmedImplicitCount: Int { confirmedImplicit.count }
    private var rejectedImplicit: [TodoRejected] = []
    // Seeded from the app-language preference (`Mehr → Sprache`), then
    // updated per opener as the per-utterance LanguageDetector picks
    // German or English from the event title. The initial value matters
    // for the first read of `noteSummaryHeader` etc. *before* any opener
    // has fired.
    public private(set) var confirmationLanguage: OpenerLanguage = .current
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
    /// (advance / skip / finishCurrentSection / cancel) so the streaming ASR
    /// is torn down promptly and the audio fan-out sink is cleared.
    private var wakeWordTask: Task<Void, Never>?
    /// How a wake-matched segment's audio should be trimmed before
    /// upload, so the spoken command ("weiter" etc.) doesn't leak into
    /// the reflection transcript (client Parakeet now, server Whisper
    /// later). Applied in `stopSegmentCapture`.
    private enum WakeTrim {
        /// Keep only the first N seconds — used when we know where the
        /// user's reflection ended: the start of the silence run that
        /// preceded the command. Drops trailing silence + ping + word.
        case keepFirst(TimeInterval)
        /// Lop N seconds off the tail — fallback for when that clean cut
        /// point was lost (the user had resumed talking before the
        /// command, so the run start no longer marks the speech end).
        case dropLast(TimeInterval)
    }
    /// Pending wake-word trims keyed by segment id.
    private var wakeMatchTrim: [String: WakeTrim] = [:]
    /// Wall-clock start of the current listening segment's recording
    /// (≈ `engine.start`). With `silenceRunStartedAt` this yields the
    /// precise keep-duration for a head-keep trim. Reset per segment.
    private var segmentRecordingStartedAt: Date?
    /// Wall-clock start of the silence run that most recently opened a
    /// wake-word window (≈ window-open minus the firing threshold). Marks
    /// where the user's reflection ended; consumed on a wake match and
    /// cleared when the user resumes speaking or a new segment begins.
    private var silenceRunStartedAt: Date?
    /// Safety margin (s) added to the kept head so a late silence
    /// detection or audio-vs-wallclock skew can't clip the user's final
    /// syllable. Only keeps a sliver more silence; the command word sits
    /// seconds later and is still dropped.
    private static let wakeMatchKeepMarginSeconds: TimeInterval = 0.25
    /// Fallback fixed tail length when no clean silence-run cut point is
    /// available. Covers the command word + ASR latency + a small buffer.
    private static let wakeMatchFallbackTailSeconds: TimeInterval = 1.5
    private let answerLullDetector = LullDetector()
    private static let todoAnswerMaxSeconds: TimeInterval = 20.0
    private var interruptInFlight: Bool = false
    /// Re-entrancy guard for `advance` / `skip` / `finishCurrentSection`. Without
    /// it, two rapid Weiter taps both pattern-match the same listening
    /// state, both await `stopSegmentCapture()` (which doesn't mutate
    /// state), and both call into `runEvent`/`runGeneral`/`runVoiceNotes`
    /// with identical indices — leading to a double `speak()` of the
    /// next opener and a `File exists` collision on the next segment's
    /// `.m4a.tmp`. Set at the top of each transition method, cleared in
    /// `defer`. `@MainActor` makes the read/set atomic across Tasks.
    private var transitionInFlight: Bool = false
    /// Time-based debounce on top of `transitionInFlight`. The in-flight
    /// flag catches re-entrant taps while the previous advance is still
    /// awaiting its async work; this rejects a second tap that arrives
    /// shortly *after* the previous one completed (e.g. wake-word
    /// "weiter" finishes, then a fraction of a second later the user
    /// taps the button thinking nothing happened — without this we'd
    /// happily skip two steps).
    private var lastAdvanceAt: Date = .distantPast
    private static let advanceDebounceSeconds: TimeInterval = 0.6

    /// True while the user paused the walkthrough via wake-word "pause"
    /// or the Pause button. While paused: no recording, no TTS, no
    /// wake-word window, timer frozen. Resume restarts the current
    /// step from its opener — the prior segment's audio is preserved
    /// and a new segment is appended on resume (see
    /// `segmentResumeCounter`).
    public private(set) var isPaused: Bool = false
    /// Snapshot of the state we paused FROM, so `resume()` knows which
    /// step to re-enter. Nil whenever `isPaused == false`.
    private var pausedAtState: WalkthroughState?
    /// On-disk record of the most recent pause, persisted into the
    /// session dir so `beginPickup` can re-enter at the right step
    /// even after an app kill. Mirrors `pausedAtState` but encoded
    /// (state has associated values that can't trivially round-trip
    /// through Codable, so we project into a flat struct).
    fileprivate struct PauseMarker: Codable, Sendable {
        enum Phase: String, Codable { case briefing, opener, listening }
        enum Kind: String, Codable { case event, general, voiceNote }
        let phase: Phase
        let kind: Kind?
        let stepIndex: Int
        let eventIndex: Int?
        let sectionID: String?
        let elapsedSeconds: Int
        let activeSegmentID: String?
        let pausedAt: Date
    }
    /// AVAudioPlayer + delegate proxy retained across the "last 5s"
    /// playback inside `playLastSeconds(of:seconds:)` so the closure
    /// can return while the player keeps the delegate alive.
    private var pickupPlayerHolder: (AVAudioPlayer, PickupPlaybackDelegate)?
    /// Continuation backing `playLastSeconds`'s `await`. Stored on
    /// self so `cancel()` can stop the player and resume the
    /// continuation explicitly — `AVAudioPlayer.stop()` does *not*
    /// fire `audioPlayerDidFinishPlaying`, so without this hook a
    /// cancel mid-playback would leak the task forever (and the
    /// audio would keep playing because nothing else stopped it).
    private var pickupPlaybackContinuation: CheckedContinuation<Void, Never>?
    /// Per-base-segment-ID counter that disambiguates the second, third,
    /// … recording of the same step after pause/resume cycles. The first
    /// recording uses the base ID verbatim (e.g. `s01e02`); subsequent
    /// recordings append `c<N>` (`s01e02c2`, `s01e02c3`, …) so each
    /// pause/resume produces its own segment in the manifest.
    private var segmentResumeCounter: [String: Int] = [:]
    /// Actual segment ID of the file the AudioEngine is currently
    /// writing into (after the resume suffix has been applied). Set
    /// inside `startEventCapture` / `startGeneralCapture` /
    /// `startVoiceNoteCapture`; cleared in `stopSegmentCapture`.
    /// Was previously a computed property derived from `state`, which
    /// couldn't distinguish a first recording from a post-resume one.
    private var currentRecordingSegmentID: String?

    /// Built in `begin()` from settings.order + events + notes. Each entry
    /// drives exactly one opener+listen cycle, except `.calendar` which
    /// owns the inner event loop.
    private var plan: [PlanStep] = []
    /// Surfaced notes for the current session (mirror of the
    /// note step's payload). Used to write the index file at upload.
    private var surfacedNoteIDs: [String] = []
    /// Seed ids the user said "Für später" on during the per-note
    /// review. Excluded from `startVoiceNoteCapture`'s segment attach +
    /// from `surfacedNoteIDs`, so the next walkthrough picks them up
    /// again. Reset in `begin()`.
    private var deferredNoteIDs: Set<String> = []

    /// Seed ids the user said "verwerfen" / "discard" on during the
    /// per-note review. Excluded from this session's manifest (not
    /// folded into the diary entry) but still marked surfaced in
    /// `LocalStore` so they don't reappear on the next walkthrough —
    /// the audio file on disk is preserved. Reset in `begin()`.
    private var droppedNoteIDs: Set<String> = []

    /// Single in-walkthrough player that reads a note's original
    /// recording back before the wake-word window opens. The *same*
    /// instance backs the `NoteReviewCard`'s play disc + scrubber, so the
    /// automatic read-aloud and the user's manual play/pause/scrub are one
    /// audio stream — the scrubber tracks the auto-playback, and a single
    /// `stopNotePlayback()` tears everything down. `managesSession: false`
    /// keeps it from flipping the session to `.playback`: the walkthrough
    /// already owns `.playAndRecord` (needed for the wake-word mic), and
    /// AVAudioPlayer plays fine under it.
    let notePlayer = SegmentPlayer(managesSession: false)
    /// Resumed exactly once — by natural playback finish OR by
    /// `stopNotePlayback()`. `SegmentPlayer.stop()` does NOT fire the
    /// natural-finish hook, so without this an interrupted note (Weiter /
    /// X / voice command mid-playback) would orphan the continuation and
    /// hang `playNoteAudio`.
    private var notePlaybackContinuation: CheckedContinuation<Void, Never>?

    /// Pre-synthesised opener scripts keyed by their target segment ID.
    /// Populated by `prefetchOpener` running in the background after each
    /// listening phase begins, consumed by `speakOpenerScript` when the
    /// next opener actually fires. The hot win is Piper: synthesising a
    /// 60-character opener is ~400–800 ms of VITS work, and this cache
    /// runs that work during the user's reflection silence so the gap
    /// after "Weiter" is just AVAudioPlayer startup (~tens of ms).
    /// Apple voices inherit a no-op `prefetch` and stay on the live
    /// `speak()` path with no behaviour change.
    private var prefetchedOpeners: [String: PrefetchedScript] = [:]
    /// Background tasks for prefetches that haven't completed yet.
    /// `consumePrefetched` awaits these before falling through to the
    /// live-speak fallback, so a half-finished prefetch still delivers
    /// its head start instead of being thrown away.
    private var prefetchTasks: [String: Task<PrefetchedScript?, Never>] = [:]

    /// Composed opener *text* (spans), keyed by segment ID. The event
    /// opener is now LLM-prepared (SPEC §11): the text is generated once
    /// — usually during prefetch — and reused by `runEvent` so the
    /// recorded `ai_prompt` and `lastSpoken` exactly match the audio that
    /// actually plays. Without this cache the prefetch (LLM) and the live
    /// record path would each call the model and could diverge.
    private var openerScriptCache: [String: [SpokenSpan]] = [:]
    /// In-flight opener-text generations, keyed by segment ID. Dedupes a
    /// concurrent prefetch + live request for the same opener onto one FM
    /// call. Stored value is `nil`-safe: callers await `.value`.
    private var openerTextTasks: [String: Task<[SpokenSpan], Never>] = [:]

    /// Pre-generated note summaries, keyed by `VoiceNote.id` (the seed
    /// id string). Filled at session start by `prefetchAllNoteSummaries`;
    /// the per-note review (`noteSummary(note:language:)`) reads from
    /// here instead of firing a fresh LLM call. Whatever can't be
    /// pre-gen'd in time (LLM still in-flight, or model unavailable)
    /// falls through to the on-demand path with its existing template +
    /// first-sentence fallback.
    private var noteSummaryCache: [String: String] = [:]
    private var noteSummaryTasks: [String: Task<String, Never>] = [:]

    private init() {
        observeStateForIsland()
        // Adopt any orphan activity left over from a previous launch
        // (jetsam during walkthrough leaves the banner on the lock
        // screen but `liveActivity = nil` here). The next state-change
        // sync will overwrite content + ownership.
        Task { await LiveActivityHub.shared.rehydrate() }
    }

    /// Called from `App.scenePhase == .active` so the hub can sweep
    /// stale activities that survived the previous run. Idempotent.
    public func reclaimLiveActivityIfNeeded() async {
        await LiveActivityHub.shared.rehydrate()
    }

    // MARK: - Plan model -----------------------------------------------

    /// One scheduled section. The calendar block is a single step that
    /// expands at runtime into per-event sub-states.
    private enum PlanStep: Sendable {
        case general(GeneralSection)
        case calendar(events: [ServerCalendarEvent])
        case voiceNote(notes: [VoiceNote])
    }

    // MARK: - Public commands -----------------------------------------

    public func begin(today: Date? = nil, language: OpenerLanguage = .current) async {
        guard case .idle = state else { return }
        let targetDate = today ?? selectedDate
        state = .briefing
        // Voxtral preflight: if the user has a server-hosted voice
        // selected for either language, probe /health in the background
        // so a banner can warn them when the sidecar is unreachable
        // before the first opener fires. The walkthrough never blocks
        // on this — the fallback policy handles per-utterance failure
        // even if /health races us.
        voxtralPreflightWarning = nil
        if hasVoxtralVoiceSelected() {
            Task { await preflightVoxtral() }
        }
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
        isPaused = false
        pausedAtState = nil
        segmentResumeCounter = [:]
        currentRecordingSegmentID = nil
        lastAdvanceAt = .distantPast
        plan = []
        surfacedNoteIDs = []
        deferredNoteIDs = []
        droppedNoteIDs = []
        clearPrefetchedOpeners()
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
            // Pre-generate every LLM-dependent line for the whole
            // session up front, two-tier: the *first* opener fires
            // alone (so the briefing-then-event-0 transition feels
            // instant), then a trampoline awaits its completion and
            // fans out everything else — remaining event openers,
            // general intros, voiceNote closings, and note summaries.
            // See `prefetchAllOpeners` for the rationale (CPU sharing
            // on `PiperTTS.prefetch` is the actual delay vector).
            prefetchAllOpeners(language: language)
            // Opening intro: orient the user on the day + the rough
            // shape of what's coming. SPEC §6 calls for a "briefing"
            // before the per-event loop; this fills that slot with a
            // single short sentence rather than silence.
            let intro = composeOpeningIntro(date: targetDate, language: language)
            if !intro.isEmpty {
                lastSpoken = intro
                recordAiPrompt(role: "session_opening", segmentID: nil, text: intro)
                await speak(intro, language: language.rawValue)
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
            previewError = ConnectionDiagnosis.classify(error)
            previewEventsRaw = []
            previewEvents = []
            Log.app.warning(
                "previewDay failed: \(String(describing: error), privacy: .public)"
            )
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

    /// Scan the local staging dir for an unfinished walkthrough session
    /// whose ISO timestamp falls on `date`. "Unfinished" = the dir has
    /// at least one m4a in `segments/` but no `manifest.json` (the
    /// manifest is only written by `finishUpload()` after the user
    /// completes the walkthrough). Sets `unfinishedSessionURL` to the
    /// most-recent matching dir (or nil). Returns the URL for callers
    /// that want it inline.
    @discardableResult
    public func loadUnfinishedSession(forDate date: Date) async -> URL? {
        let cal = Calendar.current
        let targetDay = cal.startOfDay(for: date)
        let parser = ISO8601DateFormatter()
        let found: URL? = await Task.detached(priority: .utility) { () -> URL? in
            guard let root = try? LocalStore.sessionsStagingDir(),
                  let names = try? FileManager.default.contentsOfDirectory(atPath: root.path)
            else { return nil }
            var candidates: [(url: URL, ts: Date)] = []
            for name in names {
                let dir = root.appending(path: name, directoryHint: .isDirectory)
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir),
                      isDir.boolValue else { continue }
                // Skip dirs that already finished (manifest written).
                let manifestURL = dir.appending(path: LocalStore.manifestFilename)
                if FileManager.default.fileExists(atPath: manifestURL.path) { continue }
                // Need at least one real m4a to be worth resuming.
                let segmentsDir = dir.appending(path: "segments", directoryHint: .isDirectory)
                let segmentFiles = (try? FileManager.default.contentsOfDirectory(
                    at: segmentsDir,
                    includingPropertiesForKeys: nil
                ))?.filter {
                    $0.pathExtension.lowercased() == "m4a"
                        && !M4AWriter.isOrphanTempURL($0)
                } ?? []
                guard !segmentFiles.isEmpty else { continue }
                // session_id is the dir name (ISO timestamp). Match by
                // calendar day so a session started at 23:50 yesterday
                // still shows up tomorrow if the user picks "yesterday."
                let ts: Date? = parser.date(from: name.replacingOccurrences(of: "_", with: "+"))
                    ?? (try? dir.resourceValues(forKeys: [.creationDateKey]).creationDate)
                if let ts, cal.isDate(cal.startOfDay(for: ts), inSameDayAs: targetDay) {
                    candidates.append((dir, ts))
                }
            }
            return candidates.max(by: { $0.ts < $1.ts })?.url
        }.value
        unfinishedSessionURL = found
        return found
    }

    // MARK: - Pause marker persistence

    private static let pauseMarkerFilename = "pause_state.json"

    private func pauseMarkerURL(in dir: URL) -> URL {
        dir.appending(path: Self.pauseMarkerFilename)
    }

    private func writePauseMarker(activeSegmentID: String?) {
        guard let dir = sessionDir else { return }
        let marker: PauseMarker? = {
            switch state {
            case .briefing:
                return PauseMarker(
                    phase: .briefing, kind: nil,
                    stepIndex: 0, eventIndex: nil, sectionID: nil,
                    elapsedSeconds: elapsedSeconds,
                    activeSegmentID: nil, pausedAt: Date()
                )
            case .eventOpener(let s, let e):
                return PauseMarker(
                    phase: .opener, kind: .event,
                    stepIndex: s, eventIndex: e, sectionID: nil,
                    elapsedSeconds: elapsedSeconds,
                    activeSegmentID: nil, pausedAt: Date()
                )
            case .eventListening(let s, let e):
                return PauseMarker(
                    phase: .listening, kind: .event,
                    stepIndex: s, eventIndex: e, sectionID: nil,
                    elapsedSeconds: elapsedSeconds,
                    activeSegmentID: activeSegmentID, pausedAt: Date()
                )
            case .generalOpener(let s, let id):
                return PauseMarker(
                    phase: .opener, kind: .general,
                    stepIndex: s, eventIndex: nil, sectionID: id,
                    elapsedSeconds: elapsedSeconds,
                    activeSegmentID: nil, pausedAt: Date()
                )
            case .generalListening(let s, let id):
                return PauseMarker(
                    phase: .listening, kind: .general,
                    stepIndex: s, eventIndex: nil, sectionID: id,
                    elapsedSeconds: elapsedSeconds,
                    activeSegmentID: activeSegmentID, pausedAt: Date()
                )
            case .voiceNoteOpener(let s):
                return PauseMarker(
                    phase: .opener, kind: .voiceNote,
                    stepIndex: s, eventIndex: nil, sectionID: nil,
                    elapsedSeconds: elapsedSeconds,
                    activeSegmentID: nil, pausedAt: Date()
                )
            case .voiceNoteListening(let s):
                return PauseMarker(
                    phase: .listening, kind: .voiceNote,
                    stepIndex: s, eventIndex: nil, sectionID: nil,
                    elapsedSeconds: elapsedSeconds,
                    activeSegmentID: activeSegmentID, pausedAt: Date()
                )
            default:
                return nil
            }
        }()
        guard let marker else { return }
        do {
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            enc.dateEncodingStrategy = .iso8601
            let data = try enc.encode(marker)
            try data.write(to: pauseMarkerURL(in: dir),
                           options: [.atomic, .completeFileProtection])
        } catch {
            Log.app.warning("pause marker write failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func deletePauseMarker() {
        guard let dir = sessionDir else { return }
        try? FileManager.default.removeItem(at: pauseMarkerURL(in: dir))
    }

    private func readPauseMarker(from dir: URL) -> PauseMarker? {
        let url = pauseMarkerURL(in: dir)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(PauseMarker.self, from: data)
    }

    /// Fallback when no `pause_state.json` exists: derive a marker
    /// purely from the segments[] array that `loadExistingSegments`
    /// just populated. Picks the highest `(stepIndex, eventIndex,
    /// chunkIndex)` and synthesises a `listening`-phase marker so
    /// pickup runs the rich opener-replay + tail-playback flow at
    /// the actual last-recorded position. Used for cancel-then-pickup
    /// or app-kill-then-pickup, where the user never tapped Pause.
    private func inferPickupPoint() -> PauseMarker? {
        struct Score {
            let stepIndex: Int
            let eventIndex: Int  // -1 when the step isn't a calendar block
            let chunkIndex: Int
            let actualID: String
        }
        var best: Score?
        for seg in segments {
            let actualID: String
            switch seg {
            case .calendarEvent(let v):  actualID = v.segment_id
            case .freeReflection(let v): actualID = v.segment_id
            case .generalSection(let v): actualID = v.segment_id
            case .voiceNote, .emptyBlock: continue
            }
            let (baseID, chunkIdx) = parseSegmentID(actualID)
            guard let parsed = parseBaseSegmentID(baseID) else { continue }
            let candidate = Score(
                stepIndex: parsed.step,
                eventIndex: parsed.event ?? -1,
                chunkIndex: chunkIdx,
                actualID: actualID
            )
            if best == nil
                || candidate.stepIndex > best!.stepIndex
                || (candidate.stepIndex == best!.stepIndex
                    && candidate.eventIndex > best!.eventIndex)
                || (candidate.stepIndex == best!.stepIndex
                    && candidate.eventIndex == best!.eventIndex
                    && candidate.chunkIndex > best!.chunkIndex) {
                best = candidate
            }
        }
        guard let best, best.stepIndex >= 0, best.stepIndex < plan.count else {
            return nil
        }
        let kind: PauseMarker.Kind
        let eventIndex: Int?
        let sectionID: String?
        switch plan[best.stepIndex] {
        case .calendar:
            kind = .event
            eventIndex = best.eventIndex >= 0 ? best.eventIndex : nil
            sectionID = nil
            guard eventIndex != nil else { return nil }
        case .general(let section):
            kind = .general
            eventIndex = nil
            sectionID = section.id
        case .voiceNote:
            kind = .voiceNote
            eventIndex = nil
            sectionID = nil
        }
        // Sum the recorded duration of every chunk that belongs to
        // the picked base id, so the timer resumes at the total time
        // spent in this meeting/section instead of snapping to 00:00.
        // Sync probe via `AVAudioPlayer(contentsOf:)` reads the m4a
        // duration atom in microseconds without decoding samples.
        let baseID = parseSegmentID(best.actualID).baseID
        var elapsed: Double = 0
        for seg in segments {
            let id: String
            switch seg {
            case .calendarEvent(let v):  id = v.segment_id
            case .freeReflection(let v): id = v.segment_id
            case .generalSection(let v): id = v.segment_id
            case .voiceNote, .emptyBlock: continue
            }
            guard parseSegmentID(id).baseID == baseID,
                  let url = segmentURLs[mediaPath(for: id)],
                  let player = try? AVAudioPlayer(contentsOf: url)
            else { continue }
            elapsed += player.duration
        }
        return PauseMarker(
            phase: .listening,
            kind: kind,
            stepIndex: best.stepIndex,
            eventIndex: eventIndex,
            sectionID: sectionID,
            elapsedSeconds: Int(elapsed.rounded()),
            activeSegmentID: best.actualID,
            pausedAt: Date()
        )
    }

    /// Parse a *base* segment id (no `c<N>` suffix) into its plan-step
    /// and optional event indices. `s03` → step 2, no event. `s01e04`
    /// → step 0, event 3.
    private func parseBaseSegmentID(_ base: String) -> (step: Int, event: Int?)? {
        let ns = base as NSString
        guard let regex = try? NSRegularExpression(pattern: #"^s(\d+)(?:e(\d+))?$"#),
              let match = regex.firstMatch(
                  in: base,
                  options: [],
                  range: NSRange(location: 0, length: ns.length)
              ),
              let s = Int(ns.substring(with: match.range(at: 1)))
        else { return nil }
        let step = s - 1
        let eRange = match.range(at: 2)
        if eRange.location == NSNotFound { return (step, nil) }
        guard let e = Int(ns.substring(with: eRange)) else { return (step, nil) }
        return (step, e - 1)
    }

    /// Continue an unfinished session for `date`. Reuses the existing
    /// session dir (so the prior audio survives), re-runs the
    /// walkthrough plan from step 0, and bumps `segmentResumeCounter`
    /// so newly-recorded segments don't collide with the on-disk files
    /// (a re-record of `s01e02` becomes `s01e02c2`). Falls back to
    /// `begin()` when no unfinished session is detected.
    public func beginPickup(today: Date? = nil, language: OpenerLanguage = .current) async {
        guard case .idle = state else { return }
        let targetDate = today ?? selectedDate
        let existingDir = await loadUnfinishedSession(forDate: targetDate)
        guard let existingDir else {
            await begin(today: targetDate, language: language)
            return
        }
        state = .briefing
        voxtralPreflightWarning = nil
        if hasVoxtralVoiceSelected() {
            Task { await preflightVoxtral() }
        }
        // Reset coordinator state the same way begin() does — but
        // hand the existing dir + session_id to the engine instead of
        // making fresh ones.
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
        isPaused = false
        pausedAtState = nil
        segmentResumeCounter = [:]
        currentRecordingSegmentID = nil
        lastAdvanceAt = .distantPast
        plan = []
        surfacedNoteIDs = []
        deferredNoteIDs = []
        droppedNoteIDs = []
        clearPrefetchedOpeners()
        syncLiveActivity()
        Task { await ParakeetManager.shared.warmUp() }
        do { try await engine.prepareSession() }
        catch { Log.audio.warning("audio session preflight: \(String(describing: error), privacy: .public)") }
        do {
            sessionDir = existingDir
            sessionID = existingDir.lastPathComponent
            try await fetchCalendar(date: targetDate)
            plan = await buildPlan(forDate: targetDate)
            if plan.isEmpty {
                await finishUploadOrConfirmTodos()
                return
            }
            // Replay the existing segment files into the in-memory
            // structures so they survive into the eventual upload, AND
            // so the resume counter knows about them (next recording on
            // the same step picks up at `c<N>`).
            loadExistingSegments(in: existingDir, plan: plan)
            // Resolve where the user actually left off. Two sources:
            //   1. On-disk pause marker (only present if the user
            //      tapped Pause explicitly — carries exact phase +
            //      elapsedSeconds; can be stale across cancel→advance
            //      cycles).
            //   2. Disk inference — synthesised `listening` marker
            //      pointing at the highest (step, event, chunk) m4a.
            //      Always current with disk truth.
            // Combine: pick whichever is FURTHER ALONG. A position-
            // newer inference wins over a stale marker; a position-
            // equal-or-older marker wins because it carries phase +
            // elapsed details inference can't reconstruct.
            // Final fall-through to `runStep(at: 0)` only when neither
            // source produced anything (empty / mangled dir).
            let marker: PauseMarker? = {
                let saved = readPauseMarker(from: existingDir)
                let inferred = inferPickupPoint()
                switch (saved, inferred) {
                case (let s?, let i?):
                    let sScore = (s.stepIndex, s.eventIndex ?? -1)
                    let iScore = (i.stepIndex, i.eventIndex ?? -1)
                    if iScore.0 > sScore.0
                        || (iScore.0 == sScore.0 && iScore.1 > sScore.1) {
                        return i
                    }
                    return s
                case (let s?, nil):  return s
                case (nil, let i?):  return i
                case (nil, nil):     return nil
                }
            }()
            prefetchAllOpeners(language: language)
            // No day-overview intro on pickup — the user already knows
            // what day they're in, and stacking a briefing on top of
            // the pre-intro cue feels chatty. Fresh `begin()` still
            // plays the intro.
            if let marker {
                await routePickup(marker: marker, language: language)
            } else {
                await runStep(at: 0, language: language)
            }
        } catch {
            self.error = "\(error)"
            state = .failed("\(error)")
            await endLiveActivity()
        }
        // Pickup consumed the badge — clear so the start card stops
        // advertising it after a successful upload (or another tap).
        unfinishedSessionURL = nil
    }

    /// Dispatch pickup based on what the pause marker says. Opener
    /// phase replays the opener via the canonical `runEvent`/`runStep`
    /// paths; listening phase routes to `beginListeningPickup` which
    /// adds the "here is where we left off" cue + a 5-second tail
    /// playback of the prior chunk before starting a fresh recording.
    private func routePickup(marker: PauseMarker, language: OpenerLanguage) async {
        // Bump the paused step's opener to the front of the prefetch
        // queue. Without this, `prefetchAllOpeners` would synthesise
        // step 0's opener first (which we never visit on pickup),
        // delaying the actual opener by ~3 s of LLM + Piper synth.
        // beginListeningPickup also calls this for its own path; for
        // the opener phase below the runEvent/runStep tail picks up
        // the warmed cache via `speakOpenerScript`.
        if marker.phase != .briefing {
            prefetchOpener(stepIndex: marker.stepIndex,
                           eventIndex: marker.eventIndex,
                           language: language)
        }
        switch marker.phase {
        case .briefing:
            await runStep(at: 0, language: language)
        case .opener:
            switch marker.kind ?? .event {
            case .event:
                guard marker.stepIndex >= 0,
                      marker.stepIndex < plan.count,
                      case .calendar(let evts) = plan[marker.stepIndex],
                      let evtIdx = marker.eventIndex,
                      evtIdx >= 0, evtIdx < evts.count else {
                    await runStep(at: marker.stepIndex, language: language)
                    return
                }
                await runEvent(stepIndex: marker.stepIndex,
                               eventIndex: evtIdx,
                               events: evts,
                               language: language)
            case .general, .voiceNote:
                await runStep(at: marker.stepIndex, language: language)
            }
        case .listening:
            await beginListeningPickup(marker: marker, language: language)
        }
    }

    /// Rich pickup flow for a listening-phase resume. Sequence:
    ///   1. Pre-intro TTS — informs the user a previous session is
    ///      being picked up ("Wir machen mit deiner letzten Sitzung
    ///      weiter.").
    ///   2. Re-speak the actual step opener (event opener / general
    ///      intro / closing prompt) so the user is re-oriented to the
    ///      specific meeting / section.
    ///   3. Bridging TTS ("Hier sind die letzten Sekunden deiner
    ///      Aufnahme:") + last 5s of the prior chunk. Skipped when
    ///      the chunk's audio file is too short / missing.
    ///   4. `startXCapture` for a fresh c<N> chunk + transition to
    ///      listening. Counter logic preserves the previous chunk.
    ///
    /// Lock-mode safe: every TTS call runs through the same audio
    /// session the rest of the walkthrough uses (`.playAndRecord`,
    /// pre-armed by `engine.prepareSession()`), and `AVAudioPlayer`'s
    /// playback survives screen lock.
    private func beginListeningPickup(
        marker: PauseMarker,
        language: OpenerLanguage
    ) async {
        // Resolve the URL of the chunk we'll preview. Falls back to
        // skipping the tail playback if the file is gone (manual
        // delete, sync mishap).
        let tailURL: URL? = {
            guard let segID = marker.activeSegmentID else { return nil }
            return segmentURLs[mediaPath(for: segID)]
        }()
        // Only play a tail when there's actually something worth
        // playing — files shorter than ~5 s are too short to be a
        // useful re-orient cue, so we just skip the bridge entirely
        // and rely on the opener replay.
        let tailIsWorthPlaying: Bool = {
            guard let tailURL else { return false }
            let attrs = try? FileManager.default.attributesOfItem(atPath: tailURL.path)
            // Rough size gate: AAC-LC at 64 kbps ≈ 8 kB/s, so 40 kB ≈
            // 5 s. Cheaper than probing the m4a's duration header.
            let bytes = (attrs?[.size] as? Int) ?? 0
            return bytes > 40_000
        }()
        // Restore the timer so the visible counter resumes where it
        // left off — the user "lost" the paused seconds during the
        // intro + 5s preview, but past that the timer reads correctly.
        elapsedSeconds = marker.elapsedSeconds

        // Set the matching opener state so the EventCard / general
        // header / closing prompt renders while we speak.
        switch marker.kind ?? .event {
        case .event:
            guard let evtIdx = marker.eventIndex else { return }
            state = .eventOpener(stepIndex: marker.stepIndex, eventIndex: evtIdx)
        case .general:
            guard let sid = marker.sectionID else { return }
            state = .generalOpener(stepIndex: marker.stepIndex, sectionID: sid)
        case .voiceNote:
            state = .voiceNoteOpener(stepIndex: marker.stepIndex)
        }

        // Pre-warm the paused step's opener BEFORE we speak the
        // pre-intro. `prefetchAllOpeners` in `beginPickup` queues step
        // 0 first by default — wasteful for pickup since we'll never
        // visit step 0, and it steals CPU from the Piper synth pass we
        // actually need. Bumping the priority here hides the LLM +
        // synth cost behind the pre-intro's ~2 s playback.
        prefetchOpener(stepIndex: marker.stepIndex,
                       eventIndex: marker.eventIndex,
                       language: language)

        // 1. Pre-intro — frames the pickup.
        let preIntro = language == .de
            ? "Wir machen mit deiner letzten Sitzung weiter."
            : "Picking up where you left off."
        recordAiPrompt(role: "pickup_pre_intro",
                       segmentID: marker.activeSegmentID,
                       text: preIntro)
        lastSpoken = preIntro
        await speak(preIntro, language: language.rawValue)
        if interruptInFlight { return }

        // 2. Re-speak the actual opener for the paused step. This is
        //    the same content runEvent / runGeneral / runVoiceNotes
        //    would speak on a normal entry; centralised here so the
        //    pickup path doesn't duplicate composition logic.
        await speakPickupOpener(marker: marker, language: language)
        if interruptInFlight { return }

        // 3. Bridge + tail. Only when the prior chunk is long enough
        //    to be worth re-hearing.
        if tailIsWorthPlaying, let url = tailURL {
            let bridge = language == .de
                ? "Hier sind die letzten Sekunden deiner Aufnahme:"
                : "Here are the last few seconds of your recording:"
            recordAiPrompt(role: "pickup_tail_intro",
                           segmentID: marker.activeSegmentID,
                           text: bridge)
            lastSpoken = bridge
            await speak(bridge, language: language.rawValue)
            if interruptInFlight { return }
            await playLastSeconds(of: url, seconds: 5.0)
            if interruptInFlight { return }
        }

        // Hand off to the canonical listening tail of each runX
        // path. Counter logic in startXCapture allocates the next
        // c<N> suffix so the prior chunk stays untouched.
        switch marker.kind ?? .event {
        case .event:
            guard let evtIdx = marker.eventIndex,
                  marker.stepIndex >= 0, marker.stepIndex < plan.count,
                  case .calendar(let evts) = plan[marker.stepIndex],
                  evtIdx >= 0, evtIdx < evts.count else { return }
            do {
                let segID = makeEventSegmentID(stepIndex: marker.stepIndex, eventIndex: evtIdx)
                try await startEventCapture(segmentID: segID, event: evts[evtIdx])
                state = .eventListening(stepIndex: marker.stepIndex, eventIndex: evtIdx)
                startTimer()
                startLullDetection(
                    context: .event(eventIndex: evtIdx, evts: evts),
                    step: marker.stepIndex,
                    language: language
                )
                prefetchNextOpener(
                    afterStep: marker.stepIndex,
                    eventIndex: evtIdx,
                    language: language
                )
            } catch {
                self.error = "\(error)"
                state = .failed("\(error)")
            }
        case .general:
            guard marker.stepIndex >= 0, marker.stepIndex < plan.count,
                  case .general(let section) = plan[marker.stepIndex] else { return }
            do {
                let segID = "s\(zeroPad(marker.stepIndex + 1))"
                try await startGeneralCapture(segmentID: segID, section: section)
                state = .generalListening(stepIndex: marker.stepIndex, sectionID: section.id)
                startTimer()
                startLullDetection(
                    context: .general(section),
                    step: marker.stepIndex,
                    language: language
                )
                prefetchNextOpener(
                    afterStep: marker.stepIndex,
                    eventIndex: nil,
                    language: language
                )
            } catch {
                self.error = "\(error)"
                state = .failed("\(error)")
            }
        case .voiceNote:
            guard marker.stepIndex >= 0, marker.stepIndex < plan.count,
                  case .voiceNote(let notes) = plan[marker.stepIndex] else { return }
            confirmationLanguage = language
            do {
                let segID = "s\(zeroPad(marker.stepIndex + 1))"
                try await startVoiceNoteCapture(segmentID: segID, notes: notes)
                state = .voiceNoteListening(stepIndex: marker.stepIndex)
                startTimer()
                startLullDetection(
                    context: .voiceNote,
                    step: marker.stepIndex,
                    language: language
                )
            } catch {
                self.error = "\(error)"
                await ingestAndUpload()
            }
        }
    }

    /// Speak the opener line(s) that `runEvent` / `runGeneral` /
    /// `runVoiceNoteClosing` would speak for the paused step. Pulled
    /// out so the pickup path can splice the opener between its
    /// pre-intro + tail-preview cues without duplicating each runX's
    /// composition logic.
    private func speakPickupOpener(
        marker: PauseMarker,
        language: OpenerLanguage
    ) async {
        switch marker.kind ?? .event {
        case .event:
            guard let evtIdx = marker.eventIndex,
                  marker.stepIndex >= 0, marker.stepIndex < plan.count,
                  case .calendar(let evts) = plan[marker.stepIndex],
                  evtIdx >= 0, evtIdx < evts.count else { return }
            let segID = makeEventSegmentID(
                stepIndex: marker.stepIndex,
                eventIndex: evtIdx
            )
            let spans = await eventOpenerSpans(
                event: evts[evtIdx],
                index: evtIdx,
                total: evts.count,
                segmentID: segID,
                language: language
            )
            let line = spans.flatten()
            lastSpoken = line
            recordAiPrompt(role: "opener", segmentID: segID, text: line)
            await speakOpenerScript(segmentID: segID, fallbackSpans: spans)
        case .general:
            guard marker.stepIndex >= 0, marker.stepIndex < plan.count,
                  case .general(let section) = plan[marker.stepIndex] else { return }
            let segID = "s\(zeroPad(marker.stepIndex + 1))"
            let line = section.introText
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { return }
            lastSpoken = line
            recordAiPrompt(role: "general_opener", segmentID: segID, text: line)
            await speakOpenerScript(
                segmentID: segID,
                fallbackSpans: [SpokenSpan(text: line, language: language.rawValue)]
            )
        case .voiceNote:
            guard marker.stepIndex >= 0, marker.stepIndex < plan.count,
                  case .voiceNote = plan[marker.stepIndex] else { return }
            let segID = "s\(zeroPad(marker.stepIndex + 1))"
            let closing = OpenerTemplates.closingPrompt(language: language)
            lastSpoken = closing
            recordAiPrompt(role: "closing_prompt", segmentID: segID, text: closing)
            await speakOpenerScript(
                segmentID: segID,
                fallbackSpans: [SpokenSpan(text: closing, language: language.rawValue)]
            )
        }
    }

    /// Play just the last `seconds` of an m4a under the active
    /// `.playAndRecord` session. Awaits natural finish (or decode
    /// error) via a delegate-continuation. Files shorter than
    /// `seconds` play in full from t=0. Interruptible: `cancel()`
    /// stops the player and resumes the continuation so the caller's
    /// await returns immediately and the chain bails on
    /// `interruptInFlight`.
    private func playLastSeconds(of url: URL, seconds: TimeInterval) async {
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.prepareToPlay()
            let start = max(0, player.duration - seconds)
            player.currentTime = start
            isSpeaking = true
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let proxy = PickupPlaybackDelegate { [weak self] in
                    Task { @MainActor [weak self] in
                        self?.resumePickupContinuation()
                    }
                }
                player.delegate = proxy
                // Stash everything on self so the closure can return,
                // the audio thread keeps a strong ref via the player,
                // and `cancel()` has a hook to stop + resume.
                self.pickupPlayerHolder = (player, proxy)
                self.pickupPlaybackContinuation = continuation
                player.play()
            }
            isSpeaking = false
            pickupPlayerHolder = nil
            pickupPlaybackContinuation = nil
        } catch {
            Log.audio.warning(
                "pickup tail playback failed: \(String(describing: error), privacy: .public)"
            )
            isSpeaking = false
            pickupPlayerHolder = nil
            pickupPlaybackContinuation = nil
        }
    }

    /// Idempotent resume of the pickup-playback continuation. Called
    /// from the natural-finish delegate AND from `cancel()` (where
    /// `AVAudioPlayer.stop()` won't fire the delegate). Whichever
    /// fires first wins; the other is a no-op.
    private func resumePickupContinuation() {
        guard let c = pickupPlaybackContinuation else { return }
        pickupPlaybackContinuation = nil
        c.resume()
    }

    /// Parse a segment filename stem (`s01`, `s01e02`, `s01e02c3`)
    /// into its base id + resume index. Used by `loadExistingSegments`
    /// to seed `segmentResumeCounter` from on-disk files.
    private static let segmentIDPattern: NSRegularExpression? = {
        try? NSRegularExpression(pattern: #"^(s\d+(?:e\d+)?)(?:c(\d+))?$"#)
    }()

    private func parseSegmentID(_ stem: String) -> (baseID: String, resumeIdx: Int) {
        guard let regex = Self.segmentIDPattern,
              let match = regex.firstMatch(
                  in: stem,
                  options: [],
                  range: NSRange(stem.startIndex..., in: stem)
              )
        else { return (stem, 1) }
        let ns = stem as NSString
        let base = ns.substring(with: match.range(at: 1))
        let chunkRange = match.range(at: 2)
        let chunk: Int = {
            guard chunkRange.location != NSNotFound else { return 1 }
            return Int(ns.substring(with: chunkRange)) ?? 1
        }()
        return (base, chunk)
    }

    /// Hydrate `segmentURLs`, `segments`, `segmentByID`, and
    /// `segmentResumeCounter` from m4a files left behind in an
    /// unfinished session dir. Each old file is also queued for
    /// (re-)finalisation so its transcript and todo extraction run
    /// before the eventual upload.
    private func loadExistingSegments(in dir: URL, plan: [PlanStep]) {
        let segmentsDir = dir.appending(path: "segments", directoryHint: .isDirectory)
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: segmentsDir,
            includingPropertiesForKeys: nil
        ) else { return }
        let m4a = urls
            .filter {
                $0.pathExtension.lowercased() == "m4a"
                    && !M4AWriter.isOrphanTempURL($0)
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for url in m4a {
            let stem = url.deletingPathExtension().lastPathComponent
            let (baseID, resumeIdx) = parseSegmentID(stem)
            let path = "segments/\(url.lastPathComponent)"
            // Only register the file if we can also build a Segment
            // record for it — files that can't be mapped (e.g. plan
            // shape changed) would otherwise upload as orphans the
            // manifest doesn't reference.
            guard let seg = makeReconstructedSegment(
                baseID: baseID,
                actualID: stem,
                audioPath: path,
                plan: plan
            ) else {
                Log.app.warning(
                    "pickup: dropping orphan audio file \(url.lastPathComponent, privacy: .public) — no matching plan step"
                )
                continue
            }
            // Bump the counter to at least this index so a future call
            // to `nextActualSegmentID(forBase:)` skips past the on-disk
            // file rather than overwriting it.
            let prior = segmentResumeCounter[baseID, default: 0]
            segmentResumeCounter[baseID] = max(prior, resumeIdx)
            segmentURLs[path] = url
            segments.append(seg)
            segmentByID[stem] = segments.count - 1
            // Re-transcribe — finalise() handles the rest (todos +
            // setting transcript on the segment record).
            let task = Task { [weak self] in
                guard let self else { return }
                await self.finalise(segmentID: stem, url: url)
            }
            pendingFinalisation.append(task)
        }
    }

    /// Build a Segment record for a reloaded m4a, looking up the
    /// matching plan step (and event index for calendar segments).
    /// Returns nil when the base id falls outside the current plan
    /// (e.g. plan length changed between sessions).
    private func makeReconstructedSegment(
        baseID: String,
        actualID: String,
        audioPath: String,
        plan: [PlanStep]
    ) -> Segment? {
        // base id formats: "sNN" or "sNNeMM"
        let ns = baseID as NSString
        guard let regex = try? NSRegularExpression(pattern: #"^s(\d+)(?:e(\d+))?$"#),
              let match = regex.firstMatch(
                  in: baseID,
                  options: [],
                  range: NSRange(location: 0, length: ns.length)
              ),
              let stepIdx = Int(ns.substring(with: match.range(at: 1))).map({ $0 - 1 })
        else { return nil }
        guard stepIdx >= 0, stepIdx < plan.count else { return nil }
        let eventIdxRange = match.range(at: 2)
        let eventIdx: Int? = eventIdxRange.location == NSNotFound
            ? nil
            : Int(ns.substring(with: eventIdxRange)).map { $0 - 1 }

        switch plan[stepIdx] {
        case .calendar(let evts):
            guard let evtIdx = eventIdx, evtIdx >= 0, evtIdx < evts.count else { return nil }
            let event = evts[evtIdx]
            let calRef = CalendarRef(
                graph_event_id: event.graph_event_id,
                title: event.subject,
                start: event.start,
                end: event.end,
                attendees: event.attendees.map { $0.email.isEmpty ? $0.name : $0.email },
                rsvp_status: event.rsvp_status
            )
            return .calendarEvent(CalendarEventSegment(
                segment_id: actualID,
                calendar_ref: calRef,
                audio_file: audioPath
            ))
        case .general(let section):
            return .generalSection(GeneralSectionSegment(
                segment_id: actualID,
                section_id: section.id,
                title: section.title,
                prompt_text: section.introText,
                audio_file: audioPath
            ))
        case .voiceNote:
            return .freeReflection(FreeReflectionSegment(
                segment_id: actualID,
                audio_file: audioPath,
                captured_at: ISO8601DateFormatter().string(from: Date())
            ))
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

    // MARK: - Transition preamble helpers

    /// Cancel the wake-word window and any in-flight follow-up task.
    /// Called at the top of every public transition entry point so each
    /// one starts with a clean slate regardless of what was mid-flight.
    private func cancelTransientTasks() {
        wakeWordTask?.cancel(); wakeWordTask = nil
        isWakeListening = false
        followUpTask?.cancel(); followUpTask = nil
    }

    /// Gate a transition on `transitionInFlight`, set the flag, install
    /// a `defer` to clear it, cancel transient tasks, then execute
    /// `body`. Returns immediately (without calling `body`) when another
    /// transition is already in flight.
    ///
    /// Usage pattern:
    ///
    ///     await withTransition {
    ///         switch state { … }
    ///     }
    ///
    /// If the call site needs extra teardown before the `switch` (e.g.
    /// `stopNotePlayback()`), do it inside `body` rather than after the
    /// `await withTransition {` line — the flag is already held at that
    /// point.
    @discardableResult
    private func withTransition(_ body: () async -> Void) async -> Bool {
        guard !transitionInFlight else { return false }
        transitionInFlight = true
        defer { transitionInFlight = false }
        cancelTransientTasks()
        await body()
        return true
    }

    /// Advance to the next plan step (or the next event inside the
    /// calendar block).
    public func advance(language: OpenerLanguage = .current) async {
        // Don't let a paused walkthrough be advanced — wait for the
        // user to resume first. Otherwise a tap that arrived while the
        // pause was being acknowledged would silently jump to the next
        // step.
        if isPaused { return }
        // Time-based debounce: the in-flight flag below catches a
        // re-entrant tap while the previous advance is still mid-await,
        // but doesn't catch a SECOND tap that arrives shortly *after*
        // the previous advance returned (e.g. wake-word "weiter"
        // resolves, then a fraction of a second later the user taps
        // the button thinking nothing happened — without this we'd
        // happily skip two steps). 600 ms is comfortably above human
        // double-tap intent and well below a deliberate single tap.
        let now = Date()
        if now.timeIntervalSince(lastAdvanceAt) < Self.advanceDebounceSeconds {
            Diag.log("advance: debounced (last=\(String(format: "%.2f", now.timeIntervalSince(lastAdvanceAt)))s ago)")
            return
        }
        lastAdvanceAt = now
        // Coalesce rapid Weiter taps. The runEvent/runGeneral/runVoiceNotes
        // chains are not idempotent — re-entering with the same captured
        // step/event indices double-starts the next segment's audio file
        // and double-queues the opener TTS. Drop the second tap here.
        // Cleared in defer so a real follow-up tap after this one
        // completes goes through.
        // Drop the wake-word window + its in-flight follow-up before
        // transitioning (see `cancelTransientTasks` comment). The
        // `withTransition` helper owns the in-flight guard + defer.
        await withTransition {
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
        case .voiceNoteListening(let stepIdx):
            await stopSegmentCapture()
            await runStep(at: stepIdx + 1, language: language)
        case .voiceNoteOpener(let stepIdx):
            interruptInFlight = true
            await cancelTTS()
            await runStep(at: stepIdx + 1, language: language)
        case .noteReview(let stepIdx, let noteIdx):
            // Advance to the next note, or to the closing-question
            // phase if this was the last one. Cancel any TTS still in
            // flight from the intro line + any in-flight note audio
            // playback so we don't overlap with the next note's audio
            // or the closing prompt.
            interruptInFlight = true
            await cancelTTS()
            stopNotePlayback()
            guard stepIdx >= 0, stepIdx < plan.count,
                  case .voiceNote(let notes) = plan[stepIdx] else {
                await runStep(at: stepIdx + 1, language: language)
                return
            }
            let next = noteIdx + 1
            if next < notes.count {
                await runNoteReview(stepIndex: stepIdx, noteIndex: next,
                                    notes: notes, language: language)
            } else {
                await runVoiceNoteClosing(stepIndex: stepIdx, notes: notes, language: language)
            }
        case .confirmingTodos:
            // Tapping Weiter on a todo candidate skips it (matches the
            // 20 s auto-reject and the .unknown answer outcome). The
            // user can always undo the rejection later in the diary
            // entry; what they're never allowed to do here is strand
            // the walkthrough on a candidate.
            interruptInFlight = true
            await cancelTTS()
            await rejectCurrentTodo()
        case .briefing:
            // The intro briefing is just a single TTS line before the
            // first step; tapping Weiter here means "skip the intro,
            // jump into the first event." Without this case the button
            // would visually press but advance() would fall through to
            // the default and return — exactly the "feedback fires but
            // nothing happens" symptom the user reported.
            interruptInFlight = true
            await cancelTTS()
            await runStep(at: 0, language: language)
        default:
            break
        }
        } // end withTransition
    }

    /// Skip the current step's segment without recording it.
    public func skip(language: OpenerLanguage = .current) async {
        await withTransition {
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
        case .voiceNoteListening(let stepIdx):
            await dropStagedSegment(forStepIndex: stepIdx, eventIndex: nil)
            // Don't mark notes as surfaced if user skipped the closing.
            surfacedNoteIDs = []
            await runStep(at: stepIdx + 1, language: language)
        case .voiceNoteOpener(let stepIdx):
            interruptInFlight = true
            await cancelTTS()
            surfacedNoteIDs = []
            await runStep(at: stepIdx + 1, language: language)
        case .noteReview(let stepIdx, _):
            // Skip from the per-note review = bypass the rest of the
            // notes AND the closing reflection. Don't mark notes as
            // surfaced — they should remain visible the next time the
            // user runs a walkthrough.
            interruptInFlight = true
            await cancelTTS()
            surfacedNoteIDs = []
            await runStep(at: stepIdx + 1, language: language)
        default:
            break
        }
        } // end withTransition
    }

    /// End the *current* section and advance to the next plan step.
    /// Backs the wake-word "fertig" / "Abschluss" / "done" / "finish"
    /// triggers: inside meeting 2 of 5 it moves you to meeting 3, not
    /// to ingest. The X button is still the full-abort path
    /// (`cancel()`); there is no other UI entry point. For note /
    /// note-review / closing — which is already the last section —
    /// "next step" naturally falls through to `ingestAndUpload`.
    public func finishCurrentSection(language: OpenerLanguage = .current) async {
        await withTransition {
        switch state {
        case .eventListening(let stepIdx, _):
            // Stop capturing the in-flight event so its audio is
            // preserved, then jump past the rest of the calendar block.
            await stopSegmentCapture()
            await runStep(at: stepIdx + 1, language: language)
        case .generalListening(let stepIdx, _):
            await stopSegmentCapture()
            await runStep(at: stepIdx + 1, language: language)
        case .voiceNoteListening(let stepIdx):
            // Note is the last section; advancing past it ends the
            // walkthrough by falling off the plan into ingestAndUpload.
            await stopSegmentCapture()
            await runStep(at: stepIdx + 1, language: language)
        case .eventOpener(let stepIdx, _):
            interruptInFlight = true
            await cancelTTS()
            await runStep(at: stepIdx + 1, language: language)
        case .generalOpener(let stepIdx, _):
            interruptInFlight = true
            await cancelTTS()
            await runStep(at: stepIdx + 1, language: language)
        case .voiceNoteOpener(let stepIdx):
            interruptInFlight = true
            await cancelTTS()
            surfacedNoteIDs = []
            await runStep(at: stepIdx + 1, language: language)
        case .noteReview(let stepIdx, _):
            interruptInFlight = true
            await cancelTTS()
            surfacedNoteIDs = []
            await runStep(at: stepIdx + 1, language: language)
        case .briefing:
            // No section is active yet; "fertig" during briefing is
            // ambiguous, so just play it safe and end the walkthrough.
            interruptInFlight = true
            await cancelTTS()
            await ingestAndUpload()
        default:
            break
        }
        } // end withTransition
    }

    public func cancel() async {
        // Set the abort flag FIRST, before any await. The runEvent /
        // runGeneral / runVoiceNotes chains all check `interruptInFlight`
        // after each `await speak(...)` — without setting it here, a
        // suspended chain would resume after `cancelTTS()` returns and
        // happily call `startEventCapture()` + `state = .eventListening`
        // again, which is what was causing the walkthrough screen to
        // re-appear and audio to keep playing after the X tap. The
        // existing advance() / skip() / finishCurrentSection() paths already use
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
        stopNotePlayback()
        // Stop the pickup last-5s playback if it's mid-flight, and
        // resume its continuation so the awaiting beginListeningPickup
        // task drops out instead of hanging until natural finish.
        // `AVAudioPlayer.stop()` is a no-op when idle, so this is safe
        // outside the pickup window too.
        pickupPlayerHolder?.0.stop()
        pickupPlayerHolder = nil
        resumePickupContinuation()
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
        // Drop any prefetched openers we'd queued for the now-cancelled
        // session. Their cached WAVs go to /tmp; the discard call here
        // makes sure we don't leak the files until the system reaper
        // kicks in.
        clearPrefetchedOpeners()
        // Keep the pause marker (if any) on disk. Cancel preserves the
        // session_dir + its m4a files by design — "recordings until
        // this point shall be stored" — and the pickup intent should
        // survive alongside them. `finishUpload()` is the only path
        // that strips the marker.
        state = .idle
        isPaused = false
        pausedAtState = nil
        await endLiveActivity()
    }

    // MARK: - Pause / Resume -------------------------------------------

    /// Pause the walkthrough. Wake-word "pause" (in listening states)
    /// and the Pause button (any pausable state) both route here.
    /// Finalises any active recording so the audio captured up to this
    /// point is preserved as its own segment in the manifest; cancels
    /// TTS, wake-word, follow-ups, lull detection, and stops the timer.
    /// Resume is button-only — by design — so the user can't acci-
    /// dentally un-pause with a "weiter" mid-thought.
    public func pause() async {
        guard !isPaused else { return }
        guard state.isPausable else { return }
        Diag.log("walkthrough pause: state=\(state.label)")

        pausedAtState = state
        isPaused = true
        interruptInFlight = true

        // Capture the actual segment ID before `stopSegmentCapture`
        // clears it — we want the marker to remember which `c<N>` file
        // was being written so pickup can play its tail.
        let activeSegmentForMarker = currentRecordingSegmentID

        wakeWordTask?.cancel(); wakeWordTask = nil
        isWakeListening = false
        followUpTask?.cancel(); followUpTask = nil
        stopNotePlayback()
        timer?.invalidate(); timer = nil
        // Do NOT reset elapsedSeconds — leave it frozen at the moment
        // the user paused so the timer visibly stops at "02:13" instead
        // of snapping to "00:00". Resume's startTimer continues from
        // there.
        silenceLevel = 0
        lullDetector.stop()
        await cancelTodoAnswerCapture()
        await cancelTTS()

        // Persist the pause point to disk before any further work that
        // could fail or be killed — survives an app kill so the next
        // launch's `beginPickup` knows exactly where to resume.
        writePauseMarker(activeSegmentID: activeSegmentForMarker)

        // If a recording is in flight, finalise it as its own segment.
        // `stopSegmentCapture` enqueues the finalisation task that runs
        // Parakeet on the captured audio and writes the transcript onto
        // the manifest entry. Subsequent resume() will append a NEW
        // segment with `c<N>` suffix via `nextActualSegmentID`.
        if currentRecordingSegmentID != nil {
            await stopSegmentCapture(resetElapsed: false)
        }
        // Two presentations for paused state, gated by user preference:
        //   off (default) — end the Live Activity so the lock screen +
        //                   Dynamic Island free up while the user is
        //                   stepped away from the walkthrough.
        //   on            — push a paused snapshot so the banner stays
        //                   on-screen as a one-tap shortcut back into
        //                   the walkthrough card.
        // The `observeStateForIsland` watcher fires on `state` changes
        // only, not on `isPaused`, so we push (or end) explicitly here.
        if LockScreenPreferences.showWhenPaused {
            syncLiveActivity()
        } else {
            Task { await endLiveActivity() }
        }
    }

    /// Resume from a paused state. Re-enters the same step's opener
    /// via the canonical `runEvent` / `runStep` paths — the opener
    /// re-speaks as a deliberate reorientation cue. The timer continues
    /// from the paused value (frozen in `pause()`) so the user sees
    /// "02:13 → opener replays → 02:14, 02:15…" rather than a hard
    /// reset to 00:00. On the listening phase that follows,
    /// `startXCapture` allocates a fresh `c<N>`-suffixed segment so
    /// the prior recording stays intact.
    public func resume(language: OpenerLanguage = .current) async {
        guard isPaused else { return }
        guard let paused = pausedAtState else {
            isPaused = false
            deletePauseMarker()
            return
        }
        Diag.log("walkthrough resume: state=\(paused.label)")
        isPaused = false
        pausedAtState = nil
        interruptInFlight = false
        deletePauseMarker()

        // Push the un-paused state up to the Live Activity so the widget
        // un-freezes the timer (re-based by the hub from `elapsedSeconds`,
        // so it picks up at "02:13" instead of snapping to "00:00").
        syncLiveActivity()

        switch paused {
        case .briefing:
            await runStep(at: 0, language: language)
        case .eventOpener(let stepIdx, let eventIdx),
             .eventListening(let stepIdx, let eventIdx):
            guard stepIdx >= 0, stepIdx < plan.count,
                  case .calendar(let evts) = plan[stepIdx] else {
                await runStep(at: stepIdx, language: language)
                return
            }
            await runEvent(stepIndex: stepIdx, eventIndex: eventIdx,
                           events: evts, language: language)
        case .generalOpener(let stepIdx, _),
             .generalListening(let stepIdx, _),
             .voiceNoteOpener(let stepIdx),
             .voiceNoteListening(let stepIdx):
            await runStep(at: stepIdx, language: language)
        default:
            break
        }
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
            case .voiceNote:
                let notes = await loadUnsurfacedSeeds(forDate: target)
                steps.append(.voiceNote(notes: notes))
            }
        }
        return steps
    }

    /// Seeds captured on or before the session's target day that haven't
    /// been surfaced in a prior session yet.
    private func loadUnsurfacedSeeds(forDate target: Date) async -> [VoiceNote] {
        let surfaced = LocalStore.surfacedNoteIDs()
        let cutoff = Calendar.current.date(
            byAdding: .day, value: 1,
            to: Calendar.current.startOfDay(for: target)
        ) ?? target
        return SessionHistoryStore.unsurfacedNotes(before: cutoff, surfaced: surfaced)
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
        case .voiceNote(let notes):
            await runVoiceNotes(stepIndex: index, notes: notes, language: language)
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
        let segID = makeEventSegmentID(stepIndex: stepIndex, eventIndex: eventIndex)
        // LLM-prepared opener (SPEC §11), with the deterministic template
        // as fallback. Usually a cache hit from the prefetch that ran
        // during the previous reflection; only a missed prefetch awaits
        // the model here.
        let spans = await eventOpenerSpans(
            event: evts[eventIndex],
            index: eventIndex,
            total: evts.count,
            segmentID: segID,
            language: language
        )
        // Composing can await the model; if the user tapped Weiter during
        // that hop a newer runEvent already owns the flow — bail before we
        // record a prompt or speak over it.
        guard case .eventOpener(let liveStep0, let liveEvt0) = state,
              liveStep0 == stepIndex, liveEvt0 == eventIndex else { return }
        if interruptInFlight { return }
        let line = spans.flatten()
        lastSpoken = line
        recordAiPrompt(role: "opener", segmentID: segID, text: line)
        await speakOpenerScript(segmentID: segID, fallbackSpans: spans)
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
            startLullDetection(
                context: .event(eventIndex: eventIndex, evts: evts),
                step: stepIndex,
                language: language
            )
            // Prefetch the next opener while the user reflects. Either
            // the next event in this calendar block, or — if this was
            // the last event — the first opener of the next plan step
            // (general / note / next calendar block).
            prefetchNextOpener(
                afterStep: stepIndex,
                eventIndex: eventIndex,
                language: language
            )
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
            await speakOpenerScript(
                segmentID: segID,
                fallbackSpans: [SpokenSpan(text: line, language: language.rawValue)]
            )
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
            startLullDetection(
                context: .general(section),
                step: stepIndex,
                language: language
            )
            prefetchNextOpener(
                afterStep: stepIndex,
                eventIndex: nil,
                language: language
            )
        } catch {
            self.error = "\(error)"
            state = .failed("\(error)")
        }
    }

    // MARK: - Note section step ------------------------------------

    /// Note step entry. If the user has unsurfaced notes for the
    /// diary day, walks through them one-at-a-time as breadcrumbed
    /// `noteReview` cards (silent visual, no per-note TTS) before
    /// handing off to the closing-question phase. With zero notes the
    /// flow drops straight into the closing question.
    private func runVoiceNotes(
        stepIndex: Int,
        notes: [VoiceNote],
        language: OpenerLanguage
    ) async {
        interruptInFlight = false
        statusHint = ""
        confirmationLanguage = language

        if notes.isEmpty {
            await runVoiceNoteClosing(stepIndex: stepIndex, notes: notes, language: language)
        } else {
            await runNoteReview(stepIndex: stepIndex, noteIndex: 0,
                                notes: notes, language: language)
        }
    }

    /// One step of the per-note breadcrumbed review. Voice-first flow:
    ///   1. Speak the "Du hast heute X Notizen aufgenommen…" intro
    ///      (first note only).
    ///   2. Play the note's original audio recording (`AVAudioPlayer`
    ///      under the existing `.playAndRecord` session).
    ///   3. Open a wake-word window with the extended note-review
    ///      phrase table — the user can say
    ///      `weiter / verwerfen / später / nochmal / ändern`.
    ///   4. Window timeout = "keep" → advance to next note.
    ///
    /// The Weiter button still works as a manual override (calls
    /// `advance()` which lands back here with the next index, or
    /// runs `runVoiceNoteClosing` once the last note is past).
    private func runNoteReview(
        stepIndex: Int,
        noteIndex: Int,
        notes: [VoiceNote],
        language: OpenerLanguage
    ) async {
        guard noteIndex >= 0, noteIndex < notes.count else {
            await runVoiceNoteClosing(stepIndex: stepIndex, notes: notes, language: language)
            return
        }
        interruptInFlight = false
        state = .noteReview(stepIndex: stepIndex, noteIndex: noteIndex)

        if noteIndex == 0 {
            let segID = "s\(zeroPad(stepIndex + 1))"
            let intro = composeNotesIntro(notes: notes, language: language)
            if !intro.isEmpty {
                recordAiPrompt(role: "drive_by_recap", segmentID: segID, text: intro)
                lastSpoken = intro
                await speak(intro, language: language.rawValue)
            }
        }

        // Bail if the user cancelled / advanced while the intro was
        // speaking — `cancelTTS` resets state and we don't want to
        // play the audio over the next event's opener.
        guard case .noteReview(let liveStep, let liveSeed) = state,
              liveStep == stepIndex, liveSeed == noteIndex else { return }

        await summariseAndListen(
            note: notes[noteIndex],
            index: noteIndex,
            total: notes.count,
            language: language
        )
    }

    /// Initial surfacing of a note (mirrors `speakCurrentTodoPrompt`):
    /// speak a one-sentence summary framed as an "include?" question, then
    /// open the note-review wake-word window. The raw recording is *not*
    /// auto-played — the user hears it on demand via the play disc or by
    /// saying "nochmal". This gives every note the same spoken guidance
    /// the todo confirmation has (previously only the first note had any).
    private func summariseAndListen(
        note: VoiceNote,
        index: Int,
        total: Int,
        language: OpenerLanguage
    ) async {
        guard case .noteReview(let stepIndex, _) = state else { return }
        let summary = await noteSummary(note: note, language: language)
        guard case .noteReview = state else { return }
        let prompt = composeNotePrompt(
            index: index, total: total, summary: summary, language: language
        )
        lastSpoken = prompt
        recordAiPrompt(role: "note_prompt",
                       segmentID: "s\(zeroPad(stepIndex + 1))",
                       text: prompt)
        await speak(prompt, language: language.rawValue)
        await openNoteWakeWindow(language: language)
    }

    /// Play the note's raw recording, then open the wake-word window.
    /// Used by the "nochmal" / play-disc replay path so the user can
    /// re-hear the original after the spoken summary.
    private func playNoteAndListen(
        note: VoiceNote,
        language: OpenerLanguage
    ) async {
        await playNoteAudio(note: note)
        guard case .noteReview = state else { return }
        await openNoteWakeWindow(language: language)
    }

    /// Open the note-review wake-word window and route its outcome.
    /// Shared by the summary pass and the raw-audio replay. Timeout
    /// (silence) keeps the note — note ideas default to included —
    /// and advances; a matched command was already dispatched inside the
    /// window; `.skipped` leaves the card for manual control.
    private func openNoteWakeWindow(language: OpenerLanguage) async {
        guard case .noteReview = state else { return }
        // Short settle so the wake-word ping doesn't land on the tail of
        // the just-spoken summary / replayed audio. Cancellable.
        try? await Task.sleep(nanoseconds: 600_000_000)
        guard case .noteReview = state else { return }
        wakeWordTask?.cancel()
        wakeWordTask = Task { [weak self] in
            guard let self else { return }
            let outcome = await self.runWakeWordWindow(language: language)
            switch outcome {
            case .matched:
                // A command (ja/weiter / nein/verwerfen / später /
                // nochmal / ändern) was already dispatched in the window.
                break
            case .timedOut:
                // Silent → keep this note and move on, same as Weiter.
                guard case .noteReview = self.state else { return }
                await self.advance()
            case .skipped:
                // Window never opened (wake-word off / asset missing /
                // permission denied) — leave the card for the buttons.
                break
            }
        }
    }

    /// One-sentence summary of a note for the spoken prompt. Routes
    /// through `cachedNoteSummary` so a session-start pre-generation
    /// (`prefetchAllNoteSummaries`) and the per-note review share the
    /// same summary — both for correctness (manifest logs the same text
    /// the user heard) and for latency (the review sees a cache hit).
    private func noteSummary(note: VoiceNote, language: OpenerLanguage) async -> String {
        await cachedNoteSummary(note, language: language)
    }

    /// Per-note dedup + cache. Mirrors `eventOpenerSpans` for openers:
    /// the cache check + task lookup happen with no `await` between them,
    /// so on the MainActor they're atomic w.r.t. other tasks. A
    /// concurrent prefetch + live caller resolve onto a single LLM call.
    private func cachedNoteSummary(_ note: VoiceNote, language: OpenerLanguage) async -> String {
        if let cached = noteSummaryCache[note.id] { return cached }
        if let task = noteSummaryTasks[note.id] { return await task.value }
        let transcript = note.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        // Short transcripts (or empty) are their own summary — skip LLM.
        if transcript.count <= 80 {
            noteSummaryCache[note.id] = transcript
            return transcript
        }
        let task = Task<String, Never> { [weak self] in
            guard let self else { return Self.firstSentence(of: transcript) }
            return await self.computeNoteSummary(
                transcript: transcript, language: language
            )
        }
        noteSummaryTasks[note.id] = task
        let summary = await task.value
        // Set cache before clearing task so a brand-new caller arriving
        // in this window still finds either the cache or the task.
        noteSummaryCache[note.id] = summary
        noteSummaryTasks.removeValue(forKey: note.id)
        return summary
    }

    /// The actual LLM round-trip + fallback. Pulled out so
    /// `cachedNoteSummary` only contains the cache plumbing.
    private func computeNoteSummary(
        transcript: String,
        language: OpenerLanguage
    ) async -> String {
        let llm = DialogLLMResolver.current()
        if await llm.isAvailable {
            do {
                return try await llm.summarizeNote(
                    transcript: transcript, language: language.rawValue
                )
            } catch {
                Log.app.warning(
                    "note summary via FoundationModels failed: \(String(describing: error), privacy: .public)"
                )
            }
        }
        return Self.firstSentence(of: transcript)
    }

    /// Deterministic summary fallback: the first sentence, or a hard
    /// length cap when the note is one long run-on.
    private static func firstSentence(of text: String) -> String {
        if let range = text.rangeOfCharacter(from: CharacterSet(charactersIn: ".!?")) {
            let s = String(text[..<range.upperBound]).trimmingCharacters(in: .whitespaces)
            if s.count >= 12 { return s }
        }
        if text.count <= 140 { return text }
        let idx = text.index(text.startIndex, offsetBy: 140)
        return String(text[..<idx]).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// Per-note spoken prompt, mirroring `speakCurrentTodoPrompt`'s shape:
    /// optional "X von N" progress anchor + the summary + an include
    /// question. German guillemets via escapes so the closing quote isn't
    /// an ASCII " that would end the string literal.
    private func composeNotePrompt(
        index: Int,
        total: Int,
        summary: String,
        language: OpenerLanguage
    ) -> String {
        let openQ = "\u{201E}"
        let closeQ = "\u{201C}"
        let pos: String = total > 1
            ? (language == .de ? "\(index + 1) von \(total): " : "\(index + 1) of \(total): ")
            : ""
        switch language {
        case .de:
            if summary.isEmpty {
                return "\(pos)Eine Notiz ohne Transkript. Soll ich sie aufnehmen?"
            }
            return "\(pos)Du hast notiert: \(openQ)\(summary)\(closeQ) Soll ich sie aufnehmen?"
        case .en:
            if summary.isEmpty {
                return "\(pos)A note without a transcript. Should I include it?"
            }
            return "\(pos)You noted: \(openQ)\(summary)\(closeQ) Should I include it?"
        }
    }

    /// Play the note's original .m4a through the shared `notePlayer`.
    /// Runs under the existing `.playAndRecord` session (the player has
    /// `managesSession: false`) so the walkthrough's mic graph isn't
    /// disturbed. Returns once playback finishes naturally (or fails to
    /// start, or is stopped via `stopNotePlayback()`). Because it's the
    /// same player the `NoteReviewCard` renders, the user can pause /
    /// resume / scrub this read-aloud; the wake-word window only opens
    /// once it plays through to the end.
    private func playNoteAudio(note: VoiceNote) async {
        stopNotePlayback()
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            notePlaybackContinuation = cont
            notePlayer.onNaturalFinish = { [weak self] in
                self?.finishNotePlayback()
            }
            notePlayer.toggle(url: note.audio_file_url)
            // `toggle` loads + plays synchronously; if the file failed to
            // open it resets `activeURL` to nil. Resume right away so the
            // caller doesn't hang waiting for audio that never started.
            if notePlayer.activeURL != note.audio_file_url {
                Diag.log("note playback start FAILED note=\(note.seed_id)")
                finishNotePlayback()
            } else {
                Diag.log("note playback start note=\(note.seed_id) dur=\(notePlayer.duration)s")
            }
        }
    }

    /// Natural-completion path (the player's finish hook). Clears the
    /// hook and resumes the playback continuation if it hasn't already
    /// been resumed by `stopNotePlayback()`.
    private func finishNotePlayback() {
        notePlayer.onNaturalFinish = nil
        if let cont = notePlaybackContinuation {
            notePlaybackContinuation = nil
            cont.resume()
        }
    }

    /// Cancel any in-flight note playback. Idempotent — safe to call
    /// from cancel paths even when nothing is playing. Resumes the
    /// continuation so `playNoteAudio`'s awaiter doesn't hang (a manual
    /// `stop()` never triggers the natural-finish hook). The continuation
    /// is niled first so a racing natural-finish can't double-resume.
    private func stopNotePlayback() {
        notePlayer.onNaturalFinish = nil
        notePlayer.stop()
        if let cont = notePlaybackContinuation {
            notePlaybackContinuation = nil
            cont.resume()
        }
    }

    /// Closing question for the note step: speaks "Willst du noch
    /// etwas zum ganzen Tag sagen?" and opens the free-reflection
    /// capture. Pulled out of `runVoiceNotes` so the per-note review can
    /// share it once the user has stepped through all notes.
    private func runVoiceNoteClosing(
        stepIndex: Int,
        notes: [VoiceNote],
        language: OpenerLanguage
    ) async {
        interruptInFlight = false
        state = .voiceNoteOpener(stepIndex: stepIndex)
        statusHint = ""
        confirmationLanguage = language

        let segID = "s\(zeroPad(stepIndex + 1))"
        let closing = OpenerTemplates.closingPrompt(language: language)
        recordAiPrompt(role: "closing_prompt", segmentID: segID, text: closing)
        lastSpoken = closing
        await speakOpenerScript(
            segmentID: segID,
            fallbackSpans: [SpokenSpan(text: closing, language: language.rawValue)]
        )
        guard case .voiceNoteOpener(let liveStep) = state,
              liveStep == stepIndex else { return }
        if interruptInFlight { return }

        do {
            try await startVoiceNoteCapture(segmentID: segID, notes: notes)
            guard case .voiceNoteOpener(let liveStep2) = state,
                  liveStep2 == stepIndex else { return }
            state = .voiceNoteListening(stepIndex: stepIndex)
            startTimer()
            startLullDetection(
                context: .voiceNote,
                step: stepIndex,
                language: language
            )
        } catch {
            self.error = "\(error)"
            await ingestAndUpload()
        }
    }

    private func composeNotesIntro(
        notes: [VoiceNote],
        language: OpenerLanguage
    ) -> String {
        guard !notes.isEmpty else { return "" }
        let count = notes.count
        // Phrased as "we'll go through these now" rather than "I'll fold
        // them into the entry" — the per-note review now lets the user
        // drop / defer / re-record each one, so promising up-front that
        // every note is kept would be wrong.
        switch language {
        case .de:
            switch count {
            case 1: return "Du hast heute eine Notiz aufgenommen. Wir gehen sie nun durch:"
            default: return "Du hast heute \(count) Notizen aufgenommen. Wir gehen diese nun durch:"
            }
        case .en:
            switch count {
            case 1: return "You captured one note earlier. Let's go through it now:"
            default: return "You captured \(count) notes earlier. Let's go through them now:"
            }
        }
    }

    // MARK: - Enrichment (M7) -------------------------------------------

    public func askEnrichment(
        query: String,
        language: OpenerLanguage = .current
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

    /// Compute the canonical *base* segment ID for the current listening
    /// state. The actual on-disk segment may carry a `c<N>` suffix once
    /// the user has paused/resumed; use `currentRecordingSegmentID` for
    /// "the file we're actually writing to right now."
    private var baseSegmentIDForCurrentState: String? {
        switch state {
        case .eventListening(let s, let e):
            return makeEventSegmentID(stepIndex: s, eventIndex: e)
        case .generalListening(let s, _), .voiceNoteListening(let s):
            return "s\(zeroPad(s + 1))"
        default:
            return nil
        }
    }

    /// Derive the actual segment ID to use for the next recording of a
    /// given base ID, accounting for prior pause/resume cycles on the
    /// same step. Bumps `segmentResumeCounter` so the next call returns
    /// a unique suffix. First call returns the base verbatim; second
    /// returns `<base>c2`, third `<base>c3`, …
    private func nextActualSegmentID(forBase base: String) -> String {
        let prior = segmentResumeCounter[base, default: 0]
        let next = prior + 1
        segmentResumeCounter[base] = next
        return next == 1 ? base : "\(base)c\(next)"
    }

    // MARK: - Capture --------------------------------------------------

    private func startEventCapture(
        segmentID baseSegmentID: String,
        event: ServerCalendarEvent
    ) async throws {
        guard let sessionDir else { throw NSError(domain: "Walkthrough", code: 1) }
        let actualID = nextActualSegmentID(forBase: baseSegmentID)
        let path = mediaPath(for: actualID)
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
        segmentRecordingStartedAt = Date()
        silenceRunStartedAt = nil

        let calRef = CalendarRef(
            graph_event_id: event.graph_event_id,
            title: event.subject,
            start: event.start,
            end: event.end,
            attendees: event.attendees.map { $0.email.isEmpty ? $0.name : $0.email },
            rsvp_status: event.rsvp_status
        )
        let seg = CalendarEventSegment(
            segment_id: actualID,
            calendar_ref: calRef,
            audio_file: path
        )
        segments.append(.calendarEvent(seg))
        segmentByID[actualID] = segments.count - 1
        currentRecordingSegmentID = actualID
    }

    private func startGeneralCapture(
        segmentID baseSegmentID: String,
        section: GeneralSection
    ) async throws {
        guard let sessionDir else { throw NSError(domain: "Walkthrough", code: 1) }
        let actualID = nextActualSegmentID(forBase: baseSegmentID)
        let path = mediaPath(for: actualID)
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
        segmentRecordingStartedAt = Date()
        silenceRunStartedAt = nil
        let seg = GeneralSectionSegment(
            segment_id: actualID,
            section_id: section.id,
            title: section.title,
            prompt_text: section.introText,
            audio_file: path
        )
        segments.append(.generalSection(seg))
        segmentByID[actualID] = segments.count - 1
        currentRecordingSegmentID = actualID
    }

    private func startVoiceNoteCapture(
        segmentID baseSegmentID: String,
        notes: [VoiceNote]
    ) async throws {
        guard let sessionDir else { throw NSError(domain: "Walkthrough", code: 1) }
        let actualID = nextActualSegmentID(forBase: baseSegmentID)
        let path = mediaPath(for: actualID)
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
        segmentRecordingStartedAt = Date()
        silenceRunStartedAt = nil
        let seg = FreeReflectionSegment(
            segment_id: actualID,
            audio_file: path,
            captured_at: ISO8601DateFormatter().string(from: Date())
        )
        segments.append(.freeReflection(seg))
        segmentByID[actualID] = segments.count - 1
        currentRecordingSegmentID = actualID

        // Attach each surfaced note as its own `drive_by` segment so the
        // server has the audio + transcript already available. Files are
        // copied into the session dir to keep the upload bundle
        // self-contained. Seeds the user said "Für später" on during
        // per-note review are skipped here so they stay in the
        // unsurfaced pool for the next walkthrough.
        var surfaced: [String] = []
        for note in notes where !deferredNoteIDs.contains(note.seed_id)
                             && !droppedNoteIDs.contains(note.seed_id) {
            let copyName = "seed_\(sanitize(note.seed_id)).m4a"
            let copyPath = "segments/\(copyName)"
            let copyURL = sessionDir.appending(path: copyPath)
            do {
                try FileManager.default.copyItem(at: note.audio_file_url, to: copyURL)
            } catch {
                Log.app.warning(
                    "note copy failed (\(note.seed_id, privacy: .public)): \(String(describing: error), privacy: .public)"
                )
                continue
            }
            segmentURLs[copyPath] = copyURL
            let dbSeg = VoiceNoteSegment(
                segment_id: "db_\(sanitize(note.seed_id))",
                captured_at: ISO8601DateFormatter().string(from: note.captured_at),
                audio_file: copyPath,
                transcript: note.transcript,
                language: note.language,
                seed_id: note.seed_id
            )
            segments.append(.voiceNote(dbSeg))
            surfaced.append(note.seed_id)
        }
        surfacedNoteIDs = surfaced
    }

    private func dropStagedSegment(forStepIndex stepIdx: Int, eventIndex: Int?) async {
        try? await engine.stop()
        // Drop the *actual* segment currently being recorded, not the
        // base ID derived from indices. After a pause/resume the actual
        // ID carries a `c<N>` suffix; using the base would orphan the
        // suffixed file and leave the dangling segment in the manifest.
        // Falls back to the base ID when nothing was actively recording
        // (e.g. skip during an opener TTS before the engine started).
        let segID: String = currentRecordingSegmentID ?? {
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
            case .voiceNote, .emptyBlock:  return false
            }
        }
        segmentByID.removeValue(forKey: segID)
        currentRecordingSegmentID = nil
    }

    private func stopSegmentCapture(resetElapsed: Bool = true) async {
        timer?.invalidate(); timer = nil
        // Pause flow passes `resetElapsed: false` so the visible timer
        // freezes at the moment the user tapped Pause instead of
        // snapping back to 00:00. Normal advance/skip/finishSection keep
        // the default — each new event gets a fresh counter.
        if resetElapsed { elapsedSeconds = 0 }
        lullDetector.stop()

        let finishingSegmentID: String? = currentRecordingSegmentID
        let finishingURL = finishingSegmentID.flatMap { segmentURLs[mediaPath(for: $0)] }
        // Clear the actual-id pointer before we await the engine so a
        // subsequent `resume()` (or a stray wake-word window racing the
        // shutdown) can't accidentally trim/transcribe the same file
        // twice.
        currentRecordingSegmentID = nil

        do { _ = try await engine.stop() } catch {
            Log.audio.warning("walkthrough engine stop: \(String(describing: error), privacy: .public)")
        }

        // Trim the matched command word out of the segment file *before*
        // spawning the finalise task, so Parakeet sees the cleaned file;
        // server-side Whisper picks up the same trimmed audio at upload.
        // The trim runs synchronously here because the file is small (a
        // few minutes of AAC at 64 kbps) and the export-passthrough
        // preset just rewrites the moov atom.
        //
        // When the wake word landed during a silence run we know exactly
        // where the user's reflection ended — the start of that run — so
        // we keep only up to that point (`keepFirst`), dropping the
        // trailing silence + ping + command. If that clean cut point was
        // lost (`dropLast`) we fall back to a conservative fixed tail
        // trim so the command never leaks, at the cost of possibly
        // clipping a little real audio.
        if let segmentID = finishingSegmentID,
           let url = finishingURL,
           let trim = wakeMatchTrim[segmentID] {
            do {
                switch trim {
                case .keepFirst(let keep):
                    try await AudioMerger.trim(of: url, keepingFirstSeconds: keep)
                    Log.audio.notice(
                        "wake-word trim: \(segmentID, privacy: .public) keep=\(String(format: "%.1f", keep))s"
                    )
                case .dropLast(let drop):
                    try await AudioMerger.trimTail(of: url, removingLastSeconds: drop)
                    Log.audio.notice(
                        "wake-word trim (fallback): \(segmentID, privacy: .public) -\(String(format: "%.1f", drop))s"
                    )
                }
            } catch {
                Log.audio.warning(
                    "wake-word trim failed for \(segmentID, privacy: .public): \(String(describing: error), privacy: .public)"
                )
            }
            wakeMatchTrim.removeValue(forKey: segmentID)
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

        // Strip stock Parakeet hallucinations ("vielen Dank fürs
        // Zuschauen" et al.) before feeding the transcript to either
        // extractor — otherwise the on-device LLM confidently invents
        // todos from text the user never said. The original
        // `transcript.text` is preserved on the segment for the
        // user-facing review surfaces.
        let sanitised = TodoExtractor.sanitiseForTodos(transcript.text)
        let isSubstantial = sanitised.count >= 20
        if !isSubstantial && !transcript.text.isEmpty {
            Log.app.info(
                "segment \(segmentID, privacy: .public): transcript reduced to \(sanitised.count, privacy: .public) chars after hallucination strip — skipping todo extraction"
            )
        }

        let todos: [Todo] = isSubstantial
            ? TodoExtractor.extractExplicit(
                text: sanitised,
                language: transcript.language,
                sourceSegmentID: segmentID
            )
            : []
        if !todos.isEmpty {
            Log.app.info(
                "segment \(segmentID, privacy: .public): \(todos.count, privacy: .public) explicit todo(s) detected"
            )
        }

        let llm = DialogLLMResolver.current()
        if isSubstantial, await llm.isAvailable {
            do {
                let candidates = try await llm.extractImplicit(
                    transcript: sanitised,
                    language: transcript.language
                )
                let novel = self.dedupeImplicit(
                    candidates: candidates,
                    againstExplicit: todos,
                    forSegmentID: segmentID,
                    transcriptText: sanitised,
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
        // Merge any chunked recordings (pause/resume produced multiple
        // m4a per logical event) into one m4a per base id BEFORE we
        // build the manifest, so the upload + history both see "one
        // continuous recording per meeting" — matching the user's
        // mental model. Chunks stay on disk during recording for
        // crash safety; this is the consolidation step.
        if let dir = sessionDir {
            let merged = await ChunkMerger.merge(
                segments: segments,
                segmentURLs: segmentURLs,
                segmentByID: segmentByID,
                sessionDir: dir
            )
            segments = merged.segments
            segmentURLs = merged.segmentURLs
            segmentByID = merged.segmentByID
        }
        let manifest = try buildManifest()
        sessionID = manifest.session_id
        if let dir = sessionDir {
            do { try LocalStore.writeManifest(manifest, to: dir) }
            catch { Log.app.warning("manifest snapshot failed: \(String(describing: error), privacy: .public)") }
        }
        // Mark surfaced notes *now* so a successful enqueue doesn't leave
        // them in the unsurfaced pool — the upload itself retries with
        // exponential backoff and we don't want to re-surface across
        // retries. Dropped notes (user said "verwerfen") are merged in
        // here too: the manifest excludes them from the entry, but
        // marking them surfaced stops them from reappearing on the
        // next walkthrough. Their audio files stay on disk.
        let toMarkSurfaced = Array(Set(surfacedNoteIDs).union(droppedNoteIDs))
        if !toMarkSurfaced.isEmpty {
            LocalStore.markSeedsSurfaced(ids: toMarkSurfaced)
        }
        await SessionUploader.shared.enqueue(
            manifest: manifest,
            audioFiles: segmentURLs
        )
        recordedDates.insert(manifest.date)
        // The session is on its way to the server; any lingering pause
        // marker no longer applies.
        deletePauseMarker()
        state = .done
        // Walkthrough is over — release the always-running audio engine
        // and let the audio session deactivate cleanly. The next
        // walkthrough will pre-arm again from foreground.
        await engine.shutdown()
        clearPrefetchedOpeners()
        Task { await loadRecordedDates(around: selectedDate) }
    }

    // MARK: - Follow-up logic ------------------------------------------

    /// What the lull loop is running on top of. Drives the per-step state
    /// guard inside the threshold callback and the per-context branch in
    /// the 6 s case (events use generated event-aware questions, generals
    /// use section-aware questions when the user opted in, note stays
    /// quiet — its closing prompt was already broad).
    private enum LullStepContext: Sendable {
        case event(eventIndex: Int, evts: [ServerCalendarEvent])
        case general(GeneralSection)
        case voiceNote
    }

    private func startLullDetection(
        context: LullStepContext,
        step: Int,
        language: OpenerLanguage
    ) {
        // Count silence from segment start, not just after the user's
        // first words, so a user who stays completely silent still gets
        // a voice path to move on (see `handleLull` case 15). The
        // `hasHeardSpeech` checks in cases 3/6 preserve the old
        // post-speech behaviour — and the SPEC §6.7 "3 s — thinking is
        // fine" think-time — for the common case where the user does speak.
        lullDetector.firePreSpeech = true
        // Loop timing:
        //   3 s  → wake-word window opens (post-speech only).
        //   6 s  → wake window closes + AI follow-up (post-speech only).
        //   15 s → silent users get the "soll ich weitermachen?" prompt
        //          + wake window; users who spoke just see the status row.
        //   24 s → auto-advance (gives the 15 s window room to run after
        //          the spoken prompt before the step times out).
        lullDetector.thresholds = [3, 6, 15, 24]
        lullDetector.start(
            onThresholdCrossed: { [weak self] threshold in
                guard let self else { return }
                Task { @MainActor in
                    guard self.isLullContextActive(context, step: step) else { return }
                    await self.handleLull(
                        threshold: threshold,
                        context: context,
                        step: step,
                        language: language
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

    private func isLullContextActive(_ context: LullStepContext, step: Int) -> Bool {
        switch (context, state) {
        case let (.event(eIdx, _), .eventListening(s, e)):
            return s == step && e == eIdx
        case let (.general(section), .generalListening(s, id)):
            return s == step && id == section.id
        case (.voiceNote, .voiceNoteListening(let s)):
            return s == step
        default:
            return false
        }
    }

    /// Segment ID that owns the current listening loop — used to key
    /// `followUpUsed` so each step / event fires the AI follow-up at most
    /// once across multiple silence runs.
    private func lullSegmentID(_ context: LullStepContext, step: Int) -> String {
        switch context {
        case .event(let eIdx, _):
            return makeEventSegmentID(stepIndex: step, eventIndex: eIdx)
        case .general, .voiceNote:
            return "s\(zeroPad(step + 1))"
        }
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
        // The reflection no longer ends at the prior silence-run start —
        // the user is talking again. Drop the cut point so a later wake
        // match (without a fresh lull) falls back to the safe tail trim
        // instead of slicing off real speech.
        silenceRunStartedAt = nil
        if let task = followUpTask {
            task.cancel()
            followUpTask = nil
        }
    }

    /// Per-silence-run loop, identical shape for every listening segment
    /// (events, generals, note closer):
    ///
    /// Two sub-loops depending on whether the user has spoken yet
    /// (`lullDetector.hasHeardSpeech`). `firePreSpeech` makes the timer
    /// run from segment start either way.
    ///
    /// Post-speech (user spoke, then paused — the common case):
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
    ///                                          │   of this segment (gated by
    ///                                          │   `followUpUsed[segID]`) and
    ///                                          │   only when the context opts in
    ///   t=15  ── "Stille seit 15s" ──────────►│
    ///   t=24  ── auto-advance to next step ───┘
    /// ```
    ///
    /// Pre-speech (user silent since the opener):
    /// ```
    ///   t=3   ── suppressed (think-time, SPEC §6.7)
    ///   t=6   ── suppressed
    ///   t=15  ── AI: "soll ich weitermachen?" + wake-window opens
    ///                 say "weiter"/"fertig" → advance
    ///                 start talking         → switch to post-speech loop
    ///   t=24  ── auto-advance to next step
    /// ```
    ///
    /// Earlier the wake-cancel + follow-up dispatch were both wrapped
    /// in the `followUpUsed` guard — meaning the second silence run
    /// (where `followUpUsed = true`) hit `return` before cancelling the
    /// wake task, so the wake window stayed visually open until its own
    /// 8 s timeout. Splitting the two responsibilities fixes the loop.
    private func handleLull(
        threshold: Int,
        context: LullStepContext,
        step: Int,
        language: OpenerLanguage
    ) async {
        silenceLevel = threshold
        switch threshold {

        case 3:
            // Post-speech wake window only. A user who hasn't spoken
            // since the opener is given think-time here (SPEC §6.7:
            // "3 s — thinking is fine") and gets a voice path at 15 s
            // instead. Without this guard, `firePreSpeech` would pop the
            // window the instant the opener ended.
            guard lullDetector.hasHeardSpeech else {
                Diag.log("lull case=3 suppressed — no speech yet (think-time)")
                break
            }
            // Mark where the reflection ended (≈ now − 3 s) so a wake
            // match can cut the trailing silence + command word cleanly.
            silenceRunStartedAt = Date().addingTimeInterval(-Double(threshold))
            // Open the wake-word listen window. Spawned as a tracked
            // Task so handleLull returns promptly; the wake task
            // plays the ping, opens a streaming ASR, listens until
            // either a wake word matches (`advance`/`finishCurrentSection`),
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
            // Silent users skip the follow-up entirely — their voice
            // path is the 15 s prompt below, and case 3 never opened a
            // window for them so there's nothing to close here.
            guard lullDetector.hasHeardSpeech else {
                Diag.log("lull case=6 suppressed — no speech yet")
                break
            }
            // Wake-window close decision: with headphones (or any non-
            // speaker output) we LEAVE the wake-word window open so the
            // user can interrupt the AI's follow-up question with
            // "weiter" / "fertig". On the built-in speaker the
            // speaker→mic feedback is dangerous so we close it. When
            // the context doesn't fire an AI follow-up at all (note,
            // or a general section with follow-up disabled), there's no
            // TTS to ride out — close the window unconditionally.
            let willFireFollowUp = wantsFollowUp(for: context)
            let extendThroughFollowUp = willFireFollowUp && Self.isHeadphonesOutputActive()
            if !extendThroughFollowUp {
                wakeWordTask?.cancel(); wakeWordTask = nil
                isWakeListening = false
            }

            guard willFireFollowUp else { return }

            // Only fire the AI follow-up question once per listening
            // segment. After the first time, subsequent silence runs
            // simply show "Stille seit 6s" and let the lull keep ticking.
            let segID = lullSegmentID(context, step: step)
            guard followUpUsed[segID] != true else {
                Diag.log("lull case=6 follow-up already used for \(segID), no AI prompt")
                return
            }
            followUpUsed[segID] = true

            // Spawn the follow-up as a *cancellable* Task and stash
            // the handle. `handleSpeechResumed` cancels it if the
            // user starts talking again before the AI finishes
            // preparing. A wake-word match (in headphones mode)
            // cancels it too — see `runWakeWordWindow`'s match path.
            Diag.log("lull case=6 spawning follow-up segID=\(segID) headphones=\(extendThroughFollowUp)")
            let capturedContext = context
            followUpTask = Task { [weak self] in
                guard let self else { return }
                await self.speakFollowUp(
                    context: capturedContext,
                    language: language
                )
            }

        case 15:
            // Spoke, then went quiet: the status row's "Stille seit 15s"
            // message is enough on its own.
            if lullDetector.hasHeardSpeech { break }
            // Silent since the opener (SPEC §6.7): give a voice path to
            // move on. Speak a short "soll ich weitermachen?" nudge, then
            // open the standard wake window so "weiter"/"fertig" advances.
            // Saying nothing falls through to the 24 s auto-advance;
            // starting to talk resets into the normal post-speech loop.
            // Count it as this segment's one AI prompt so the loop can't
            // also fire a 6 s follow-up afterwards.
            Diag.log("lull case=15 silent-path continue prompt + wake window")
            followUpUsed[lullSegmentID(context, step: step)] = true
            silenceRunStartedAt = Date().addingTimeInterval(-Double(threshold))
            let promptLang = language
            let promptStep = step
            let promptContext = context
            wakeWordTask?.cancel(); wakeWordTask = nil
            wakeWordTask = Task { [weak self] in
                await self?.speakContinuePromptThenListen(
                    context: promptContext,
                    step: promptStep,
                    language: promptLang
                )
            }

        case 24:
            // Silent for 24 s straight (or no response to the 15 s
            // prompt). Auto-advance — they're clearly done with this one.
            Diag.log("lull case=24 auto-advance")
            wakeWordTask?.cancel(); wakeWordTask = nil
            isWakeListening = false
            await advance(language: language)

        default:
            break
        }
    }

    /// Silent-path 15 s handler: speak the "soll ich weitermachen?"
    /// prompt, then open a wake-word window. The shared `lullDetector`
    /// keeps running underneath, so the three outcomes are all covered:
    /// the user says "weiter"/"fertig" → the window advances; the user
    /// starts a real reflection → `handleSpeechResumed` fires and the
    /// normal post-speech loop takes over; the user stays silent → the
    /// 24 s auto-advance closes the step. On built-in speaker the prompt
    /// TTS bleeds into the open mic exactly as the 6 s follow-up already
    /// does — same accepted trade-off, no AEC in this session.
    private func speakContinuePromptThenListen(
        context: LullStepContext,
        step: Int,
        language: OpenerLanguage
    ) async {
        guard isLullContextActive(context, step: step) else { return }
        let prompt = OpenerTemplates.continuePrompt(language: language)
        lastSpoken = prompt
        recordAiPrompt(role: "continue_prompt",
                       segmentID: currentRecordingSegmentID,
                       text: prompt)
        await speak(prompt, language: language.rawValue)
        // Bail if the user advanced / cancelled / started talking while
        // the prompt was synthesising or playing.
        if Task.isCancelled || !isLullContextActive(context, step: step) { return }
        await runWakeWordWindow(language: language)
    }

    /// True when the lull's 6 s branch should generate + speak a follow-up
    /// question. Calendar events always do; user-defined general sections
    /// only when the user toggled `followUpEnabled` on; note stays
    /// quiet (its closing prompt was already broad).
    private func wantsFollowUp(for context: LullStepContext) -> Bool {
        switch context {
        case .event:                  return true
        case .general(let section):   return section.followUpEnabled
        case .voiceNote:                return false
        }
    }

    private func speakFollowUp(
        context: LullStepContext,
        language: OpenerLanguage
    ) async {
        let llm = DialogLLMResolver.current()
        var line: String?
        if await llm.isAvailable {
            do {
                line = try await generateFollowUpLine(
                    context: context,
                    language: language,
                    llm: llm
                )
            } catch {
                Log.app.warning(
                    "FoundationModels follow-up failed: \(String(describing: error), privacy: .public)"
                )
            }
        }
        // First cancellation gate: bail if the user resumed speech
        // while the LLM was generating.
        if Task.isCancelled { return }

        if line == nil || line?.isEmpty == true {
            line = OpenerTemplates.followUp(language: language, rotation: followUpRotation)
            followUpRotation += 1
        }
        guard let spoken = line, !spoken.isEmpty else { return }

        lastSpoken = spoken
        let segID: String? = currentRecordingSegmentID
        recordAiPrompt(role: "follow_up", segmentID: segID, text: spoken)
        // Second cancellation gate: skip the speak entirely if the
        // user spoke during prompt-template selection.
        if Task.isCancelled { return }
        await speak(spoken, language: language.rawValue)
    }

    private func generateFollowUpLine(
        context: LullStepContext,
        language: OpenerLanguage,
        llm: any DialogLLM
    ) async throws -> String {
        switch context {
        case .event(let eIdx, let evts):
            guard eIdx < evts.count else { throw LLMError.empty }
            let event = evts[eIdx]
            let attendeeNames = event.attendees.map(\.name).filter { !$0.isEmpty }
            let result = try await llm.generateFollowUp(
                eventTitle: event.subject,
                attendees: attendeeNames,
                userTranscript: "",
                language: language.rawValue
            )
            Log.app.info("follow-up via FoundationModels for event \(eIdx, privacy: .public)")
            return result

        case .general(let section):
            let result = try await llm.generateGeneralFollowUp(
                sectionTitle: section.title,
                sectionIntro: section.introText,
                userTranscript: "",
                language: language.rawValue
            )
            Log.app.info("follow-up via FoundationModels for general section \(section.id, privacy: .public)")
            return result

        case .voiceNote:
            // Note doesn't fire a follow-up (filtered upstream by
            // `wantsFollowUp`). If we got here something is off — return
            // empty so the template fallback path in the caller takes over.
            throw LLMError.empty
        }
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

        // Harden against the intermittent dropped-intro race. The path
        // into here is `ingestAndUpload → finishUploadOrConfirmTodos`,
        // which already awaits all per-segment finalisation tasks; in
        // practice that means the previous TTS engine state can still
        // be in a transient "stopping" tail (Apple synth right after
        // `stopSpeaking(at: .immediate)`, or Piper's serial queue with
        // a cancelled-but-not-yet-drained Task at the head). Both
        // engines occasionally swallow a `speak()` queued in that
        // window. Two cheap fixes that compose:
        //
        //   1. `await cancelTTS()` puts both engines into a known-
        //      empty state (no queued utterance, no pending player).
        //   2. A short settle pause lets the audio session route +
        //      `AVAudioEngine` no-op tap stabilise before we open a
        //      fresh TTS continuation.
        //
        // Logged on entry + exit so a future "intro didn't play"
        // report can be confirmed against the timeline instead of
        // guessed at.
        Diag.log("todo intro begin lang=\(lang.rawValue) candidates=\(pendingImplicitTodos.count)")
        await cancelTTS()
        try? await Task.sleep(nanoseconds: 200_000_000)
        lastSpoken = intro
        recordAiPrompt(role: "todo_intro", segmentID: nil, text: intro)
        await speak(intro, language: lang.rawValue)
        Diag.log("todo intro spoken")
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
        // Frame as a question so the yes/no affordance is obvious from
        // the spoken line alone. With multiple candidates the leading
        // "1 von 3" anchor still helps the user track progress.
        // `TodoAnswerParser` recognises both keyword answers (ja / nein
        // / anders) and refinements ("nimm lieber X stattdessen").
        // Use German low/high guillemets ( U+201E … U+201C ) so the
        // closing quote isn't an ASCII " that would terminate the
        // string literal mid-interpolation.
        let openQ  = "\u{201E}"
        let closeQ = "\u{201C}"
        let body: String
        switch lang {
        case .de:
            body = total > 1
                ? "\(i + 1) von \(total): Soll ich \(openQ)\(candidate.text)\(closeQ) übernehmen?"
                : "Soll ich \(openQ)\(candidate.text)\(closeQ) übernehmen?"
        case .en:
            body = total > 1
                ? "\(i + 1) of \(total): Should I keep \(openQ)\(candidate.text)\(closeQ)?"
                : "Should I keep \(openQ)\(candidate.text)\(closeQ)?"
        }
        lastSpoken = body
        recordAiPrompt(role: "todo_prompt",
                       segmentID: candidate.source_segment_id,
                       text: body)
        await speak(body, language: lang.rawValue)
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

        // Cadence mirrors the regular listening loop, with todo-specific
        // semantics for each lull threshold:
        //
        //   pre-speech 3 s  → open wake-word window. If the user says
        //                     "weiter"/"next"/"fertig"/"done" the
        //                     match handler routes via advance() →
        //                     rejectCurrentTodo() and we never reach
        //                     the transcribe path.
        //   post-speech 3 s → end of utterance, the user paused after
        //                     answering. Break the loop → transcribe.
        //   pre-speech 12 s → user stayed silent and didn't say a
        //                     skip-word. Auto-reject.
        //   post-speech 12 s → user spoke but then went very quiet.
        //                     Break the loop → transcribe whatever
        //                     was captured.
        //
        // No 6 s AI follow-up here — todo confirmation never asks a
        // generated follow-up, just plays the candidate text and
        // listens. `firePreSpeech = true` lets the 3 s and 12 s
        // thresholds fire even before the user has uttered a word, so
        // the silent-skip path actually arms.
        let detector = answerLullDetector
        detector.thresholds = [3, 12]
        detector.firePreSpeech = true
        silenceLevel = 0
        let lullStream = AsyncStream<Int> { continuation in
            detector.start(
                onThresholdCrossed: { threshold in
                    continuation.yield(threshold)
                },
                onSpeechResumed: { [weak self] in
                    Task { @MainActor in
                        self?.silenceLevel = 0
                    }
                }
            )
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
            detector.firePreSpeech = false
            return
        }

        isAwaitingTodoAnswer = true
        defer { isAwaitingTodoAnswer = false }
        startTimer()

        let answerLanguage = confirmationLanguage

        // Three exit conditions handled here, plus a hard safety
        // timeout (`todoAnswerMaxSeconds`, 20 s) in case the lull
        // stream stalls for some reason — that path also auto-rejects.
        let maxSeconds = Self.todoAnswerMaxSeconds
        var hardTimeout = false
        await withTaskGroup(of: Bool.self) { group in
            group.addTask { [weak self] in
                guard let self else { return false }
                for await crossed in lullStream {
                    await MainActor.run { self.silenceLevel = crossed }
                    let hasSpoken = detector.hasHeardSpeech
                    switch crossed {
                    case 3:
                        if hasSpoken {
                            // End-of-utterance — the user answered and
                            // paused. Exit so we transcribe + parse.
                            return false
                        }
                        // Pre-speech 3 s: open the wake-word window so
                        // the user can skip via voice. Spawned as a
                        // tracked Task so the loop returns promptly
                        // and the 12 s threshold can still fire.
                        await MainActor.run { [weak self] in
                            self?.wakeWordTask?.cancel()
                            self?.wakeWordTask = Task { [weak self] in
                                await self?.runWakeWordWindow(language: answerLanguage)
                            }
                        }
                        continue
                    case 12:
                        // Pre-speech: user stayed silent → auto-reject
                        //   (decided downstream from `hasHeardSpeech`).
                        // Post-speech: long quiet after an answer →
                        //   transcribe whatever was captured.
                        return false
                    default:
                        continue
                    }
                }
                return false
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(maxSeconds * 1e9))
                return true
            }
            if let first = await group.next() { hardTimeout = first }
            group.cancelAll()
            await group.waitForAll()
        }
        let userSpokeAnswer = detector.hasHeardSpeech
        detector.stop()
        detector.firePreSpeech = false
        // Tear down any wake-word window we may have opened. (Match
        // path nils this itself before calling advance(); this is the
        // no-match cleanup.)
        wakeWordTask?.cancel(); wakeWordTask = nil
        isWakeListening = false
        timer?.invalidate(); timer = nil
        elapsedSeconds = 0
        silenceLevel = 0

        if Task.isCancelled {
            try? await engine.stop()
            return
        }

        do { _ = try await engine.stop() }
        catch {
            Log.audio.warning(
                "todo answer engine stop: \(String(describing: error), privacy: .public)"
            )
        }
        try? await Task.sleep(nanoseconds: 200_000_000)

        guard case .confirmingTodos(let nowIndex) = state, nowIndex == index else { return }

        if !userSpokeAnswer {
            // 12 s pre-speech timeout: user neither answered nor said
            // "weiter". Auto-skip this candidate. (The wake-word match
            // path doesn't reach here — advance() cancelled this task
            // before transcribe.)
            Log.app.info("todo answer (\(index, privacy: .public)) → silent timeout, auto-reject")
            await rejectCurrentTodo()
            return
        }
        if hardTimeout {
            Log.app.info("todo answer (\(index, privacy: .public)) → hard timeout, auto-reject")
            await rejectCurrentTodo()
            return
        }

        let transcript: ParakeetManager.Transcript
        do {
            transcript = try await ParakeetManager.shared.transcribe(audioURL: url)
        } catch {
            Log.app.warning(
                "todo answer transcribe failed: \(String(describing: error), privacy: .public)"
            )
            await rejectCurrentTodo()
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
        case .confirm:          await confirmCurrentTodo()
        case .reject:           await rejectCurrentTodo()
        case .refine(let text): await refineCurrentTodo(text)
        case .unknown:
            // Couldn't classify the answer — auto-reject rather than
            // strand the user on this candidate. The buttons that used
            // to provide a manual hedge are gone (voice-first UX), so
            // unknown answers behave like "no" to keep the walkthrough
            // moving.
            await rejectCurrentTodo()
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
        candidates: [ImplicitCandidate],
        againstExplicit explicit: [Todo],
        forSegmentID segmentID: String,
        transcriptText: String,
        transcriptLanguage language: String
    ) -> [Todo] {
        var seen: Set<String> = []
        for t in explicit { seen.insert(normaliseTodoKey(t.text)) }
        for t in pendingImplicitTodos { seen.insert(normaliseTodoKey(t.text)) }

        let transcriptLower = transcriptText.lowercased()
        var out: [Todo] = []
        for c in candidates {
            let key = normaliseTodoKey(c.text)
            guard !key.isEmpty, !seen.contains(key) else { continue }

            // Drop candidates whose words aren't anywhere in the transcript:
            // the German prompt's few-shot examples ("Stephan anrufen",
            // "Deck an Carsten schicken") leak through the LLM verbatim
            // when the real transcript doesn't fit the pattern. Token
            // overlap on ≥4-char alphanumeric substrings is enough to
            // catch that without rejecting legitimate paraphrases —
            // German compound words mean a single matching token is a
            // very strong signal.
            if !Self.isGroundedInTranscript(c.text, transcriptLower: transcriptLower) {
                Log.app.warning(
                    "segment \(segmentID, privacy: .public): dropping ungrounded implicit candidate '\(c.text, privacy: .public)' — no meaningful token overlap with transcript (likely prompt-example hallucination)"
                )
                continue
            }

            seen.insert(key)
            let due = TodoExtractor.parseDueDate(in: c.text, language: language)
            out.append(Todo(
                text: c.text,
                type: "implicit",
                due: due,
                status: "Offen",
                source_segment_id: segmentID,
                source_quote: c.sourceQuote
            ))
        }
        return out
    }

    /// True when at least one ≥4-char alphanumeric token of `text` appears
    /// as a substring in `transcriptLower` (which the caller has already
    /// lower-cased). Substring rather than whole-token match so German
    /// compound nouns like "Dokumentationsabstimmung" still ground a
    /// candidate "Dokumentation abstimmen".
    static func isGroundedInTranscript(_ text: String, transcriptLower: String) -> Bool {
        let tokens = text
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 4 }
        // No meaningful tokens to validate — give the candidate the
        // benefit of the doubt rather than reject blindly.
        guard !tokens.isEmpty else { return true }
        return tokens.contains { transcriptLower.contains($0) }
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
        let segments = dir.appending(path: "segments", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: segments,
                                                withIntermediateDirectories: true)
        // iOS file protection is per-file, not inherited from the
        // parent at directory-creation time, so we have to tag every
        // new node we create. Without this the recording dies the
        // moment the device locks: writes return -40 and the next
        // segment open returns -54.
        LocalStore.applyProtection(to: dir)
        LocalStore.applyProtection(to: segments)
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
            drive_by_seeds_surfaced: surfacedNoteIDs,
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
                // No per-second Live Activity push — the widget renders
                // its counter via `Text(timerInterval:)` from
                // `state.startedAt`, which the hub re-bases each time we
                // sync. Pushing every second only burned the system's
                // activity-update budget and made the digit *more*
                // likely to freeze on the lock screen.
            }
        }
    }

    // MARK: - UI helpers (consumed by WalkthroughView) -----------------

    /// Title shown in the page header for the current state. The view
    /// previously poked into `events[currentIndex]` directly; that still
    /// works for calendar events, but generals + note need their own
    /// labels. Falls back to the generic "Abend".
    public var currentSectionTitle: String? {
        switch state {
        case .generalOpener(_, let id), .generalListening(_, let id):
            return WalkthroughSettingsStore.generals.first { $0.id == id }?.title
        case .noteReview:
            // `confirmationLanguage` mirrors the per-utterance language
            // detection during a live session; outside of that the
            // section header should match the *app* language, not
            // whichever language the last opener happened to be in. We
            // therefore route through `String(localized:)` so the
            // catalog answers based on AppLanguage.
            return String(localized: "Notes")
        case .voiceNoteOpener, .voiceNoteListening:
            return String(localized: "Day close")
        default:
            return nil
        }
    }

    /// The note currently rendered by `NoteReviewCard`, plus its
    /// 1-based index and total. `nil` outside `.noteReview`.
    public var currentNote: (note: VoiceNote, index: Int, total: Int)? {
        guard case .noteReview(let stepIdx, let noteIdx) = state,
              stepIdx >= 0, stepIdx < plan.count,
              case .voiceNote(let notes) = plan[stepIdx],
              noteIdx >= 0, noteIdx < notes.count
        else { return nil }
        return (notes[noteIdx], noteIdx + 1, notes.count)
    }

    /// "Verwerfen" wake-word on the per-note review step. Drops the
    /// current note from this session's manifest AND marks it surfaced
    /// so it doesn't re-appear in the next walkthrough. The audio file
    /// itself is kept on disk — the user's recording isn't deleted by
    /// a stray voice command. Advances to the next note (or the
    /// closing question) on completion.
    public func dropCurrentNote(language: OpenerLanguage = .current) async {
        await withTransition {
            // stopNotePlayback() is load-bearing here: must halt any
            // in-progress note audio before the state guard runs so we
            // don't leave a dangling player when the guard returns early.
            stopNotePlayback()

            guard case .noteReview(let stepIdx, let noteIdx) = state,
                  stepIdx >= 0, stepIdx < plan.count,
                  case .voiceNote(let notes) = plan[stepIdx],
                  noteIdx >= 0, noteIdx < notes.count
            else { return }

            let dropped = notes[noteIdx]
            droppedNoteIDs.insert(dropped.seed_id)
            Log.app.info("note dropped: \(dropped.seed_id, privacy: .public)")
            recordAiPrompt(role: "note_dropped",
                           segmentID: "s\(zeroPad(stepIdx + 1))",
                           text: dropped.transcript)

            interruptInFlight = true
            await cancelTTS()
            let next = noteIdx + 1
            if next < notes.count {
                await runNoteReview(stepIndex: stepIdx, noteIndex: next,
                                    notes: notes, language: language)
            } else {
                await runVoiceNoteClosing(stepIndex: stepIdx, notes: notes, language: language)
            }
        }
    }

    /// "Nochmal" / "Replay" wake-word on the per-note review step.
    /// Re-plays the current note's audio and re-opens the wake-word
    /// window once playback completes. Same code path the AI runs the
    /// first time a note is surfaced — kept as one method so the
    /// timing logic stays in one place.
    public func replayCurrentNote(language: OpenerLanguage = .current) async {
        wakeWordTask?.cancel(); wakeWordTask = nil
        isWakeListening = false
        guard case .noteReview(let stepIdx, let noteIdx) = state,
              stepIdx >= 0, stepIdx < plan.count,
              case .voiceNote(let notes) = plan[stepIdx],
              noteIdx >= 0, noteIdx < notes.count
        else { return }
        await playNoteAndListen(note: notes[noteIdx], language: language)
    }

    /// "Ändern" / "Rerecord" wake-word on the per-note review step.
    /// MVP: drops the original note (so the user isn't stuck with an
    /// outcome they explicitly rejected) and speaks a short hint
    /// telling them to use the Aufnahme tab for the replacement. The
    /// original audio file stays on disk, matching the `verwerfen`
    /// "keep audio" semantics — so the user can always recover it.
    /// In-walkthrough re-recording (start a fresh segment capture,
    /// transcribe inline, splice the new note back into the entry) is
    /// out of scope here and tracked as a follow-up slice.
    public func rerecordCurrentNote(language: OpenerLanguage = .current) async {
        await withTransition {
            // stopNotePlayback() must run before the state guard (see
            // dropCurrentNote comment above for why).
            stopNotePlayback()

            guard case .noteReview(let stepIdx, let noteIdx) = state,
                  stepIdx >= 0, stepIdx < plan.count,
                  case .voiceNote(let notes) = plan[stepIdx],
                  noteIdx >= 0, noteIdx < notes.count
            else { return }

            let dropped = notes[noteIdx]
            droppedNoteIDs.insert(dropped.seed_id)
            Log.app.info("note rerecord requested → note \(dropped.seed_id, privacy: .public) dropped, user redirected to Aufnahme tab")
            recordAiPrompt(role: "note_rerecord_requested",
                           segmentID: "s\(zeroPad(stepIdx + 1))",
                           text: dropped.transcript)

            interruptInFlight = true
            await cancelTTS()
            let hint = language == .de
                ? "Verworfen. Du kannst sie über den Aufnahme-Tab neu aufzeichnen."
                : "Discarded. You can re-record it via the Aufnahme tab."
            await speak(hint, language: language.rawValue)

            // Re-enter runNoteReview only if state is still .noteReview —
            // a parallel X tap or auto-advance during the TTS could have
            // moved us already.
            guard case .noteReview = state else { return }
            let next = noteIdx + 1
            if next < notes.count {
                await runNoteReview(stepIndex: stepIdx, noteIndex: next,
                                    notes: notes, language: language)
            } else {
                await runVoiceNoteClosing(stepIndex: stepIdx, notes: notes, language: language)
            }
        }
    }

    /// "Für später aufheben" on the per-note review card. Marks the
    /// current note as deferred — it won't be attached to this
    /// walkthrough's manifest and won't be flagged surfaced, so the
    /// next walkthrough re-offers it. Then advances to the next note
    /// (or to the closing question when this was the last). Used only
    /// on orphan notes (older than the diary day); same-day notes
    /// always fold into the session via the regular Weiter path.
    public func saveCurrentNoteForLater(language: OpenerLanguage = .current) async {
        await withTransition {
            // stopNotePlayback() must run before the state guard (see
            // dropCurrentNote comment above for why).
            stopNotePlayback()

            guard case .noteReview(let stepIdx, let noteIdx) = state,
                  stepIdx >= 0, stepIdx < plan.count,
                  case .voiceNote(let notes) = plan[stepIdx],
                  noteIdx >= 0, noteIdx < notes.count
            else { return }

            deferredNoteIDs.insert(notes[noteIdx].seed_id)

            interruptInFlight = true
            await cancelTTS()
            let next = noteIdx + 1
            if next < notes.count {
                await runNoteReview(stepIndex: stepIdx, noteIndex: next,
                                    notes: notes, language: language)
            } else {
                await runVoiceNoteClosing(stepIndex: stepIdx, notes: notes, language: language)
            }
        }
    }

    /// Look up the transcript of an already-finalised segment. Used by
    /// `TodoConfirmationCard` to render the 5-line excerpt around the
    /// matched todo phrase. Returns `nil` if the segment_id isn't known
    /// (e.g. the per-segment finalisation task hasn't completed yet) or
    /// if the segment carries no transcript.
    public func transcript(forSegmentID id: String) -> String? {
        guard let idx = segmentByID[id], idx < segments.count else { return nil }
        let text: String
        switch segments[idx] {
        case .calendarEvent(let s):   text = s.transcript
        case .voiceNote(let s):         text = s.transcript
        case .freeReflection(let s):  text = s.transcript
        case .emptyBlock(let s):      text = s.transcript
        case .generalSection(let s):  text = s.transcript
        }
        return text.isEmpty ? nil : text
    }

    /// Number of unsurfaced notes the current note step will (or
    /// did) walk the user through. Read by the WalkthroughView header
    /// to keep the breadcrumb dot count consistent across the per-note
    /// review steps and the closing question step that follows.
    public var plannedNoteCount: Int {
        let stepIdx: Int? = {
            switch state {
            case .noteReview(let s, _),
                 .voiceNoteOpener(let s),
                 .voiceNoteListening(let s):
                return s
            default:
                return nil
            }
        }()
        guard let i = stepIdx, i >= 0, i < plan.count,
              case .voiceNote(let notes) = plan[i] else { return 0 }
        return notes.count
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
    //
    // Routed through `LiveActivityHub`: the hub arbitrates with
    // `CaptureCoordinator`'s drive-by activity so we never stack two of
    // the same type, and it re-bases `startedAt` from `elapsedSeconds`
    // so the widget's self-incrementing `Text(timerInterval:)` shows
    // the right offset on every push (including pause→resume).

    private var liveActivityKind: CaptureActivityAttributes.Kind? {
        switch state {
        case .briefing, .eventOpener, .generalOpener, .voiceNoteOpener: return .speaking
        case .eventListening, .generalListening, .voiceNoteListening:   return .listening
        case .confirmingTodos:                                        return .listening
        // Note review is silent visual; the note's intro line plays
        // briefly on the first card and Live Activity tracks the
        // walkthrough as a whole, so .speaking matches the rest.
        case .noteReview:                                             return .speaking
        case .idle, .ingesting, .done, .failed:                       return nil
        }
    }

    private func syncLiveActivity() {
        guard let kind = liveActivityKind else {
            Task { await endLiveActivity() }
            return
        }
        // Counter shows the *current segment's* elapsed seconds (mirror
        // of the in-app `ListeningTimer`). During speaking states we
        // send 0 so the widget doesn't suggest the user is being timed
        // while the AI has the floor.
        let elapsed = (kind == .speaking) ? 0 : self.elapsedSeconds
        let paused = self.isPaused
        Task {
            await LiveActivityHub.shared.sync(
                owner: .walkthrough,
                kind: kind,
                elapsedSeconds: elapsed,
                isPaused: paused
            )
        }
    }

    private func endLiveActivity() async {
        await LiveActivityHub.shared.end(owner: .walkthrough)
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

    /// Speak a multi-language script, routing each span to the engine
    /// that owns its language. Used for event openers where a German
    /// frame can wrap an English meeting title (or vice versa).
    ///
    /// Cancellation: between spans we check the ambient `Task` for
    /// cancellation, so a manual advance / X-tap mid-opener stops the
    /// remaining spans from playing. The active span itself isn't
    /// pre-empted — the per-engine `cancel()` path (called via
    /// `cancelTTS()`) handles that, same as for single-string speak.
    private func speak(script: [SpokenSpan]) async {
        let spans = script.coalesced()
        guard !spans.isEmpty else { return }
        isSpeaking = true
        silenceLevel = 0
        defer { isSpeaking = false }
        for span in spans {
            // `interruptInFlight` is the project's actual abort signal —
            // `cancel()` sets it before tearing TTS down. `Task.isCancelled`
            // alone isn't enough because this loop runs inside the actor's
            // own call chain, not a cancellable Task: the *current* span's
            // engine.speak() gets silenced by cancelTTS(), but without
            // this check the loop would proceed to the next span (e.g. an
            // English title after a German intro is cancelled).
            if Task.isCancelled || interruptInFlight { return }
            await VoiceRegistry.engine(for: span.language)
                .speak(span.text, language: span.language)
        }
    }

    // MARK: - Opener composition (LLM-prepared, SPEC §11) --------------

    /// Compose the spoken opener for one calendar event, caching the
    /// result per segment so the prefetch synth and the live
    /// record/`lastSpoken` path use byte-identical text. Concurrent
    /// callers for the same segment dedupe onto a single FM call.
    private func eventOpenerSpans(
        event: ServerCalendarEvent,
        index: Int,
        total: Int,
        segmentID: String,
        language: OpenerLanguage
    ) async -> [SpokenSpan] {
        // The cache check and the task lookup run with no `await` between
        // them, so on the MainActor they're atomic w.r.t. other tasks.
        if let cached = openerScriptCache[segmentID] { return cached }
        if let task = openerTextTasks[segmentID] { return await task.value }
        let task = Task<[SpokenSpan], Never> { [weak self] in
            guard let self else { return [] }
            return await self.generateEventOpenerSpans(
                event: event, index: index, total: total, language: language
            )
        }
        openerTextTasks[segmentID] = task
        let spans = await task.value
        // Set cache *before* clearing the task so a brand-new caller that
        // arrives in this window still finds either the cache or the task.
        openerScriptCache[segmentID] = spans
        openerTextTasks.removeValue(forKey: segmentID)
        return spans
    }

    /// Try Apple FM for a varied, day-aware opener; fall back to the
    /// deterministic template (already spoken-time safe, and the only
    /// path that keeps mixed-language title voice routing) on any failure.
    private func generateEventOpenerSpans(
        event: ServerCalendarEvent,
        index: Int,
        total: Int,
        language: OpenerLanguage
    ) async -> [SpokenSpan] {
        let fallback = OpenerTemplates.scriptLine(
            for: event, index: index, of: total, language: language
        )
        let slot = OpenerTemplates.slot(
            for: event,
            positionInDay: OpenerTemplates.position(of: index, count: total)
        )
        let ctx = EventOpenerContext(
            title: event.subject,
            attendees: event.attendees.map(\.name),
            spokenTime: OpenerTemplates.spokenTime(event.startDate, language: language),
            spokenTimeRange: OpenerTemplates.spokenTimeRange(
                event.startDate, event.endDate, language: language
            ),
            durationText: OpenerTemplates.spokenDuration(event.durationMinutes, language: language),
            isRecurring: event.is_recurring,
            isExternal: event.hasExternalAttendee,
            agendaPreview: event.body_preview,
            position: Self.positionString(index: index, total: total),
            slot: slot.rawValue
        )
        do {
            let line = try await DialogLLMResolver.current().generateEventOpener(
                context: ctx, language: language.rawValue
            )
            // Route the whole opener to the dominant language's voice. FM
            // answers in `language` (assertLanguage-enforced), so this is
            // normally the base voice; an embedded foreign title is read
            // by that same voice — the accepted trade-off for LLM openers
            // vs the template's per-span routing.
            let voice = LanguageDetector.detect(line) ?? language.rawValue
            Diag.log("eventOpener: FM line ok (\(line.count) chars)")
            return [SpokenSpan(text: line, language: voice)]
        } catch {
            Diag.log("eventOpener: FM fallback → template (\(error))")
            return fallback
        }
    }

    private static func positionString(index: Int, total: Int) -> String {
        switch OpenerTemplates.position(of: index, count: total) {
        case .first:  return "first"
        case .last:   return "last"
        case .middle: return "middle"
        }
    }

    // MARK: - Opener prefetch -----------------------------------------

    /// Speak the opener for `segmentID`. Uses the cached prefetched
    /// script when available (reaped from `prefetchedOpeners` /
    /// `prefetchTasks`), otherwise falls back to a live speak of
    /// `fallbackSpans` — same end behaviour as `speak(script:)` so the
    /// non-prefetch path is bit-identical to before.
    ///
    /// Mirrors the visible state semantics of `speak(script:)`:
    /// `isSpeaking` flips on for the duration; `silenceLevel` is
    /// cleared at entry so the AI's voice always wins over a stale
    /// "Stille seit Xs" indicator. Cancellation between utterances
    /// matches `speak(script:)`'s behaviour — the per-span
    /// `Task.isCancelled` check is the same one used there.
    private func speakOpenerScript(
        segmentID: String,
        fallbackSpans: [SpokenSpan]
    ) async {
        if let prefetched = await consumePrefetched(segmentID: segmentID),
           !prefetched.isEmpty {
            Diag.log(
                "speakOpener: prefetched cache hit \(segmentID), \(prefetched.utterances.count) utt"
            )
            isSpeaking = true
            silenceLevel = 0
            defer { isSpeaking = false }
            for utt in prefetched.utterances {
                // Mirror the `speak(script:)` guard — see comment there
                // for the full rationale. `interruptInFlight` is what
                // `cancel()` actually toggles; `Task.isCancelled` won't
                // fire because this runs inside the actor's call chain.
                if Task.isCancelled || interruptInFlight { return }
                await VoiceRegistry.engine(for: utt.language).play(utt)
            }
            return
        }
        Diag.log("speakOpener: live speak \(segmentID)")
        await speak(script: fallbackSpans)
    }

    /// Resolve the segment ID + a span provider for a given plan
    /// position. Returns `nil` if the position is out of range or has no
    /// spoken opener (e.g. a general section whose intro text is empty).
    /// The segment ID matches the keys used in `runEvent` / `runGeneral`
    /// / `runVoiceNotes` so prefetch + consume share the same map.
    ///
    /// Calendar openers are now LLM-prepared, so the provider is `async`
    /// and routes through `eventOpenerSpans` (shared cache → identical
    /// text on the live path). General / note openers are fixed strings,
    /// so their provider just returns them.
    ///
    /// `eventIndex == nil` for non-calendar steps (general /
    /// note) means "the step's single opener". For calendar
    /// steps, `nil` means "the first event in the block".
    private func openerProviderForPrefetch(
        stepIndex: Int,
        eventIndex: Int?,
        language: OpenerLanguage
    ) -> (segmentID: String, provider: @MainActor () async -> [SpokenSpan])? {
        guard stepIndex >= 0, stepIndex < plan.count else { return nil }
        switch plan[stepIndex] {
        case .calendar(let evts):
            let i = eventIndex ?? 0
            guard i < evts.count else { return nil }
            let segID = makeEventSegmentID(stepIndex: stepIndex, eventIndex: i)
            let evt = evts[i]
            let total = evts.count
            let provider: @MainActor () async -> [SpokenSpan] = { [weak self] in
                await self?.eventOpenerSpans(
                    event: evt, index: i, total: total,
                    segmentID: segID, language: language
                ) ?? []
            }
            return (segID, provider)
        case .general(let section):
            let line = section.introText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { return nil }
            let segID = "s\(zeroPad(stepIndex + 1))"
            return (segID, { [SpokenSpan(text: line, language: language.rawValue)] })
        case .voiceNote:
            // Prefetch only the closing prompt. The per-note recap
            // intro ("Du hast heute N Notizen…") is spoken directly in
            // `runNoteReview` at note 0 via `speak()`; bundling it here
            // too made `runVoiceNoteClosing` replay it after the notes.
            let segID = "s\(zeroPad(stepIndex + 1))"
            let closing = OpenerTemplates.closingPrompt(language: language)
            return (segID, { [SpokenSpan(text: closing, language: language.rawValue)] })
        }
    }

    /// Spawn a background prefetch task for a specific upcoming
    /// opener. No-op when a prefetch (in-flight or completed) already
    /// exists for this segment, or when the position has no opener
    /// to speak. The Task first resolves the opener text (FM for calendar
    /// events), then synthesises each span via the appropriate engine's
    /// `prefetch(_:language:)`; same-language adjacent spans coalesce so
    /// the synth runs once per language bucket. Running on the MainActor
    /// is fine: both the FM call and the synth `await` off-actor.
    private func prefetchOpener(
        stepIndex: Int,
        eventIndex: Int?,
        language: OpenerLanguage
    ) {
        guard let (segmentID, provider) = openerProviderForPrefetch(
            stepIndex: stepIndex,
            eventIndex: eventIndex,
            language: language
        ) else { return }
        guard prefetchedOpeners[segmentID] == nil,
              prefetchTasks[segmentID] == nil else { return }
        Diag.log("prefetchOpener: queued \(segmentID)")
        let task: Task<PrefetchedScript?, Never> = Task { @MainActor in
            let coalesced = (await provider()).coalesced()
            if coalesced.isEmpty || Task.isCancelled { return nil }
            var utts: [PrefetchedUtterance] = []
            for span in coalesced {
                if Task.isCancelled { return nil }
                let utt = await VoiceRegistry
                    .engine(for: span.language)
                    .prefetch(span.text, language: span.language)
                utts.append(utt)
            }
            if Task.isCancelled { return nil }
            return PrefetchedScript(segmentID: segmentID, utterances: utts)
        }
        prefetchTasks[segmentID] = task
        Task { [weak self] in
            let result = await task.value
            await MainActor.run { [weak self] in
                guard let self else { return }
                // The session may have been cancelled or restarted
                // before this resolved; in that case our prefetchTasks
                // entry will already have been cleared by
                // clearPrefetchedOpeners(), and we shouldn't resurrect
                // it. Only stash the result if the slot still exists.
                guard self.prefetchTasks[segmentID] != nil else {
                    if let script = result {
                        for utt in script.utterances {
                            VoiceRegistry.engine(for: utt.language).discard(utt)
                        }
                    }
                    return
                }
                self.prefetchTasks.removeValue(forKey: segmentID)
                if let script = result {
                    self.prefetchedOpeners[segmentID] = script
                    Diag.log("prefetchOpener: ready \(segmentID)")
                } else {
                    Diag.log("prefetchOpener: cancelled \(segmentID)")
                }
            }
        }
    }

    /// Convenience: prefetch the opener for "the step after the one
    /// we're currently in." Calendar blocks expand into per-event
    /// prefetches; the boundary case (last event in a calendar block)
    /// hops to the next plan step's first opener.
    private func prefetchNextOpener(
        afterStep currentStep: Int,
        eventIndex: Int?,
        language: OpenerLanguage
    ) {
        if let eIdx = eventIndex,
           currentStep < plan.count,
           case .calendar(let evts) = plan[currentStep],
           eIdx + 1 < evts.count {
            prefetchOpener(stepIndex: currentStep, eventIndex: eIdx + 1, language: language)
            return
        }
        prefetchOpener(stepIndex: currentStep + 1, eventIndex: nil, language: language)
    }

    /// First-step prefetch used at session start. Hides the Piper
    /// synth pass behind the opening intro's playback time.
    private func prefetchFirstOpener(language: OpenerLanguage) {
        guard !plan.isEmpty else { return }
        prefetchOpener(stepIndex: 0, eventIndex: nil, language: language)
    }

    /// Session-start pre-generation, two-tier.
    ///
    /// Tier 1 — fire the **very first** opener prefetch alone. While
    /// the briefing intro plays the user is about to hear this one
    /// next, so any delay here is the delay they perceive. The LLM
    /// actor would process event 0 first anyway, but `PiperTTS.prefetch`
    /// is direct (not serial-queued) and N concurrent synths share
    /// CPU — meaning fanning out 5+ prefetches at once measurably
    /// slows event 0's synth. Giving it exclusive CPU + LLM time
    /// during the briefing closes that gap.
    ///
    /// Tier 2 — once event 0's text + audio are cached, fire every
    /// other opener and every note summary. By the time the user has
    /// finished the first event's reflection, the rest of the day's
    /// LLM work has already happened in the background.
    ///
    /// If the user backgrounds the app mid-prefetch, `GemmaDialogLLM`
    /// suspends and any not-yet-generated opener falls through to
    /// Apple FM via `ChainDialogLLM`. Already-cached openers replay
    /// from their pre-rendered audio without touching the model.
    private func prefetchAllOpeners(language: OpenerLanguage) {
        guard !plan.isEmpty else { return }

        // Tier 1: just the first opener.
        prefetchOpener(stepIndex: 0, eventIndex: 0, language: language)

        // Tier 2: trampoline that waits for the first prefetch to land,
        // then fans out the rest. Spawned on the MainActor so it
        // inherits this actor's isolation and can read the prefetch
        // task map safely. `prefetchOpener` is internally dedup'd, so
        // calling it again for event 0 inside the fan-out is a no-op.
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.waitForFirstPrefetch()
            self.prefetchRemainingOpeners(language: language)
            self.prefetchAllNoteSummaries(language: language)
        }
    }

    /// Block on the first opener's prefetch task value. Both the
    /// completed map and the in-flight task map are consulted; either
    /// match returns. The caller doesn't *need* the script, just the
    /// fact that the work is done so the rest can fire without
    /// stealing CPU from it.
    private func waitForFirstPrefetch() async {
        guard !plan.isEmpty else { return }
        let segID: String
        switch plan[0] {
        case .calendar(let evts):
            guard !evts.isEmpty else { return }
            segID = makeEventSegmentID(stepIndex: 0, eventIndex: 0)
        case .general, .voiceNote:
            segID = "s\(zeroPad(1))"
        }
        if prefetchedOpeners[segID] != nil { return }
        if let task = prefetchTasks[segID] {
            _ = await task.value
        }
    }

    /// Fan-out for the deferred tier. `prefetchOpener`'s internal
    /// dedup makes the first-opener call a no-op, so we don't need a
    /// special case to skip it.
    private func prefetchRemainingOpeners(language: OpenerLanguage) {
        for (stepIdx, step) in plan.enumerated() {
            switch step {
            case .calendar(let evts):
                for evtIdx in 0..<evts.count {
                    prefetchOpener(stepIndex: stepIdx, eventIndex: evtIdx, language: language)
                }
            case .general, .voiceNote:
                prefetchOpener(stepIndex: stepIdx, eventIndex: nil, language: language)
            }
        }
    }

    /// Session-start pre-generation of every note summary. Notes are
    /// captured earlier in the day, so their transcripts are already
    /// on disk at session start — meaning `summarizeNote` is
    /// deterministic from data we have. Pre-running it caches one
    /// summary per note keyed by `VoiceNote.id`; the per-note review
    /// later reads the cache instead of hitting the LLM mid-walkthrough.
    /// Now deferred to the second tier so it doesn't compete with the
    /// first opener's LLM call.
    private func prefetchAllNoteSummaries(language: OpenerLanguage) {
        for step in plan {
            if case .voiceNote(let notes) = step {
                for note in notes {
                    Task { [weak self] in
                        _ = await self?.cachedNoteSummary(note, language: language)
                    }
                }
            }
        }
    }

    /// Resolve a prefetched script for `segmentID`, awaiting the
    /// in-flight task if it hasn't completed yet (so a partial
    /// prefetch still delivers its head start). Removes the entry
    /// from both the in-flight map and the completed map so each
    /// prefetched script is consumed exactly once.
    private func consumePrefetched(segmentID: String) async -> PrefetchedScript? {
        if let cached = prefetchedOpeners.removeValue(forKey: segmentID) {
            prefetchTasks.removeValue(forKey: segmentID)
            return cached
        }
        if let task = prefetchTasks.removeValue(forKey: segmentID) {
            let result = await task.value
            // Recheck the completed map: while we were awaiting, the
            // continuation Task in `prefetchOpener` may have written
            // the result there already.
            prefetchedOpeners.removeValue(forKey: segmentID)
            return result
        }
        return nil
    }

    /// Drop everything: cancel in-flight prefetches, discard cached
    /// WAVs from /tmp, clear both maps. Safe to call repeatedly.
    private func clearPrefetchedOpeners() {
        for (_, task) in prefetchTasks {
            task.cancel()
        }
        prefetchTasks.removeAll()
        for (_, script) in prefetchedOpeners {
            for utt in script.utterances {
                VoiceRegistry.engine(for: utt.language).discard(utt)
            }
        }
        prefetchedOpeners.removeAll()
        // Drop composed opener text too — a restarted session re-fetches
        // the calendar and must regenerate openers from scratch.
        for (_, task) in openerTextTasks { task.cancel() }
        openerTextTasks.removeAll()
        openerScriptCache.removeAll()
        // And the note summaries — they're keyed by note ID which is
        // stable across sessions, but a new session may surface a
        // different set of notes so a clean slate is the right default.
        for (_, task) in noteSummaryTasks { task.cancel() }
        noteSummaryTasks.removeAll()
        noteSummaryCache.removeAll()
    }

    // MARK: - Opening intro -------------------------------------------

    /// One-line opening intro spoken at the very start of the
    /// session. Calls out the date and the rough shape of the
    /// schedule so the user knows what's coming. The first event's
    /// opener follows naturally — no explicit "let's start with…"
    /// transition needed because the per-event opener already does
    /// that work in its own template.
    private func composeOpeningIntro(date: Date, language: OpenerLanguage) -> String {
        let formatter = DateFormatter()
        switch language {
        case .de:
            formatter.locale = Locale(identifier: "de_DE")
            // "d." not "dd." — Voxtral reads the leading-zero form ("04.")
            // as "null vier" instead of "vierter". Without the pad, "4. Mai"
            // is voiced naturally as "vierter Mai".
            formatter.dateFormat = "EEEE, d. MMMM"
            let dateStr = formatter.string(from: date)
            switch events.count {
            case 0: return "Heute ist \(dateStr). Lass uns kurz auf den Tag schauen."
            case 1: return "Heute ist \(dateStr). Wir gehen einen Termin durch."
            default: return "Heute ist \(dateStr). Wir gehen \(events.count) Termine durch."
            }
        case .en:
            formatter.locale = Locale(identifier: "en_US")
            formatter.dateFormat = "EEEE, MMMM d"
            let dateStr = formatter.string(from: date)
            switch events.count {
            case 0: return "Today is \(dateStr). Let's take a moment on the day."
            case 1: return "Today is \(dateStr). We'll walk through one meeting."
            default: return "Today is \(dateStr). We'll walk through \(events.count) meetings."
            }
        }
    }

    // MARK: - Voxtral preflight (slice 05b)

    private func hasVoxtralVoiceSelected() -> Bool {
        VoicePreferences.isVoxtralVoiceID(VoicePreferences.selectedVoiceID(for: "de"))
        || VoicePreferences.isVoxtralVoiceID(VoicePreferences.selectedVoiceID(for: "en"))
    }

    private func preflightVoxtral() async {
        do {
            let data = try await ServerClient.shared.health()
            let payload = try JSONDecoder().decode(VoxtralPreflightPayload.self, from: data)
            guard payload.upstream["voxtral"] == "down" else { return }
            let message = "Voxtral nicht erreichbar — Voxtral-Stimmen fallen heute auf Piper zurück."
            voxtralPreflightWarning = message
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            // Only clear if we still own the message (no other path overwrote it).
            if voxtralPreflightWarning == message {
                voxtralPreflightWarning = nil
            }
        } catch {
            // Network/parse failure: walkthrough proceeds normally and
            // the engine fallback policy handles per-utterance failure.
            // Surface only at debug level so the log doesn't get noisy.
            Log.app.debug("voxtral preflight skipped: \(String(describing: error), privacy: .public)")
        }
    }

    private struct VoxtralPreflightPayload: Decodable {
        let upstream: [String: String]
    }

    /// Cancel any in-flight playback. Broadcasts to all three engines
    /// because we don't track which one spoke the most recent line —
    /// and calling `cancel()` on an idle engine is a cheap no-op. This
    /// matters when the user switches engines mid-walkthrough, when
    /// Voxtral has fallen back to Piper, or when the user taps X
    /// during the network round-trip: the previous engine's queued
    /// utterance and any in-flight HTTP request must both be silenced
    /// even though the *next* `speak(_:language:)` will resolve to a
    /// different engine.
    private func cancelTTS() async {
        await AppleSpeechTTS.shared.cancel()
        await PiperTTS.shared.cancel()
        await VoxtralTTS.shared.cancel()
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
    /// `finishCurrentSection()` on a match or closes the window after ~5 s
    /// without one. Idempotent on cancellation: if the parent Task is
    /// cancelled mid-window the streaming ASR is torn down and the
    /// fan-out sink is cleared.
    /// Outcome of one wake-word window. Lets callers (note review)
    /// distinguish "the user stayed silent" (auto-advance) from "the
    /// window never opened" (wake-word off / asset missing → leave the
    /// card up for a manual Weiter) from "a command was matched and
    /// already dispatched here" (do nothing further).
    private enum WakeWindowOutcome {
        case matched(WakeWordDetector.Action)
        case timedOut
        case skipped
    }

    @discardableResult
    private func runWakeWordWindow(language: OpenerLanguage) async -> WakeWindowOutcome {
        // Don't keep the window open across a state change. If the
        // user already advanced manually (or the X tap moved us to
        // .idle) we just bail.
        guard isInListeningState else {
            Diag.log("wake-word: aborted, not in listening state")
            wakeWordTask = nil
            return .skipped
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
            return .skipped
        }
        guard AppleStreamingRecognizer.supportsOnDeviceRecognition(language: language.rawValue) else {
            Diag.log("wake-word: skipped — on-device asset not installed for \(language.rawValue)")
            wakeWordTask = nil
            return .skipped
        }

        // Pick the backend by active language. The streaming Parakeet
        // model is English-only; German falls back to Apple's
        // on-device SFSpeechRecognizer (which the Info.plist's
        // NSSpeechRecognitionUsageDescription gates).
        let asr: any StreamingASR
        let phrases: [WakeWordDetector.Phrase]
        // Note-review steps swap the base phrase table for the extended
        // one (adds drop / defer / replay / rerecord). The base table
        // stays for every other listening state so a "später" mid-
        // meeting can't accidentally defer something.
        let useNoteReviewPhrases: Bool = {
            if case .noteReview = state { return true }
            return false
        }()
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
                return .skipped
            }
            asr = AppleStreamingRecognizer()
            phrases = useNoteReviewPhrases
                ? WakeWordDetector.germanNoteReview
                : WakeWordDetector.german
        case .en:
            asr = FluidAudioStreaming()
            phrases = useNoteReviewPhrases
                ? WakeWordDetector.englishNoteReview
                : WakeWordDetector.english
        }

        // Match arrives via the detector's callback; we surface it as
        // an AsyncStream element. `finish()` from the timeout side
        // closes the loop without emitting an action.
        let (matchStream, matchContinuation) = AsyncStream<WakeWordDetector.Action>.makeStream()
        let detector = WakeWordDetector(phrases: phrases) { action, matched in
            // Piggy-back a resident-memory reading on the wake-word
            // advance log. This is the cardinal per-event boundary in
            // a walkthrough — printing memory here makes a slow-growth
            // leak across multiple events visible in the console
            // (e.g. "wake-word match … mem=412 MB" → "… mem=503 MB"
            // → "… mem=611 MB" tells us roughly +100 MB per event,
            // which is what tipped us into jetsam by the 5th meeting).
            Diag.log(
                "wake-word match: \(matched) → \(action.rawValue) mem=\(MemoryReport.formatted())"
            )
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
            return .skipped
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
            // Schedule the trim that keeps the matched command word
            // (`weiter` / `next` / etc.) out of the segment's transcript.
            // It was just spoken into the mic and is sitting at the end
            // of the M4A; without the trim it would show up verbatim in
            // both the client-side Parakeet transcript and the
            // server-side Whisper output. Prefer a precise head-keep cut
            // at the start of the silence run that preceded the command;
            // fall back to a fixed tail trim if that run start was
            // cleared (user resumed talking before saying the command).
            if let segID = currentRecordingSegmentID {
                if let runStart = silenceRunStartedAt,
                   let segStart = segmentRecordingStartedAt {
                    let keep = max(0, runStart.timeIntervalSince(segStart)
                                      + Self.wakeMatchKeepMarginSeconds)
                    wakeMatchTrim[segID] = .keepFirst(keep)
                } else {
                    wakeMatchTrim[segID] = .dropLast(Self.wakeMatchFallbackTailSeconds)
                }
            }
            switch action {
            case .advance:        await advance()
            case .finishSection:  await finishCurrentSection()
            case .pause:          await pause()
            case .dropNote:       await dropCurrentNote()
            case .deferNote:      await saveCurrentNoteForLater()
            case .replayNote:     await replayCurrentNote()
            case .rerecordNote:   await rerecordCurrentNote()
            }
            return .matched(action)
        }
        return .timedOut
    }

    /// True for any state where opening a wake-word window is
    /// meaningful: the three listening segment-capture states, the
    /// per-candidate todo-confirmation pass (`.confirmingTodos`), and
    /// the per-note review step (`.noteReview`). In todo confirmation
    /// a "weiter" match routes through `advance()` → `rejectCurrentTodo()`;
    /// in note review the extended phrase table also matches
    /// drop / defer / replay / rerecord. Used by `runWakeWordWindow`
    /// as a pre-flight to bail if the user already advanced before
    /// the lull callback fired.
    private var isInListeningState: Bool {
        switch state {
        case .eventListening, .generalListening, .voiceNoteListening,
             .confirmingTodos, .noteReview:
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

/// Bridges `AVAudioPlayerDelegate` (Obj-C protocol, can't be put on
/// an actor) to the Swift continuation used by
/// `playLastSeconds(of:seconds:)`. Both the natural finish and the
/// decode-error path resume the continuation so the caller never
/// hangs on a malformed m4a tail.
final class PickupPlaybackDelegate: NSObject, AVAudioPlayerDelegate {
    private let onFinish: @Sendable () -> Void
    init(onFinish: @escaping @Sendable () -> Void) {
        self.onFinish = onFinish
    }
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully _: Bool) {
        onFinish()
    }
    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error _: Error?) {
        onFinish()
    }
}
