import Foundation
import Testing
@testable import VoiceDiary

// UFH-06: a calendar failure at walkthrough start (fresh or resumed) is a
// decision screen, not a dead end. The coordinator is a singleton over live
// audio, TTS and network, so the rules live in `CalendarStartGate`, the
// plan builder and `CalendarFreeMarker`, which these tests drive directly.

private struct FetchFailed: Error {}

private func event(_ id: String) -> ServerCalendarEvent {
    ServerCalendarEvent(
        graph_event_id: id, subject: "Sync", start: "2026-10-15T10:00:00+02:00",
        end: "2026-10-15T10:30:00+02:00", is_all_day: false, show_as: "busy",
        rsvp_status: "accepted", organizer: ServerAttendee(name: "A", email: "a@example.com"),
        attendees: [], body_preview: "", is_recurring: false, web_link: ""
    )
}

@Suite("Calendar failure diagnosis")
struct CalendarFailureDiagnosisTests {
    private func diagnosis(_ code: String?, retryable: Bool?, language: OpenerLanguage = .en) -> ConnectionDiagnosis {
        ConnectionDiagnosis.classify(
            ServerClientError.http(
                status: 503, detail: "boom",
                failure: UpstreamFailure(code: code, upstream: "msgraph", retryable: retryable)
            ),
            language: language
        )
    }

    @Test("a retryable Graph failure keeps Retry as the primary action")
    func retryableGraphFailure() {
        for code in ["msgraph_unavailable", "msgraph_rate_limited", "msgraph_engine_error"] {
            #expect(diagnosis(code, retryable: true).isRetryable, "\(code)")
        }
    }

    @Test("Graph not bootstrapped is not retryable and says once that the server has to fix it")
    func notBootstrapped() {
        for language in [OpenerLanguage.en, .de] {
            let d = diagnosis("msgraph_not_bootstrapped", retryable: false, language: language)
            #expect(!d.isRetryable)
            let impact = FailureCatalog.copy(
                for: UpstreamFailure(code: "msgraph_not_bootstrapped", upstream: "msgraph", retryable: false),
                language: language
            )?.impact
            #expect(impact != nil)
            #expect(!d.hint.contains(impact ?? "?"), "the impact line would repeat the hint")
            #expect(!d.hint.isEmpty)
        }
    }

    @Test("other coded failures still show hint and impact")
    func otherCodesKeepImpact() {
        let d = diagnosis("msgraph_unavailable", retryable: true)
        #expect(d.hint.contains("Calendar and mail aren’t reachable right now."))
    }

    @Test("failures without the contract fields stay retryable")
    func uncodedFailuresAreRetryable() {
        #expect(ConnectionDiagnosis.classify(ServerClientError.http(status: 502, detail: "x")).isRetryable)
        #expect(ConnectionDiagnosis.classify(URLError(.cannotConnectToHost)).isRetryable)
    }

    @Test("calendarUnavailable is a waiting state: no event-loop chrome, no pause")
    func waitingState() {
        let state = WalkthroughState.calendarUnavailable(diagnosis("msgraph_unavailable", retryable: true))
        #expect(!state.isInEventLoop)
        #expect(!state.isPausable)
        #expect(!state.isListening)
        #expect(!state.isSpeaking)
        #expect(!state.label.isEmpty)
    }
}

@MainActor
@Suite("Calendar start gate")
struct CalendarStartGateTests {
    private let day = Date(timeIntervalSince1970: 1_760_000_000)
    private let resumeDir = URL(fileURLWithPath: "/tmp/vd-session")

    private func start(_ gate: CalendarStartGate, mode: CalendarStart.Mode = .fresh) -> CalendarStart {
        CalendarStart(attempt: gate.newAttempt(), targetDate: day, language: .en, mode: mode)
    }

    @Test("retry fetches again and hands back the events to continue with")
    func retryThenContinue() async {
        let gate = CalendarStartGate()
        let waiting = start(gate)
        gate.park(waiting)

        var calls = 0
        let outcome = await gate.retry { date in
            calls += 1
            #expect(date == waiting.targetDate)
            return [event("e1")]
        }
        guard case .fetched(let events, let started) = outcome else {
            Issue.record("expected .fetched, got \(outcome)")
            return
        }
        #expect(calls == 1)
        #expect(events.map(\.graph_event_id) == ["e1"])
        #expect(started == waiting)
        #expect(gate.waiting == nil)
        #expect(!gate.isRetrying)
    }

    @Test("a failed retry keeps the start waiting, and a second retry can succeed")
    func retryFailsThenSucceeds() async {
        let gate = CalendarStartGate()
        gate.park(start(gate))

        let first = await gate.retry { _ in throw FetchFailed() }
        guard case .stillFailing = first else {
            Issue.record("expected .stillFailing, got \(first)")
            return
        }
        #expect(gate.waiting != nil)

        let second = await gate.retry { _ in [] }
        guard case .fetched(let events, _) = second else {
            Issue.record("expected .fetched, got \(second)")
            return
        }
        #expect(events.isEmpty)
    }

    @Test("a fetch that outlives a cancel is stale and changes nothing")
    func cancelMidFetch() async {
        let gate = CalendarStartGate()
        gate.park(start(gate))

        let outcome = await gate.retry { _ in
            gate.invalidate()           // the user closed the walkthrough
            return [event("late")]
        }
        guard case .stale = outcome else {
            Issue.record("expected .stale, got \(outcome)")
            return
        }
        #expect(gate.waiting == nil)
        #expect(gate.current == nil)
    }

    @Test("a fetch that outlives a newer start is stale, even when it fails")
    func restartMidFetch() async {
        let gate = CalendarStartGate()
        let old = start(gate)
        gate.park(old)

        let outcome = await gate.retry { _ in
            gate.invalidate()
            _ = gate.newAttempt()       // and started again
            throw FetchFailed()
        }
        guard case .stale = outcome else {
            Issue.record("expected .stale, got \(outcome)")
            return
        }
        #expect(!gate.isCurrent(old.attempt))
    }

    @Test("a second tap during a retry is ignored and cannot start without the calendar")
    func doubleTap() async {
        let gate = CalendarStartGate()
        gate.park(start(gate))

        let outcome = await gate.retry { _ in
            #expect(gate.isRetrying)
            #expect(gate.takeForStartWithout() == nil)
            let nested = await gate.retry { _ in [event("nested")] }
            guard case .ignored = nested else {
                Issue.record("expected .ignored, got \(nested)")
                return []
            }
            return [event("e1")]
        }
        guard case .fetched(let events, _) = outcome else {
            Issue.record("expected .fetched, got \(outcome)")
            return
        }
        #expect(events.count == 1)
    }

    @Test("a fresh start can choose to start without the calendar, once")
    func startWithoutForFreshStart() {
        let gate = CalendarStartGate()
        let waiting = start(gate)
        gate.park(waiting)
        #expect(gate.canStartWithout)

        #expect(gate.takeForStartWithout() == waiting)
        #expect(gate.waiting == nil)
        #expect(gate.takeForStartWithout() == nil)
    }

    @Test("resuming while Graph is down offers retry only, and a failed retry keeps waiting")
    func resumeWhileGraphIsDown() async {
        let gate = CalendarStartGate()
        gate.park(start(gate, mode: .resume(resumeDir)))
        #expect(!gate.canStartWithout)
        #expect(gate.takeForStartWithout() == nil)

        let outcome = await gate.retry { _ in throw FetchFailed() }
        guard case .stillFailing(_, let waiting) = outcome else {
            Issue.record("expected .stillFailing, got \(outcome)")
            return
        }
        #expect(waiting.mode == .resume(resumeDir))
        #expect(gate.waiting != nil)

        let later = await gate.retry { _ in [event("back")] }
        guard case .fetched(_, let resumed) = later else {
            Issue.record("expected .fetched, got \(later)")
            return
        }
        #expect(resumed.mode == .resume(resumeDir))
    }

    @Test("nothing waiting means nothing to retry or start")
    func nothingWaiting() async {
        let gate = CalendarStartGate()
        let outcome = await gate.retry { _ in [] }
        guard case .ignored = outcome else {
            Issue.record("expected .ignored, got \(outcome)")
            return
        }
        #expect(gate.takeForStartWithout() == nil)
    }
}

@Suite("Calendar-free session")
struct CalendarFreeSessionTests {
    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "vd-calfree-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("the marker survives for a later resume and is per session")
    func markerPersists() throws {
        let marked = try tempDir()
        let other = try tempDir()
        defer {
            try? FileManager.default.removeItem(at: marked)
            try? FileManager.default.removeItem(at: other)
        }
        #expect(!CalendarFreeMarker.isMarked(in: marked))
        CalendarFreeMarker.mark(in: marked)
        #expect(CalendarFreeMarker.isMarked(in: marked))
        #expect(!CalendarFreeMarker.isMarked(in: other))
    }

    private let general = GeneralSection(id: "g1", title: "Reflection", introText: "How was your day?")

    private func kinds(_ steps: [WalkthroughCoordinator.PlanStep]) -> [String] {
        steps.map {
            switch $0 {
            case .general: return "general"
            case .calendar: return "calendar"
            case .voiceNote: return "voiceNote"
            }
        }
    }

    @Test("without events the plan has no calendar step, in the configured order")
    func planWithoutCalendar() {
        let steps = WalkthroughCoordinator.makePlan(
            order: [.general(id: "g1"), .calendarEvents, .voiceNote],
            generals: [general], events: [], notes: []
        )
        #expect(kinds(steps) == ["general", "voiceNote"])
    }

    @Test("with events the calendar step keeps its place")
    func planWithCalendar() {
        let steps = WalkthroughCoordinator.makePlan(
            order: [.general(id: "g1"), .calendarEvents, .voiceNote],
            generals: [general], events: [event("e1")], notes: []
        )
        #expect(kinds(steps) == ["general", "calendar", "voiceNote"])
    }

    @Test("a calendar-free session's manifest has no calendar segment")
    func manifestHasNoCalendarSegment() throws {
        let manifest = Manifest(
            session_id: "2026-10-15T19:30:00+02:00",
            date: "2026-10-15",
            segments: [
                .generalSection(.init(
                    segment_id: "s01", section_id: "g1", title: "Reflection",
                    prompt_text: "How was your day?", audio_file: "segments/s01.m4a"
                )),
            ]
        )
        let decoded = try JSONDecoder().decode(Manifest.self, from: JSONEncoder().encode(manifest))
        #expect(decoded.segments.count == 1)
        for segment in decoded.segments {
            if case .calendarEvent = segment { Issue.record("unexpected calendar segment") }
        }
        let json = try #require(String(data: JSONEncoder().encode(manifest), encoding: .utf8))
        #expect(!json.contains("calendar_event"))
        #expect(!json.contains("calendar_ref"))
    }
}
