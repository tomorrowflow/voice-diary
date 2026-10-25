import Foundation

/// One scheduled section of a walkthrough. The calendar block is a single
/// step that expands at runtime into per-event sub-states.
enum WalkthroughPlanStep: Sendable {
    case general(GeneralSection)
    case calendar(events: [ServerCalendarEvent])
    case voiceNote(notes: [VoiceNote])
}

/// Walkthrough plan assembly as a pure function of explicit values: the
/// configured order, the general sections, the day's calendar events and the
/// unsurfaced voice notes. Loading those inputs and running the steps stay
/// in the coordinator.
enum WalkthroughPlanBuilder {
    /// The steps of a walkthrough, in `order`. A general id with no section
    /// is skipped; repeated entries are not deduplicated. A day with no
    /// events (or none fetched, when starting without the calendar) has no
    /// calendar step, so no calendar segment can be recorded. The voice-note
    /// step is kept even with no notes. `generals` must have unique ids.
    static func build(
        order: [WalkthroughSection],
        generals: [GeneralSection],
        events: [ServerCalendarEvent],
        notes: [VoiceNote]
    ) -> [WalkthroughPlanStep] {
        let generalsByID: [String: GeneralSection] = Dictionary(
            uniqueKeysWithValues: generals.map { ($0.id, $0) }
        )
        var steps: [WalkthroughPlanStep] = []
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
                steps.append(.voiceNote(notes: notes))
            }
        }
        return steps
    }
}
