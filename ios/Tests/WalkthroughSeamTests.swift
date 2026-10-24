import Foundation
import Testing
@testable import VoiceDiary

// IOS-A14 (#10): `WalkthroughCoordinator` takes its capture engine and its
// server calls through `AudioCapturing` and `SessionTransport`; the upload
// queue sends through the same transport. Fakes stand in for both, so none
// of these tests opens a microphone or makes an HTTP request.

private func calendarJSON(date: String, subjects: [String]) throws -> Data {
    let events = subjects.enumerated().map { index, subject in
        ServerCalendarEvent(
            graph_event_id: "e\(index)", subject: subject,
            start: "\(date)T10:00:00+02:00", end: "\(date)T10:30:00+02:00",
            is_all_day: false, show_as: "busy", rsvp_status: "accepted",
            organizer: ServerAttendee(name: "A", email: "a@example.com"),
            attendees: [], body_preview: "", is_recurring: false, web_link: ""
        )
    }
    return try JSONEncoder().encode(
        TodayCalendarResponse(date: date, rsvp_filter: ["accepted"], events: events)
    )
}

@MainActor
@Suite("WalkthroughCoordinator with fakes")
struct WalkthroughSeamTests {
    private let engine = FakeAudioEngine()
    private let transport = FakeTransport()
    private let transcriptions = CallLog()
    private let coordinator: WalkthroughCoordinator

    init() {
        var transcriber = WalkthroughCoordinator.Transcriber()
        let log = transcriptions
        transcriber.warmUp = { await log.add("warmUp") }
        transcriber.transcribe = { url in
            await log.add("transcribe:\(url.lastPathComponent)")
            throw FakeTransport.Unreachable()
        }
        coordinator = WalkthroughCoordinator(
            engine: engine, transport: transport, transcriber: transcriber
        )
    }

    /// Starts a walkthrough whose calendar fetch fails, which parks it on
    /// `.calendarUnavailable` after the session bundle exists and before any
    /// TTS, LLM or upload runs.
    private func beginWithUnreachableCalendar() async {
        await transport.stubCalendar(.failure(FakeTransport.Unreachable()))
        await coordinator.begin()
    }

    @Test("begin arms the audio session once, before the calendar fallback is shown")
    func beginPreparesTheSession() async {
        await beginWithUnreachableCalendar()

        #expect(await engine.calls == ["prepareSession"])
        guard case .calendarUnavailable = coordinator.state else {
            Issue.record("expected .calendarUnavailable, got \(coordinator.state)")
            return
        }
        #expect(await eventually { await transcriptions.items == ["warmUp"] })
    }

    @Test("begin probes /health through the transport and shows the upstream notice")
    func beginShowsUpstreamNotice() async {
        await transport.stubHealth(.success(Data(#"{"upstream":{"whisper":"down"}}"#.utf8)))

        await beginWithUnreachableCalendar()

        let shown = await eventually { coordinator.upstreamStartNotice != nil }
        await coordinator.cancel()   // ends the notice's 6 s timer even if an expectation fails
        #expect(shown)
        #expect(await transport.healthCalls == 1)
    }

    @Test("a failing /health does not stop the start")
    func beginIgnoresHealthFailure() async {
        await transport.stubHealth(.failure(FakeTransport.Unreachable()))

        await beginWithUnreachableCalendar()

        #expect(await eventually { await transport.healthCalls == 1 })
        #expect(await engine.calls == ["prepareSession"])
        guard case .calendarUnavailable = coordinator.state else {
            Issue.record("expected .calendarUnavailable, got \(coordinator.state)")
            return
        }
    }

    @Test("a failed engine start throws and the bundle does not keep the segment")
    func failedCaptureStart() async throws {
        await beginWithUnreachableCalendar()
        await engine.failStarts()

        await #expect(throws: FakeAudioEngine.StartFailed.self) {
            try await coordinator.startCapture(.reflection(baseID: "s01"))
        }
        await engine.allowStarts()
        try await coordinator.startCapture(.reflection(baseID: "s01"))

        // The retry gets the same file: the failed attempt was never recorded.
        let starts = await engine.calls.filter { $0.hasPrefix("start:") }
        #expect(starts.count == 2)
        #expect(starts[0] == starts[1])
        #expect(await engine.calls.first == "prepareSession")
        await coordinator.cancel()
    }

    @Test("an interruption seen at segment stop stays latched when the next segment starts")
    func interruptionLatchesAcrossSegments() async throws {
        await beginWithUnreachableCalendar()
        try await coordinator.startCapture(.reflection(baseID: "s01"))
        await engine.interrupt()

        await coordinator.stopSegmentCapture()
        #expect(coordinator.recordingWasInterrupted)

        // The fake clears its own flag on start, like AudioEngine does.
        try await coordinator.startCapture(.reflection(baseID: "s01"))
        #expect(!(await engine.wasInterrupted))
        #expect(coordinator.recordingWasInterrupted)

        await coordinator.stopSegmentCapture()
        #expect(coordinator.recordingWasInterrupted)
        coordinator.dismissInterruptionNotice()
        #expect(!coordinator.recordingWasInterrupted)

        // The finaliser went through the stub, not the Parakeet model.
        #expect(await eventually { await transcriptions.items.filter { $0.hasPrefix("transcribe:") }.count == 2 })
        await coordinator.cancel()
    }

    @Test("a segment that ends without an interruption does not set the flag")
    func noInterruptionNoFlag() async throws {
        await beginWithUnreachableCalendar()
        try await coordinator.startCapture(.reflection(baseID: "s01"))

        await coordinator.stopSegmentCapture()

        #expect(!coordinator.recordingWasInterrupted)
        await coordinator.cancel()
    }

    @Test("cancel finalises the open segment, then shuts the engine down")
    func cancelStopsThenShutsDown() async {
        await coordinator.cancel()

        #expect(await engine.calls == ["stop", "shutdown"])
        #expect(coordinator.state == .idle)
    }

    @Test("previewDay asks the transport for the chosen day and keeps its events")
    func previewDaySuccess() async throws {
        await transport.stubCalendar(.success(try calendarJSON(date: "2026-10-15", subjects: ["Sync", "Review"])))
        let day = try #require(Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 15)))

        await coordinator.previewDay(day)

        #expect(await transport.calendarDates == ["2026-10-15|accepted,organizer"])
        #expect(coordinator.previewEvents.map(\.subject) == ["Sync", "Review"])
        #expect(coordinator.previewError == nil)
        #expect(!coordinator.isPreviewing)
    }

    @Test("a transport failure in previewDay clears the events and reports a diagnosis")
    func previewDayFailure() async throws {
        let day = try #require(Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 15)))
        await transport.stubCalendar(.success(try calendarJSON(date: "2026-10-15", subjects: ["Sync"])))
        await coordinator.previewDay(day)
        #expect(coordinator.previewEvents.count == 1)

        await transport.stubCalendar(.failure(FakeTransport.Unreachable()))
        await coordinator.previewDay(day)

        #expect(coordinator.previewEvents.isEmpty)
        #expect(coordinator.previewError != nil)
        #expect(!coordinator.isPreviewing)
    }

    @Test("loadRecordedDates asks for 60 days either side and stores the answer")
    func recordedDatesSuccess() async throws {
        await transport.stubDates(.success(["2026-10-01", "2026-10-02"]))
        let anchor = try #require(Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 15)))

        await coordinator.loadRecordedDates(around: anchor)

        #expect(await transport.recordedRanges == ["2026-08-16...2026-12-14"])
        #expect(coordinator.recordedDates == ["2026-10-01", "2026-10-02"])
    }

    @Test("loadRecordedDates keeps the previous dates when the transport fails")
    func recordedDatesFailure() async {
        await transport.stubDates(.success(["2026-10-01"]))
        await coordinator.loadRecordedDates()

        await transport.stubDates(.failure(FakeTransport.Unreachable()))
        await coordinator.loadRecordedDates()

        #expect(coordinator.recordedDates == ["2026-10-01"])
    }
}

@Suite("EngineSessionBundleAudio over a fake engine")
struct BundleAudioSeamTests {
    @Test("the bundle reads its sample rate from whatever engine it was given")
    func sampleRateComesFromTheSeam() async {
        let audio = EngineSessionBundleAudio(engine: FakeAudioEngine())

        #expect(await audio.sampleRate() == 44_100)
    }
}

@Suite("SessionUploader over a transport")
struct UploaderTransportTests {
    private let sessionID = "2026-04-27T19:30:00+02:00"

    /// A queue file holding one entry whose single audio file exists.
    private func seededQueue() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "vd-transport-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let audio = dir.appending(path: "s01.m4a")
        try Data("audio".utf8).write(to: audio)
        let field = "segments/s01.m4a"
        let entry = SessionUploader.QueueEntry(
            id: sessionID,
            manifest: Manifest(
                session_id: sessionID, date: "2026-04-27",
                segments: [.voiceNote(VoiceNoteSegment(
                    segment_id: "s01", captured_at: "2026-04-27T19:31:00+02:00", audio_file: field
                ))]
            ),
            audio_file_paths: [field: audio.path],
            attempts: 0,
            next_attempt_at: Date(timeIntervalSince1970: 0)
        )
        let file = dir.appending(path: "upload_queue.json")
        try JSONEncoder().encode([entry]).write(to: file)
        return file
    }

    private func accepted() -> SessionAccepted {
        SessionAccepted(
            status: "accepted", session_id: sessionID,
            received_at: "2026-04-27T19:32:00+02:00", processing_status_url: "/s", segments: []
        )
    }

    @Test("a successful transport upload dequeues the session")
    func successDequeues() async throws {
        let file = try seededQueue()
        let transport = FakeTransport()
        await transport.stubUpload(.success(accepted()))
        let uploader = SessionUploader(transport: transport, queueFile: { file })

        await uploader.flush()

        #expect(await transport.uploadedSessionIDs == [sessionID])
        #expect(await uploader.pending().isEmpty)
    }

    @Test("a failing transport keeps the session queued with one more attempt")
    func failureKeepsEntry() async throws {
        let file = try seededQueue()
        let transport = FakeTransport()
        await transport.stubUpload(.failure(FakeTransport.Unreachable()))
        let uploader = SessionUploader(transport: transport, queueFile: { file })

        await uploader.flush()

        #expect(await transport.uploadedSessionIDs == [sessionID])
        let waiting = await uploader.pending()
        #expect(waiting.count == 1)
        #expect(waiting[0].attempts == 1)
    }
}
