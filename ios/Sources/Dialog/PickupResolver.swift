import Foundation

/// Pickup decisions as pure functions of explicit values: which pause marker
/// a walkthrough state produces, and where in the current plan a saved
/// marker or the latest recorded segment re-enters. No audio engine, bundle
/// or coordinator is read, so the rules are testable without any of them.
/// Marker storage stays in `SessionBundle`; the coordinator supplies the
/// inputs and acts on the result.
enum PickupResolver {
    typealias Marker = SessionBundle.PauseMarker

    /// What the session journal says about where the user was, as values.
    struct Journal {
        /// The pause marker, nil when the user did not pause.
        var savedMarker: Marker?
        /// The recorded segment the saved marker's `activeSegmentID` names,
        /// nil when the marker names none or the journal no longer has it.
        var savedSegment: Segment?
        /// The most recently recorded walkthrough segment.
        var latestSegment: Segment?
        /// Every chunk of `latestSegment`'s recording, the latest included.
        var latestChunks: [Segment]
    }

    /// Where pickup re-enters in `plan`. The saved marker when the user
    /// paused; otherwise the step of the latest recorded segment, as after
    /// an app kill or a cancel. The step is found by what the segment says
    /// it recorded (its calendar event or section), never by its id, so a
    /// calendar that changed since the kill cannot move the user onto
    /// another event. Nil when that step no longer exists in `plan`.
    /// `chunkSeconds` measures one recorded chunk, nil when it cannot be
    /// read; it is only asked for on the latest-segment fallback.
    static func resolve(
        _ journal: Journal,
        in plan: [WalkthroughCoordinator.PlanStep],
        chunkSeconds: (Segment) -> TimeInterval?,
        now: Date
    ) -> Marker? {
        if let saved = journal.savedMarker {
            // Only a listening pause names a recorded segment to relocate.
            guard saved.phase == .listening,
                  let id = saved.activeSegmentID,
                  let segment = journal.savedSegment else { return saved }
            guard let spot = position(of: segment, in: plan) else { return nil }
            return Marker(
                phase: .listening,
                kind: spot.kind,
                stepIndex: spot.stepIndex,
                eventIndex: spot.eventIndex,
                sectionID: spot.sectionID,
                elapsedSeconds: saved.elapsedSeconds,
                activeSegmentID: id,
                pausedAt: saved.pausedAt
            )
        }
        guard let latest = journal.latestSegment,
              let spot = position(of: latest, in: plan) else { return nil }
        // Sum the recorded duration of every chunk of this step, so the
        // timer resumes at the total time spent in this meeting/section
        // instead of snapping to 00:00.
        let elapsed = journal.latestChunks.reduce(0.0) { $0 + (chunkSeconds($1) ?? 0) }
        return Marker(
            phase: .listening,
            kind: spot.kind,
            stepIndex: spot.stepIndex,
            eventIndex: spot.eventIndex,
            sectionID: spot.sectionID,
            elapsedSeconds: Int(elapsed.rounded()),
            activeSegmentID: latest.segmentID,
            pausedAt: now
        )
    }

    /// The plan step a recorded segment belongs to in `plan`.
    private static func position(of segment: Segment, in plan: [WalkthroughCoordinator.PlanStep]) -> (
        kind: Marker.Kind, stepIndex: Int, eventIndex: Int?, sectionID: String?
    )? {
        for (stepIndex, step) in plan.enumerated() {
            switch (step, segment) {
            case (.calendar(let events), .calendarEvent(let recorded)):
                if let eventIndex = events.firstIndex(where: {
                    $0.graph_event_id == recorded.calendar_ref.graph_event_id
                }) {
                    return (.event, stepIndex, eventIndex, nil)
                }
            case (.general(let section), .generalSection(let recorded)):
                if section.id == recorded.section_id {
                    return (.general, stepIndex, nil, section.id)
                }
            case (.voiceNote, .freeReflection):
                return (.voiceNote, stepIndex, nil, nil)
            default:
                continue
            }
        }
        return nil
    }

    static func marker(
        for state: WalkthroughState,
        elapsedSeconds: Int,
        activeSegmentID: String?,
        now: Date
    ) -> Marker? {
        switch state {
        case .briefing:
            return Marker(
                phase: .briefing, kind: nil,
                stepIndex: 0, eventIndex: nil, sectionID: nil,
                elapsedSeconds: elapsedSeconds,
                activeSegmentID: nil, pausedAt: now
            )
        case .eventOpener(let s, let e):
            return Marker(
                phase: .opener, kind: .event,
                stepIndex: s, eventIndex: e, sectionID: nil,
                elapsedSeconds: elapsedSeconds,
                activeSegmentID: nil, pausedAt: now
            )
        case .eventListening(let s, let e):
            return Marker(
                phase: .listening, kind: .event,
                stepIndex: s, eventIndex: e, sectionID: nil,
                elapsedSeconds: elapsedSeconds,
                activeSegmentID: activeSegmentID, pausedAt: now
            )
        case .generalOpener(let s, let id):
            return Marker(
                phase: .opener, kind: .general,
                stepIndex: s, eventIndex: nil, sectionID: id,
                elapsedSeconds: elapsedSeconds,
                activeSegmentID: nil, pausedAt: now
            )
        case .generalListening(let s, let id):
            return Marker(
                phase: .listening, kind: .general,
                stepIndex: s, eventIndex: nil, sectionID: id,
                elapsedSeconds: elapsedSeconds,
                activeSegmentID: activeSegmentID, pausedAt: now
            )
        case .voiceNoteOpener(let s):
            return Marker(
                phase: .opener, kind: .voiceNote,
                stepIndex: s, eventIndex: nil, sectionID: nil,
                elapsedSeconds: elapsedSeconds,
                activeSegmentID: nil, pausedAt: now
            )
        case .voiceNoteListening(let s):
            return Marker(
                phase: .listening, kind: .voiceNote,
                stepIndex: s, eventIndex: nil, sectionID: nil,
                elapsedSeconds: elapsedSeconds,
                activeSegmentID: activeSegmentID, pausedAt: now
            )
        default:
            return nil
        }
    }
}
