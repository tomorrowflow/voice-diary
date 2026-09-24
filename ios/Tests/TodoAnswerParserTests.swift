import Foundation
import Testing
@testable import VoiceDiary

@Suite("TodoAnswerParser")
struct TodoAnswerParserTests {

    @Test("German confirm tokens map to .confirm")
    func germanConfirm() {
        for s in ["Ja", "ja, bitte", "Stimmt.", "Klar", "passt schon",
                  "ja klar", "ok", "übernehmen"] {
            #expect(TodoAnswerParser.parse(s) == .confirm,
                    "expected confirm for \"\(s)\"")
        }
    }

    @Test("English confirm tokens map to .confirm")
    func englishConfirm() {
        for s in ["yes", "Yeah!", "yep", "sure", "correct", "save it"] {
            #expect(TodoAnswerParser.parse(s) == .confirm,
                    "expected confirm for \"\(s)\"")
        }
    }

    @Test("German + English reject tokens map to .reject")
    func reject() {
        for s in ["Nein", "nö", "nee", "weglassen", "verwerfen",
                  "no", "nope", "skip", "drop it", "no thanks"] {
            #expect(TodoAnswerParser.parse(s) == .reject,
                    "expected reject for \"\(s)\"")
        }
    }

    @Test("'anders' / 'rephrase' alone returns .unknown so the UI stays open")
    func switchToRefine() {
        #expect(TodoAnswerParser.parse("anders") == .unknown)
        #expect(TodoAnswerParser.parse("rephrase") == .unknown)
        #expect(TodoAnswerParser.parse("ändern") == .unknown)
    }

    @Test("Long free-form answer is treated as the refined task")
    func refineFromLongAnswer() {
        let outcome = TodoAnswerParser.parse("Stephan morgen früh anrufen wegen der Demo")
        switch outcome {
        case .refine(let s):
            #expect(s.localizedCaseInsensitiveContains("stephan"))
            #expect(s.localizedCaseInsensitiveContains("demo"))
        default:
            Issue.record("expected .refine")
        }
    }

    @Test("Leading 'ja' followed by extra detail produces a refinement")
    func confirmThenDetail() {
        let outcome = TodoAnswerParser.parse("Ja, aber bitte nur das Deck schicken nicht das Briefing")
        switch outcome {
        case .refine(let s):
            #expect(s.localizedCaseInsensitiveContains("deck"))
        default:
            Issue.record("expected .refine for qualified yes")
        }
    }

    @Test("Hesitation markers are stripped before parsing")
    func hesitationStripping() {
        #expect(TodoAnswerParser.parse("ähm ja") == .confirm)
        #expect(TodoAnswerParser.parse("uhm no") == .reject)
    }
}
