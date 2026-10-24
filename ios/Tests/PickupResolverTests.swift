import Foundation
import Testing
@testable import VoiceDiary

// IOS-A7 / #6: pickup decisions live in `PickupResolver`, a set of pure
// functions over explicit values. These tests build states, plans and
// segments directly: no audio engine, bundle or coordinator is involved.

@Suite("PickupResolver state mapping")
struct PickupResolverStateMappingTests {
    private let now = Date(timeIntervalSince1970: 1_760_000_000)

    private func marker(_ state: WalkthroughState, activeSegmentID: String? = "s01e02c2") -> SessionBundle.PauseMarker? {
        PickupResolver.marker(for: state, elapsedSeconds: 133, activeSegmentID: activeSegmentID, now: now)
    }

    @Test("briefing pauses at step 0 with no segment")
    func briefing() {
        #expect(marker(.briefing) == .init(
            phase: .briefing, kind: nil, stepIndex: 0, eventIndex: nil, sectionID: nil,
            elapsedSeconds: 133, activeSegmentID: nil, pausedAt: now
        ))
    }

    @Test("an event opener names the step and event, never a segment")
    func eventOpener() {
        #expect(marker(.eventOpener(stepIndex: 2, eventIndex: 3)) == .init(
            phase: .opener, kind: .event, stepIndex: 2, eventIndex: 3, sectionID: nil,
            elapsedSeconds: 133, activeSegmentID: nil, pausedAt: now
        ))
    }

    @Test("event listening carries the segment being recorded")
    func eventListening() {
        #expect(marker(.eventListening(stepIndex: 2, eventIndex: 3)) == .init(
            phase: .listening, kind: .event, stepIndex: 2, eventIndex: 3, sectionID: nil,
            elapsedSeconds: 133, activeSegmentID: "s01e02c2", pausedAt: now
        ))
    }

    @Test("a general opener names the section, never a segment")
    func generalOpener() {
        #expect(marker(.generalOpener(stepIndex: 1, sectionID: "sec-1")) == .init(
            phase: .opener, kind: .general, stepIndex: 1, eventIndex: nil, sectionID: "sec-1",
            elapsedSeconds: 133, activeSegmentID: nil, pausedAt: now
        ))
    }

    @Test("general listening carries the section and the segment being recorded")
    func generalListening() {
        #expect(marker(.generalListening(stepIndex: 1, sectionID: "sec-1")) == .init(
            phase: .listening, kind: .general, stepIndex: 1, eventIndex: nil, sectionID: "sec-1",
            elapsedSeconds: 133, activeSegmentID: "s01e02c2", pausedAt: now
        ))
    }

    @Test("a voice-note opener names the step, never a segment")
    func voiceNoteOpener() {
        #expect(marker(.voiceNoteOpener(stepIndex: 4)) == .init(
            phase: .opener, kind: .voiceNote, stepIndex: 4, eventIndex: nil, sectionID: nil,
            elapsedSeconds: 133, activeSegmentID: nil, pausedAt: now
        ))
    }

    @Test("voice-note listening carries the segment being recorded")
    func voiceNoteListening() {
        #expect(marker(.voiceNoteListening(stepIndex: 4)) == .init(
            phase: .listening, kind: .voiceNote, stepIndex: 4, eventIndex: nil, sectionID: nil,
            elapsedSeconds: 133, activeSegmentID: "s01e02c2", pausedAt: now
        ))
    }

    @Test("a listening pause with nothing recording yet keeps a nil segment")
    func listeningWithoutSegment() {
        #expect(marker(.eventListening(stepIndex: 0, eventIndex: 0), activeSegmentID: nil)?.activeSegmentID == nil)
    }

    @Test("states that are not a step of the plan produce no marker")
    func nonPausableStates() {
        let states: [WalkthroughState] = [
            .idle,
            .noteReview(stepIndex: 0, noteIndex: 0),
            .confirmingTodos(index: 0),
            .calendarUnavailable(ConnectionDiagnosis(
                kind: .unreachable, title: "Offline", hint: "", detail: nil, systemImage: "wifi.slash"
            )),
            .ingesting,
            .done,
            .failed("boom"),
        ]
        for state in states {
            #expect(marker(state) == nil, "\(state)")
        }
    }
}

@Suite("PickupResolver resolution")
struct PickupResolverResolutionTests {
    private let now = Date(timeIntervalSince1970: 1_760_000_000)
    private let pausedAt = Date(timeIntervalSince1970: 1_759_990_000)

    // MARK: - Fixtures

    private func event(_ id: String) -> ServerCalendarEvent {
        ServerCalendarEvent(
            graph_event_id: id, subject: "Sync", start: "2026-10-15T10:00:00+02:00",
            end: "2026-10-15T10:30:00+02:00", is_all_day: false, show_as: "busy",
            rsvp_status: "accepted", organizer: ServerAttendee(name: "A", email: "a@example.com"),
            attendees: [], body_preview: "", is_recurring: false, web_link: ""
        )
    }

    private func eventSegment(_ segmentID: String, event eventID: String) -> Segment {
        .calendarEvent(CalendarEventSegment(
            segment_id: segmentID,
            calendar_ref: CalendarRef(
                graph_event_id: eventID, title: "Sync",
                start: "2026-10-15T10:00:00+02:00", end: "2026-10-15T10:30:00+02:00"
            ),
            audio_file: "\(segmentID).m4a"
        ))
    }

    private func sectionSegment(_ segmentID: String, section sectionID: String) -> Segment {
        .generalSection(GeneralSectionSegment(
            segment_id: segmentID, section_id: sectionID, title: "Wins",
            prompt_text: "Was lief gut?", audio_file: "\(segmentID).m4a"
        ))
    }

    private func reflectionSegment(_ segmentID: String) -> Segment {
        .freeReflection(FreeReflectionSegment(segment_id: segmentID, audio_file: "\(segmentID).m4a"))
    }

    private func section(_ id: String) -> GeneralSection {
        GeneralSection(id: id, title: "Wins", introText: "Was lief gut?")
    }

    private func saved(
        phase: SessionBundle.PauseMarker.Phase, kind: SessionBundle.PauseMarker.Kind?,
        stepIndex: Int = 0, eventIndex: Int? = nil, sectionID: String? = nil, activeSegmentID: String? = nil
    ) -> SessionBundle.PauseMarker {
        .init(
            phase: phase, kind: kind, stepIndex: stepIndex, eventIndex: eventIndex, sectionID: sectionID,
            elapsedSeconds: 133, activeSegmentID: activeSegmentID, pausedAt: pausedAt
        )
    }

    private func resolve(
        _ journal: PickupResolver.Journal,
        plan: [WalkthroughCoordinator.PlanStep] = [],
        seconds: @escaping (Segment) -> TimeInterval? = { _ in nil }
    ) -> SessionBundle.PauseMarker? {
        PickupResolver.resolve(journal, in: plan, chunkSeconds: seconds, now: now)
    }

    // MARK: - saved marker

    @Test("a saved briefing marker is returned as saved")
    func savedBriefing() {
        let marker = saved(phase: .briefing, kind: nil)
        let journal = PickupResolver.Journal(savedMarker: marker, latestChunks: [])
        #expect(resolve(journal) == marker)
    }

    @Test("a saved opener marker is returned as saved, even if the plan has changed")
    func savedOpener() {
        let marker = saved(phase: .opener, kind: .event, stepIndex: 0, eventIndex: 1)
        let journal = PickupResolver.Journal(
            savedMarker: marker,
            latestSegment: eventSegment("s02e01", event: "gone"), latestChunks: []
        )
        #expect(resolve(journal, plan: [.calendar(events: [event("A")])]) == marker)
    }

    @Test("a saved listening marker whose segment is missing is returned as saved")
    func savedListeningMissingSegment() {
        let marker = saved(phase: .listening, kind: .event, eventIndex: 1, activeSegmentID: "s01e02")
        let journal = PickupResolver.Journal(savedMarker: marker, savedSegment: nil, latestChunks: [])
        #expect(resolve(journal, plan: [.calendar(events: [event("A")])]) == marker)
    }

    @Test("a saved listening marker that names no segment is returned as saved")
    func savedListeningWithoutSegmentID() {
        let marker = saved(phase: .listening, kind: .voiceNote, stepIndex: 3)
        let journal = PickupResolver.Journal(
            savedMarker: marker, savedSegment: reflectionSegment("s03"), latestChunks: []
        )
        #expect(resolve(journal) == marker)
    }

    @Test("a saved listening marker follows its event to the new index after a calendar reorder")
    func savedListeningEventReordered() {
        let marker = saved(phase: .listening, kind: .event, stepIndex: 1, eventIndex: 0, activeSegmentID: "s02e01c2")
        let journal = PickupResolver.Journal(
            savedMarker: marker, savedSegment: eventSegment("s02e01c2", event: "B"), latestChunks: []
        )
        let plan: [WalkthroughCoordinator.PlanStep] = [
            .general(section("sec-1")),
            .calendar(events: [event("A"), event("C"), event("B")]),
        ]
        #expect(resolve(journal, plan: plan) == saved(
            phase: .listening, kind: .event, stepIndex: 1, eventIndex: 2, activeSegmentID: "s02e01c2"
        ))
    }

    @Test("a saved listening marker is nil when its event was removed from the calendar")
    func savedListeningEventRemoved() {
        let marker = saved(phase: .listening, kind: .event, stepIndex: 0, eventIndex: 1, activeSegmentID: "s01e02")
        let journal = PickupResolver.Journal(
            savedMarker: marker, savedSegment: eventSegment("s01e02", event: "B"), latestChunks: []
        )
        #expect(resolve(journal, plan: [.calendar(events: [event("A"), event("C")])]) == nil)
    }

    @Test("a saved general listening marker follows its section to the new step")
    func savedListeningSectionMoved() {
        let marker = saved(phase: .listening, kind: .general, stepIndex: 0, sectionID: "sec-1", activeSegmentID: "s01")
        let journal = PickupResolver.Journal(
            savedMarker: marker, savedSegment: sectionSegment("s01", section: "sec-1"), latestChunks: []
        )
        let plan: [WalkthroughCoordinator.PlanStep] = [
            .calendar(events: [event("A")]),
            .general(section("sec-2")),
            .general(section("sec-1")),
        ]
        #expect(resolve(journal, plan: plan) == saved(
            phase: .listening, kind: .general, stepIndex: 2, sectionID: "sec-1", activeSegmentID: "s01"
        ))
    }

    @Test("a saved voice-note listening marker follows the voice-note step")
    func savedListeningVoiceNoteMoved() {
        let marker = saved(phase: .listening, kind: .voiceNote, stepIndex: 1, activeSegmentID: "s02")
        let journal = PickupResolver.Journal(
            savedMarker: marker, savedSegment: reflectionSegment("s02"), latestChunks: []
        )
        let plan: [WalkthroughCoordinator.PlanStep] = [
            .calendar(events: [event("A")]), .general(section("sec-1")), .voiceNote(notes: []),
        ]
        #expect(resolve(journal, plan: plan) == saved(
            phase: .listening, kind: .voiceNote, stepIndex: 2, activeSegmentID: "s02"
        ))
    }

    @Test("a saved marker wins over the latest recorded segment and measures nothing")
    func savedMarkerHasPriority() {
        let marker = saved(phase: .opener, kind: .general, stepIndex: 0, sectionID: "sec-1")
        let latest = eventSegment("s02e01", event: "A")
        let journal = PickupResolver.Journal(savedMarker: marker, latestSegment: latest, latestChunks: [latest])
        var measured = 0
        let result = resolve(journal, plan: [.calendar(events: [event("A")])]) { _ in
            measured += 1
            return 5
        }
        #expect(result == marker)
        #expect(measured == 0)
    }

    // MARK: - latest recorded segment

    @Test("with no marker pickup lands on the latest recorded event, listening, with its segment")
    func fallbackEvent() {
        let latest = eventSegment("s01e02", event: "B")
        let journal = PickupResolver.Journal(latestSegment: latest, latestChunks: [latest])
        let plan: [WalkthroughCoordinator.PlanStep] = [.calendar(events: [event("A"), event("B")])]
        #expect(resolve(journal, plan: plan) { _ in 42 } == .init(
            phase: .listening, kind: .event, stepIndex: 0, eventIndex: 1, sectionID: nil,
            elapsedSeconds: 42, activeSegmentID: "s01e02", pausedAt: now
        ))
    }

    @Test("with no marker pickup lands on the latest recorded general section")
    func fallbackGeneral() {
        let latest = sectionSegment("s01", section: "sec-1")
        let journal = PickupResolver.Journal(latestSegment: latest, latestChunks: [latest])
        let plan: [WalkthroughCoordinator.PlanStep] = [.calendar(events: []), .general(section("sec-1"))]
        #expect(resolve(journal, plan: plan) == .init(
            phase: .listening, kind: .general, stepIndex: 1, eventIndex: nil, sectionID: "sec-1",
            elapsedSeconds: 0, activeSegmentID: "s01", pausedAt: now
        ))
    }

    @Test("with no marker pickup lands on the voice-note step after a recorded reflection")
    func fallbackReflection() {
        let latest = reflectionSegment("s03")
        let journal = PickupResolver.Journal(latestSegment: latest, latestChunks: [latest])
        let plan: [WalkthroughCoordinator.PlanStep] = [.general(section("sec-1")), .voiceNote(notes: [])]
        #expect(resolve(journal, plan: plan) == .init(
            phase: .listening, kind: .voiceNote, stepIndex: 1, eventIndex: nil, sectionID: nil,
            elapsedSeconds: 0, activeSegmentID: "s03", pausedAt: now
        ))
    }

    @Test("the elapsed time is the rounded total of every chunk, not a sum of rounded chunks")
    func fallbackElapsedRoundsTheTotal() {
        let first = eventSegment("s01e02", event: "A")
        let second = eventSegment("s01e02c2", event: "A")
        let durations = ["s01e02": 0.4, "s01e02c2": 0.4]
        let journal = PickupResolver.Journal(latestSegment: second, latestChunks: [first, second])
        let plan: [WalkthroughCoordinator.PlanStep] = [.calendar(events: [event("A")])]
        #expect(resolve(journal, plan: plan) { durations[$0.segmentID] }?.elapsedSeconds == 1)

        let long = ["s01e02": 61.4, "s01e02c2": 71.2]
        #expect(resolve(journal, plan: plan) { long[$0.segmentID] }?.elapsedSeconds == 133)
    }

    @Test("a chunk that cannot be measured adds nothing")
    func fallbackSkipsUnreadableChunk() {
        let first = eventSegment("s01e02", event: "A")
        let second = eventSegment("s01e02c2", event: "A")
        let journal = PickupResolver.Journal(latestSegment: second, latestChunks: [first, second])
        let plan: [WalkthroughCoordinator.PlanStep] = [.calendar(events: [event("A")])]
        let result = resolve(journal, plan: plan) { $0.segmentID == "s01e02" ? nil : 30 }
        #expect(result?.elapsedSeconds == 30)
        #expect(result?.activeSegmentID == "s01e02c2")
    }

    @Test("with no marker and no recording there is nothing to resume")
    func nothingRecorded() {
        let journal = PickupResolver.Journal(latestChunks: [])
        #expect(resolve(journal, plan: [.calendar(events: [event("A")])]) == nil)
    }

    @Test("a segment only matches a plan step of its own kind")
    func segmentKindMustMatchStepKind() {
        let eventRecording = eventSegment("s01e02", event: "A")
        let sectionRecording = sectionSegment("s02", section: "sec-1")
        let reflection = reflectionSegment("s03")
        let eventsOnly: [WalkthroughCoordinator.PlanStep] = [.calendar(events: [event("A")])]
        let sectionsOnly: [WalkthroughCoordinator.PlanStep] = [.general(section("sec-1"))]
        let noteStepOnly: [WalkthroughCoordinator.PlanStep] = [.voiceNote(notes: [])]
        #expect(resolve(.init(latestSegment: eventRecording, latestChunks: []), plan: sectionsOnly) == nil)
        #expect(resolve(.init(latestSegment: sectionRecording, latestChunks: []), plan: eventsOnly) == nil)
        #expect(resolve(.init(latestSegment: reflection, latestChunks: []), plan: eventsOnly) == nil)
        #expect(resolve(.init(latestSegment: eventRecording, latestChunks: []), plan: noteStepOnly) == nil)
    }

    @Test("the latest recorded step is nil when it no longer exists in the plan")
    func fallbackStepGone() {
        let latest = eventSegment("s01e02", event: "B")
        let journal = PickupResolver.Journal(latestSegment: latest, latestChunks: [latest])
        #expect(resolve(journal, plan: [.calendar(events: [event("A")])]) == nil)
        #expect(resolve(journal, plan: [.general(section("sec-1"))]) == nil)
        #expect(resolve(journal, plan: []) == nil)
    }
}
