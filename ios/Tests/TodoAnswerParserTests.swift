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
        let outcome = TodoAnswerParser.parse("Andreas morgen früh anrufen wegen der Demo")
        switch outcome {
        case .refine(let s):
            #expect(s.localizedCaseInsensitiveContains("andreas"))
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

    @Test("Leading 'ja' with three more words still confirms (four-word cap)")
    func confirmAtFourWords() {
        #expect(TodoAnswerParser.parse("ja eins zwei drei") == .confirm)
    }

    @Test("Leading 'ja' with four more words refines to the rest")
    func confirmPastFourWordsRefines() {
        #expect(TodoAnswerParser.parse("ja eins zwei drei vier") == .refine("Eins zwei drei vier"))
    }

    @Test("Leading 'nein' stays a reject past the four-word cap")
    func rejectPastFourWords() {
        #expect(TodoAnswerParser.parse("nein eins zwei drei") == .reject)
        #expect(TodoAnswerParser.parse("nein eins zwei drei vier") == .reject)
    }

    @Test("'anders' with three more words is unknown; with four it refines")
    func switchToRefineAcrossFourWordCap() {
        #expect(TodoAnswerParser.parse("anders eins zwei drei") == .unknown)
        #expect(TodoAnswerParser.parse("anders eins zwei drei vier") == .refine("Anders eins zwei drei vier"))
    }

    @Test("Hesitation markers are stripped before parsing")
    func hesitationStripping() {
        #expect(TodoAnswerParser.parse("ähm ja") == .confirm)
        #expect(TodoAnswerParser.parse("uhm no") == .reject)
    }
}
