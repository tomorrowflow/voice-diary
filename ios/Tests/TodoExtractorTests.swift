import Foundation
import Testing
@testable import VoiceDiary

@Suite("TodoExtractor")
struct TodoExtractorTests {

    @Test("German trigger phrases are recognised")
    func germanTriggers() {
        let text = "Das Meeting war gut. Ich muss noch das Board-Deck bis Donnerstag fertigstellen. Außerdem todo: Azure-Zertifikat erneuern."
        let todos = TodoExtractor.extractExplicit(
            text: text, language: "de", sourceSegmentID: "s01"
        )
        #expect(todos.count >= 2)
        #expect(todos.contains { $0.text.localizedCaseInsensitiveContains("board") })
        #expect(todos.contains { $0.text.localizedCaseInsensitiveContains("azure") })
        #expect(todos.allSatisfy { $0.type == "explicit" && $0.status == "Offen" })
        #expect(todos.allSatisfy { $0.source_segment_id == "s01" })
    }

    @Test("English trigger phrases are recognised")
    func englishTriggers() {
        let text = "Solid meeting. I need to follow up with the legal team. We should also draft the Q2 plan tomorrow."
        let todos = TodoExtractor.extractExplicit(
            text: text, language: "en", sourceSegmentID: "s02"
        )
        #expect(todos.count == 2)
        #expect(todos.contains { $0.text.localizedCaseInsensitiveContains("legal") })
        #expect(todos.contains { $0.text.localizedCaseInsensitiveContains("q2") })
    }

    @Test("Tomorrow / übermorgen / weekday → due date")
    func dueDates() {
        let morgen = TodoExtractor.parseDueDate(in: "Bericht morgen senden", language: "de")
        #expect(morgen != nil)

        let uebermorgen = TodoExtractor.parseDueDate(in: "Doku übermorgen prüfen", language: "de")
        #expect(uebermorgen != nil)
        #expect(morgen != uebermorgen)

        let donnerstag = TodoExtractor.parseDueDate(in: "Meeting bis Donnerstag", language: "de")
        #expect(donnerstag != nil)

        let iso = TodoExtractor.parseDueDate(in: "deadline 2026-12-15", language: "de")
        #expect(iso == "2026-12-15")
    }

    @Test("text without trigger phrase yields no todos")
    func noTrigger() {
        let text = "Heute war ein produktiver Tag. Wir haben viel besprochen."
        let todos = TodoExtractor.extractExplicit(
            text: text, language: "de", sourceSegmentID: "s01"
        )
        #expect(todos.isEmpty)
    }

    @Test("Hallucination phrases are stripped")
    func hallucinationStrip() {
        let pure = "Vielen Dank fürs Zuschauen. Bis zum nächsten Mal."
        #expect(TodoExtractor.sanitiseForTodos(pure).isEmpty)

        let mixed = "Wir hatten ein gutes Meeting. Vielen Dank fürs Zuschauen."
        let cleaned = TodoExtractor.sanitiseForTodos(mixed)
        #expect(!cleaned.contains("Zuschauen"))
        #expect(cleaned.contains("gutes Meeting"))

        let englishStock = "Thanks for watching, like and subscribe."
        #expect(TodoExtractor.sanitiseForTodos(englishStock).isEmpty)
    }

    @Test("Explicit todos use verbatim source_quote")
    func explicitSourceQuote() {
        let text = "Ich muss noch die Doku an Carsten schicken."
        let todos = TodoExtractor.extractExplicit(
            text: text, language: "de", sourceSegmentID: "s01"
        )
        #expect(todos.count == 1)
        let q = todos.first?.source_quote ?? ""
        #expect(q.lowercased().contains("ich muss"))
        #expect(q.lowercased().contains("doku"))
    }
}
