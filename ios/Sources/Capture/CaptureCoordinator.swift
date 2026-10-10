@preconcurrency import ActivityKit
import AVFoundation
import Foundation
import SwiftUI
import UIKit
import WidgetKit

// Single source of truth for "is a note recording in progress?"
//
// The widget extension and the App Intent both need to observe and mutate
// this state. We use:
//   * `UserDefaults(suiteName: AppGroup.identifier)` for cross-process
//     persistence so the widget timeline can read it.
//   * `ActivityKit.Activity` for a Live Activity that the lock-screen
//     widget surfaces while a capture is running.
//
// The coordinator is `@MainActor`-isolated; the underlying `AudioEngine`
// is itself an actor so its work happens off the main thread regardless.
//
// `AppGroup` and `CaptureActivityAttributes` live in `Sources/Shared/`
// because they're consumed by both this target and the widget extension.
//
// Pause/resume model. A single drive-by "session" (one start … stop)
// produces N audio chunks, where N is 1 + number of pause→resume cycles.
// Each chunk is a complete M4A in `driveby_seeds/{ts}/`:
//   * chunk #1 → `audio.m4a` (legacy name preserved so older history rows
//                              keep working unchanged)
//   * chunk #2 → `audio_002.m4a`
//   * chunk #N → `audio_NNN.m4a`
// Pause finalises the current chunk and transcribes it; resume starts a
// fresh chunk file. Stop folds everything into the session's metadata.json
// as a `VoiceNote` whose `chunks: [VoiceNoteChunk]` lists each chunk's
// filename + transcript + duration.

@MainActor
@Observable
public final class CaptureCoordinator {
    public static let shared = CaptureCoordinator()

    public private(set) var isRecording: Bool = false
    /// True between `pause()` and the next `resume()` / `stop()` call.
    /// While paused: engine is stopped, the previous chunk has been
    /// finalised, the timer is frozen. Resume starts a new chunk; stop
    /// folds everything into one metadata record.
    public private(set) var isPaused: Bool = false
    public private(set) var startedAt: Date?
    public private(set) var elapsedSeconds: Int = 0
    public private(set) var statusLine: String = ""
    public private(set) var lastNote: VoiceNote?
    public private(set) var lastError: String?
    /// True when a system interruption (call / Siri / alarm) cut the
    /// recording short at any point in the current or just-finished
    /// session. Latched at pause/stop time because `AudioEngine` clears
    /// its own flag on the next `start()`. Surfaced as a banner by
    /// `CaptureView`; cleared by `start()` or `dismissInterruptionNotice()`.
    public private(set) var recordingWasInterrupted: Bool = false

    private let engine = AudioEngine()
    private var timer: Timer?

    /// Directory that holds every chunk's m4a + the final metadata.json
    /// for the current session. Survives pause/resume cycles; reset on
    /// stop.
    private var sessionDir: URL?
    /// File the AudioEngine is actively writing into, or nil when paused
    /// / stopped.
    private var currentAudioURL: URL?
    /// Wall-clock start of the currently-recording chunk. Used to compute
    /// per-chunk duration on pause / stop without relying on the
    /// elapsed-seconds tick (which is paused alongside).
    private var currentChunkStartedAt: Date?
    /// Finalised chunks captured so far in this session — each tuple is
    /// the file URL, its Parakeet transcript (nil if transcription failed
    /// or skipped), and the chunk's duration in seconds. Stop folds these
    /// plus the still-recording chunk (if any) into the metadata.
    private struct StoredChunk {
        let url: URL
        let transcript: ParakeetManager.Transcript?
        let duration: Double
    }
    private var chunks: [StoredChunk] = []

    /// Correlation ID for the current drive-by recording. Stamped onto
    /// boundary-marker log lines so the Diagnostics view can isolate
    /// every event that belongs to one session. Reset to `nil` on stop.
    private var sessionID: UUID?

    public init() {
        // Hydrate from any leftover state in shared defaults (e.g. if a
        // crash left isRecording=true).
        if let defaults = UserDefaults(suiteName: AppGroup.identifier),
           defaults.bool(forKey: AppGroup.recordingActiveKey) {
            // Don't trust the previous run's "is recording"; reset it.
            defaults.set(false, forKey: AppGroup.recordingActiveKey)
        }
        // Sweep any orphan Live Activity left on the lock screen from a
        // previous run that was killed mid-recording. Without this the
        // banner would persist until the user dismissed it manually, and
        // the next `start()` would stack a second activity on top.
        Task { await LiveActivityHub.shared.rehydrate() }
    }

    /// Called from `App.scenePhase == .active` so an activity that
    /// outlived a backgrounded-then-resumed launch cycle is reclaimed
    /// before the user interacts. Idempotent.
    public func reclaimLiveActivityIfNeeded() async {
        await LiveActivityHub.shared.rehydrate()
    }

    // --- toggle --------------------------------------------------------

    /// Idempotent toggle used by the App Intent. Returns the new state.
    /// Pause/resume are *not* part of toggle — they have their own
    /// dedicated `pause()` / `resume()` methods and a dedicated button
    /// in the recording UI.
    @discardableResult
    public func toggle() async -> Bool {
        if isRecording { await stop() } else { await start() }
        return isRecording
    }

    public func start() async {
        guard !isRecording else { return }
        lastError = nil
        statusLine = ""
        recordingWasInterrupted = false
        let sid = UUID()
        self.sessionID = sid
        Diag.log(session: sid, "capture.start mem=\(MemoryReport.formatted())")
        do {
            let dir = try LocalStore.voiceNotesDir()
                .appending(path: ISO8601DateFormatter().string(from: Date()),
                           directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let audio = dir.appending(path: "audio.m4a")
            // Pre-arm the AVAudioSession before `engine.start()`. When
            // the note trigger originates from the lock-screen widget
            // / Action Button, `start()` runs as the app is just being
            // foregrounded — calling `setCategory(.playAndRecord)` on a
            // not-yet-fully-active scene reliably hits
            // `Failed to set properties, error: '!int'`. Pre-arming
            // configures the session idempotently and tolerates being
            // called when the category is already set.
            try await engine.prepareSession()
            try await engine.start(outputURL: audio)
            let now = Date()
            sessionDir = dir
            currentAudioURL = audio
            currentChunkStartedAt = now
            chunks = []
            startedAt = now
            isRecording = true
            isPaused = false
            elapsedSeconds = 0
            startTimer()
            persistRecordingState(active: true, startedAt: now)
            await syncLiveActivity()
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            // Audible "recording started" cue so the user gets confirmation
            // even hands-off / screen-off (Action Button, lock screen). All
            // capture triggers funnel through this single start(), so one
            // call covers every entry point.
            WakePing.shared.playCaptureStart()
        } catch {
            lastError = CaptureErrorMessage.message(for: error, context: .start)
            persistRecordingState(active: false, startedAt: nil)
            Diag.log(session: sid, "capture.start.failed err=\(String(describing: error))")
            self.sessionID = nil
        }
    }

    /// Pause the current recording. Finalises the in-flight m4a as a
    /// complete chunk (so the audio captured up to this point is safe
    /// even if the user later kills the app) and transcribes it via
    /// Parakeet. Resume picks up with a fresh chunk file in the same
    /// session directory.
    public func pause() async {
        guard isRecording, !isPaused else { return }
        timer?.invalidate(); timer = nil
        let chunkStart = currentChunkStartedAt ?? startedAt ?? Date()
        let chunkURL = currentAudioURL
        let chunkDuration = Date().timeIntervalSince(chunkStart)
        Diag.log(session: sessionID, "capture.pause chunkIdx=\(chunks.count) dur=\(Int(chunkDuration))s mem=\(MemoryReport.formatted())")
        do {
            _ = try await engine.stop()
        } catch {
            // Pause is best-effort — if the engine wasn't in a
            // stoppable state we still want to flip into the paused UI
            // so the user can resume cleanly.
            Log.audio.warning(
                "drive-by pause engine stop: \(String(describing: error), privacy: .public)"
            )
        }
        await latchInterruption()
        if let url = chunkURL {
            // Verify the chunk file is present and non-empty before
            // appending — if `engine.stop()` failed above the writer
            // may not have finalised and the file could be absent or
            // zero-byte. Appending a phantom chunk would cause `stop()`
            // to write a metadata.json pointing at a file that doesn't
            // exist (or is unplayable), making the session invisible in
            // history.
            let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if fileSize > 0 {
                var transcript: ParakeetManager.Transcript?
                do {
                    transcript = try await ParakeetManager.shared.transcribe(audioURL: url)
                } catch {
                    Log.audio.warning(
                        "drive-by chunk transcribe skipped: \(String(describing: error), privacy: .public)"
                    )
                }
                chunks.append(StoredChunk(url: url, transcript: transcript, duration: chunkDuration))
            } else {
                Diag.log(session: sessionID, "capture.pause.dropChunk reason=zero_or_missing url=\(url.lastPathComponent)")
            }
        }
        currentAudioURL = nil
        currentChunkStartedAt = nil
        isPaused = true
        statusLine = String(localized: "Paused")
        // Two presentations for paused state, gated by user preference:
        //   off (default) — end the banner so the lock screen + Dynamic
        //                   Island free up while the user is stepped
        //                   away from the flow.
        //   on            — push a paused snapshot so the banner stays
        //                   on-screen as a one-tap shortcut back into
        //                   the dedicated capture screen.
        if LockScreenPreferences.showWhenPaused {
            await syncLiveActivity()
        } else {
            await endLiveActivity()
        }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    /// Resume after `pause()`. Starts a fresh chunk file in the same
    /// session directory and re-arms the timer.
    public func resume() async {
        guard isRecording, isPaused else { return }
        guard let dir = sessionDir else {
            // Session dir went missing somehow — bail without flipping
            // state so the user can stop cleanly.
            Diag.log(session: sessionID, "capture.resume.failed reason=missing_session_dir")
            return
        }
        let nextIndex = chunks.count + 1  // chunks[0] was audio.m4a; next is audio_002.m4a
        let filename = String(format: "audio_%03d.m4a", nextIndex)
        let url = dir.appending(path: filename)
        Diag.log(session: sessionID, "capture.resume chunkIdx=\(nextIndex) mem=\(MemoryReport.formatted())")
        do {
            try await engine.prepareSession()
            try await engine.start(outputURL: url)
        } catch {
            lastError = CaptureErrorMessage.message(for: error, context: .resume)
            return
        }
        currentAudioURL = url
        currentChunkStartedAt = Date()
        isPaused = false
        statusLine = ""
        startTimer()
        // Resume reanimates the banner: hub re-bases `startedAt` from
        // the preserved `elapsedSeconds` so the widget picks up at the
        // user's actual position instead of snapping back to 00:00.
        await syncLiveActivity()
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    public func stop() async {
        guard isRecording else { return }
        timer?.invalidate(); timer = nil
        statusLine = String(localized: "Transcribing …")
        Diag.log(session: sessionID, "capture.stop chunks=\(chunks.count) elapsed=\(elapsedSeconds)s mem=\(MemoryReport.formatted())")
        do {
            // If the user stopped without pausing first, finalise the
            // currently-recording chunk as the last one. If they were
            // already paused, the engine is already stopped — skip the
            // engine.stop() but still shutdown below.
            var trailing: StoredChunk?
            if !isPaused, let url = currentAudioURL {
                let chunkStart = currentChunkStartedAt ?? startedAt ?? Date()
                let chunkDuration = Date().timeIntervalSince(chunkStart)
                do {
                    _ = try await engine.stop()
                } catch {
                    // An interruption already closed the writer, so
                    // `stop()` throws `notRunning` with the audio intact.
                    // Keep the chunk instead of discarding the session.
                    let interrupted = await engine.wasInterrupted
                    guard InterruptionNotice.shouldTolerateStopError(error, wasInterrupted: interrupted) else {
                        throw error
                    }
                    Diag.log(session: sessionID, "capture.stop.interrupted_chunk_kept url=\(url.lastPathComponent)")
                }
                await latchInterruption()
                var transcript: ParakeetManager.Transcript?
                do {
                    transcript = try await ParakeetManager.shared.transcribe(audioURL: url)
                } catch {
                    Log.audio.warning(
                        "Parakeet transcript skipped: \(String(describing: error), privacy: .public)"
                    )
                }
                trailing = StoredChunk(
                    url: url,
                    transcript: transcript,
                    duration: chunkDuration
                )
            }
            // Note is one-shot — once the segment is finalised, tear
            // the engine fully down. We pre-armed it in `start()` to
            // cope with the lock-screen / Action-Button trigger path,
            // so it's running until we explicitly shutdown here.
            await engine.shutdown()
            if let trailing { chunks.append(trailing) }

            guard let started = startedAt, let dir = sessionDir, !chunks.isEmpty else {
                resetAfterStop()
                return
            }
            let duration = chunks.reduce(0) { $0 + $1.duration }
            isRecording = false
            isPaused = false
            startedAt = nil
            persistRecordingState(active: false, startedAt: nil)
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()

            let firstChunk = chunks[0]
            let voiceNoteChunks = chunks.map { c in
                VoiceNoteChunk(
                    filename: c.url.lastPathComponent,
                    duration_seconds: c.duration,
                    language: c.transcript?.language ?? "de",
                    transcript: c.transcript?.text ?? ""
                )
            }
            let note = VoiceNote(
                seed_id: "note-" + ISO8601DateFormatter().string(from: started),
                captured_at: started,
                duration_seconds: duration,
                language: firstChunk.transcript?.language ?? "de",
                transcript: firstChunk.transcript?.text ?? "",
                audio_file_url: firstChunk.url,
                chunks: voiceNoteChunks.count > 1 ? voiceNoteChunks : nil
            )
            do {
                try writeMetadata(note: note, into: dir)
            } catch {
                // Metadata write failed (disk full, permissions). The audio
                // files are already on disk in `dir` and are not lost —
                // we deliberately do NOT call `resetAfterStop()` here, which
                // would set `sessionDir = nil` and make them invisible. Keep
                // `sessionDir` intact so a future recovery path can find them.
                // Surface the error in the UI but leave `isRecording = false`
                // so the user is not stuck in a permanent "recording" state.
                lastError = CaptureErrorMessage.message(for: error, context: .finishAudioSaved)
                statusLine = ""
                isRecording = false
                isPaused = false
                startedAt = nil
                persistRecordingState(active: false, startedAt: nil)
                Diag.log(session: sessionID, "capture.stop.metadata_failed err=\(String(describing: error)) dir=\(dir.lastPathComponent)")
                self.sessionID = nil
                await endLiveActivity()
                return
            }
            lastNote = note
            persistLastSeed(note)
            statusLine = chunks.contains(where: { $0.transcript == nil })
                ? String(localized: "Recording saved. Transcript follows on server upload.")
                : String(localized: "Recording + transcript saved.")
            // Reset chunk storage now that the metadata captures it.
            chunks = []
            sessionDir = nil
            currentAudioURL = nil
            currentChunkStartedAt = nil
            Diag.log(session: sessionID, "capture.finalized seed=\(note.seed_id) dur=\(Int(duration))s")
            self.sessionID = nil
            await endLiveActivity()
            await CaptureNotifications.shared.fireCaptureComplete(
                duration: duration,
                transcriptPreview: note.transcript.isEmpty ? nil : note.transcript
            )
        } catch {
            lastError = CaptureErrorMessage.message(for: error, context: .finish)
            statusLine = ""
            Diag.log(session: sessionID, "capture.stop.failed err=\(String(describing: error))")
            resetAfterStop()
            self.sessionID = nil
            await endLiveActivity()
        }
    }

    /// Dismisses the interruption banner without starting a new recording.
    public func dismissInterruptionNotice() {
        recordingWasInterrupted = false
    }

    private func latchInterruption() async {
        if await engine.wasInterrupted {
            recordingWasInterrupted = true
            Diag.log(session: sessionID, "capture.interrupted")
        }
    }

    private func resetAfterStop() {
        isRecording = false
        isPaused = false
        startedAt = nil
        sessionDir = nil
        currentAudioURL = nil
        currentChunkStartedAt = nil
        chunks = []
        persistRecordingState(active: false, startedAt: nil)
    }

    // --- private helpers ----------------------------------------------

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.elapsedSeconds += 1
                // No per-second Live Activity push — the widget renders
                // its counter from `state.startedAt` via
                // `Text(timerInterval:)`, so it self-ticks. We previously
                // burned an `Activity.update` every second here; iOS
                // throttles those aggressively and the digit would freeze
                // for tens of seconds at a time on the lock screen. State
                // changes (start / pause / resume / stop) still flow
                // through the hub.
            }
        }
    }

    private func writeMetadata(note: VoiceNote, into dir: URL) throws {
        try Self.writeMetadata(note: note, into: dir)
    }

    /// `write` is a seam so tests can simulate a full disk; it only ever
    /// touches `metadata.json`, never the audio chunks beside it.
    static func writeMetadata(
        note: VoiceNote,
        into dir: URL,
        write: (Data, URL) throws -> Void = { data, url in
            try data.write(to: url, options: [.atomic, .completeFileProtection])
        }
    ) throws {
        let json = dir.appending(path: "metadata.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(note)
        try write(data, json)
    }

    private func persistRecordingState(active: Bool, startedAt: Date?) {
        guard let defaults = UserDefaults(suiteName: AppGroup.identifier) else { return }
        defaults.set(active, forKey: AppGroup.recordingActiveKey)
        if let startedAt {
            defaults.set(startedAt.timeIntervalSince1970,
                         forKey: AppGroup.recordingStartedAtKey)
        } else {
            defaults.removeObject(forKey: AppGroup.recordingStartedAtKey)
        }
        // Kick the lock-screen accessory widget timeline so its mic/
        // record glyph flips immediately instead of waiting for the
        // next system-budgeted refresh (which scheduled +5 / +15 min
        // out). Without this the lock-screen icon could stay green
        // "mic" minutes after recording started, or red "record" minutes
        // after stopping.
        WidgetCenter.shared.reloadTimelines(
            ofKind: "com.tomorrowflow.voice-diary.lockscreen"
        )
    }

    private func persistLastSeed(_ note: VoiceNote) {
        guard let defaults = UserDefaults(suiteName: AppGroup.identifier) else { return }
        defaults.set(note.transcript, forKey: AppGroup.lastSeedTranscriptKey)
        defaults.set(note.duration_seconds, forKey: AppGroup.lastSeedDurationKey)
    }

    // --- Live Activity --------------------------------------------------
    //
    // Pushed through `LiveActivityHub` so the drive-by and the walkthrough
    // coordinators never stack two activities of the same type. The hub
    // also computes `startedAt` from `elapsedSeconds` so a pause+resume
    // cycle re-bases the widget's self-counting timer at the right
    // offset without us having to push per-second updates.

    private func syncLiveActivity() async {
        await LiveActivityHub.shared.sync(
            owner: .capture,
            kind: .recording,
            elapsedSeconds: elapsedSeconds,
            isPaused: isPaused
        )
    }

    private func endLiveActivity() async {
        await LiveActivityHub.shared.end(owner: .capture)
    }
}
