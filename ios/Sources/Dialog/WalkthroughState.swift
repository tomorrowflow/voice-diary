import Foundation

// Walkthrough state machine values (SPEC §6.1 / §6.2). The actual
// transition logic lives in `WalkthroughCoordinator`; this file is just
// the data model so views and tests can pattern-match without pulling in
// AVFoundation.

public enum WalkthroughState: Sendable, Equatable {
    case idle
    case briefing
    case eventOpener(index: Int)        // AI speaking the opener for events[index]
    case eventListening(index: Int)     // mic open, recording the user's reflection
    case closingPrompt                  // AI: "Willst du noch etwas zum ganzen Tag sagen?"
    case closingListening               // recording the free-reflection segment
    case ingesting                      // building manifest + handing to SessionUploader
    case done
    case failed(String)
}

public extension WalkthroughState {
    var isListening: Bool {
        switch self {
        case .eventListening, .closingListening: return true
        default: return false
        }
    }

    var isSpeaking: Bool {
        switch self {
        case .briefing, .eventOpener, .closingPrompt: return true
        default: return false
        }
    }

    var label: String {
        switch self {
        case .idle:                 return "Bereit"
        case .briefing:             return "Briefing"
        case .eventOpener(let i):   return "Termin \(i + 1) — Opener"
        case .eventListening(let i): return "Termin \(i + 1) — Hören"
        case .closingPrompt:        return "Abschluss"
        case .closingListening:     return "Freie Reflexion"
        case .ingesting:            return "Lade hoch"
        case .done:                 return "Fertig"
        case .failed(let msg):      return "Fehler: \(msg)"
        }
    }
}
