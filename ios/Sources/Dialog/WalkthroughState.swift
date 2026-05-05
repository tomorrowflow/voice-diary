import Foundation

// Walkthrough state machine values (SPEC §6.1 / §6.2). The actual
// transition logic lives in `WalkthroughCoordinator`; this file is just
// the data model so views and tests can pattern-match without pulling in
// AVFoundation.
//
// Every event-loop / general / drive-by listening state carries the index
// of the current `PlanStep` in the coordinator's plan so the UI can use
// one progress counter for the whole session regardless of section type.

public enum WalkthroughState: Sendable, Equatable {
    case idle
    case briefing
    case eventOpener(stepIndex: Int, eventIndex: Int)        // AI speaking the per-event opener
    case eventListening(stepIndex: Int, eventIndex: Int)     // mic open, recording the user's reflection
    case generalOpener(stepIndex: Int, sectionID: String)    // AI speaking the user-defined intro
    case generalListening(stepIndex: Int, sectionID: String) // mic open, recording the section answer
    case driveByOpener(stepIndex: Int)                       // AI surfacing seeds + closing prompt
    case driveByListening(stepIndex: Int)                    // mic open, recording the closing reflection
    case confirmingTodos(index: Int)                         // post-CLOSING per-candidate ja/nein/anders pass
    case ingesting                                           // building manifest + handing to SessionUploader
    case done
    case failed(String)
}

public extension WalkthroughState {
    var isListening: Bool {
        switch self {
        case .eventListening, .generalListening, .driveByListening: return true
        default: return false
        }
    }

    var isSpeaking: Bool {
        switch self {
        case .briefing, .eventOpener, .generalOpener, .driveByOpener: return true
        default: return false
        }
    }

    /// True for any state where the user is "inside a section" — briefing,
    /// any opener, any listening. Used to keep the per-section action
    /// stack (Überspringen / Ich bin fertig / Weiter) and the timer
    /// visible from the moment `begin()` is called instead of waiting for
    /// TTS to finish.
    var isInEventLoop: Bool {
        switch self {
        case .briefing,
             .eventOpener, .eventListening,
             .generalOpener, .generalListening,
             .driveByOpener, .driveByListening:
            return true
        default:
            return false
        }
    }

    var label: String {
        switch self {
        case .idle:                       return "Bereit"
        case .briefing:                   return "Briefing"
        case .eventOpener(_, let i):      return "Termin \(i + 1) — Opener"
        case .eventListening(_, let i):   return "Termin \(i + 1) — Hören"
        case .generalOpener:              return "Abschnitt — Opener"
        case .generalListening:           return "Abschnitt — Hören"
        case .driveByOpener:              return "Drive-by"
        case .driveByListening:           return "Drive-by — Hören"
        case .confirmingTodos:            return "Aufgaben prüfen"
        case .ingesting:                  return "Lade hoch"
        case .done:                       return "Fertig"
        case .failed(let msg):            return "Fehler: \(msg)"
        }
    }
}
