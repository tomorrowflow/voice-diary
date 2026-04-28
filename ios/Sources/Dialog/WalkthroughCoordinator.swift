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

    private let engine = AudioEngine()
    private let tts: any TTSEngine = VoiceRegistry.engine(for: "de")
    private var sessionDir: URL?
    private var segmentURLs: [String: URL] = [:]    // multipart name → on-disk URL
    private var segments: [Segment] = []
    private var timer: Timer?

    private init() {}

    // MARK: - Public commands -----------------------------------------

    public func begin(today: Date = Date(), language: OpenerLanguage = .de) async {
        guard case .idle = state else { return }
        state = .briefing
        error = nil
        events = []
        segments = []
        segmentURLs = [:]
        do {
            try makeSessionDir()
            try await fetchCalendar(date: today)
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
        try? await engine.stop()
        await tts.cancel()
        state = .idle
    }

    // MARK: - Phases ---------------------------------------------------

    private func runEvent(at index: Int, language: OpenerLanguage) async {
        guard index < events.count else { return }
        state = .eventOpener(index: index)
        let line = OpenerTemplates.line(
            for: events[index],
            index: index,
            of: events.count,
            language: language
        )
        lastSpoken = line
        await tts.speak(line, language: language.rawValue)
        // Move to listening — start capturing this event's segment.
        do {
            try await startSegmentCapture(forEventAt: index)
            state = .eventListening(index: index)
            startTimer()
        } catch {
            self.error = "\(error)"
            state = .failed("\(error)")
        }
    }

    private func goClosing(language: OpenerLanguage) async {
        state = .closingPrompt
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
        state = .ingesting
        do {
            try await stopSegmentCaptureNoTranscribe()
            let manifest = try buildManifest()
            sessionID = manifest.session_id
            await SessionUploader.shared.enqueue(
                manifest: manifest,
                audioFiles: segmentURLs
            )
            state = .done
        } catch {
            self.error = "\(error)"
            state = .failed("\(error)")
        }
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
        try await engine.start(outputURL: url)
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
        try await engine.start(outputURL: url)
        segmentURLs[path] = url
        let seg = FreeReflectionSegment(
            segment_id: segmentID,
            audio_file: path,
            captured_at: ISO8601DateFormatter().string(from: Date())
        )
        segments.append(.freeReflection(seg))
    }

    private func stopSegmentCapture() async {
        timer?.invalidate(); timer = nil
        elapsedSeconds = 0
        do { _ = try await engine.stop() } catch {
            Log.audio.warning("walkthrough engine stop: \(String(describing: error), privacy: .public)")
        }
    }

    private func stopSegmentCaptureNoTranscribe() async throws {
        timer?.invalidate(); timer = nil
        elapsedSeconds = 0
        _ = try? await engine.stop()
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
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        let dateString = f.string(from: date)
        let raw = try await ServerClient.shared.todayCalendar(date: dateString)
        let response = try JSONDecoder().decode(TodayCalendarResponse.self, from: raw)
        events = response.events
    }

    private func buildManifest() throws -> Manifest {
        guard let sessionID else { throw NSError(domain: "Walkthrough", code: 2) }
        let dateString: String = {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy-MM-dd"
            return f.string(from: Date())
        }()
        return Manifest(
            session_id: sessionID,
            date: dateString,
            audio_codec: AudioCodec(
                codec: "aac-lc",
                sample_rate: 44_100,
                channels: 1,
                bitrate: 64_000
            ),
            segments: segments,
            ai_prompts: [
                AiPrompt(
                    at: ISO8601DateFormatter().string(from: Date()),
                    role: "walkthrough_skeleton",
                    text: "M5 deterministic openers, no follow-ups, no enrichment."
                )
            ],
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

