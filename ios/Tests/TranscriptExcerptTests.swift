import Foundation
import Testing
@testable import VoiceDiary

@Suite("TranscriptExcerpt")
struct TranscriptExcerptTests {

    /// "Sentence 1. Sentence 2. … Sentence n."
    private func transcript(_ count: Int) -> String {
        (1...count).map { "Sentence \($0)." }.joined(separator: " ")
    }

    /// The window text for sentences `range` of `transcript(_:)`.
    private func window(_ range: ClosedRange<Int>) -> String {
        range.map { "Sentence \($0)." }.joined(separator: " ")
    }

    private func select(
        _ transcript: String,
        quote: String? = nil,
        text: String
    ) -> TranscriptExcerpt.Selection? {
        TranscriptExcerpt.select(
            transcript: transcript, sourceQuote: quote, candidateText: text)
    }

    // MARK: - Windowing

    @Test("A match in the first sentence shows sentences 1-5")
    func firstWindow() throws {
        let ex = try #require(select(transcript(9), text: "Sentence 1"))
        #expect(ex.text == window(1...5))
        #expect(ex.highlightRange.map { String(ex.text[$0]) } == "Sentence 1")
    }

    @Test("A match in the middle is centred: two sentences before, two after")
    func middleWindow() throws {
        let ex = try #require(select(transcript(9), text: "Sentence 5"))
        #expect(ex.text == window(3...7))
        #expect(ex.highlightRange.map { String(ex.text[$0]) } == "Sentence 5")
    }

    @Test("A match in the last sentence clamps the window to the final five")
    func lastWindow() throws {
        let ex = try #require(select(transcript(9), text: "Sentence 9"))
        #expect(ex.text == window(5...9))
        #expect(ex.highlightRange.map { String(ex.text[$0]) } == "Sentence 9")
    }

    @Test("A match near the end is clamped so the window still holds five sentences")
    func nearEndWindow() throws {
        let ex = try #require(select(transcript(9), text: "Sentence 8"))
        #expect(ex.text == window(5...9))
    }

    @Test("Without a match the window is the transcript tail, unhighlighted")
    func unmatchedTail() throws {
        let ex = try #require(select(transcript(9), text: "zzz"))
        #expect(ex.text == window(5...9))
        #expect(ex.highlightRange == nil)
    }

    @Test("A transcript shorter than the window is returned whole")
    func shortTranscript() throws {
        let ex = try #require(select(transcript(3), text: "Sentence 2"))
        #expect(ex.text == window(1...3))
        #expect(ex.highlightRange.map { String(ex.text[$0]) } == "Sentence 2")
    }

    // MARK: - Needle selection

    @Test("The source quote wins over the candidate text")
    func sourceQuotePreferred() throws {
        let ex = try #require(select(
            transcript(9), quote: "Sentence 7", text: "Sentence 2"))
        #expect(ex.text == window(5...9))
        #expect(ex.highlightRange.map { String(ex.text[$0]) } == "Sentence 7")
    }

    @Test("A blank source quote falls back to the candidate text")
    func blankQuoteFallsBack() throws {
        for quote in [nil, "", "  \n "] as [String?] {
            let ex = try #require(select(
                transcript(9), quote: quote, text: "Sentence 2"))
            #expect(ex.text == window(1...5), "quote: \(String(describing: quote))")
        }
    }

    @Test("The source quote is trimmed before matching")
    func quoteIsTrimmed() throws {
        let ex = try #require(select(
            transcript(9), quote: "  Sentence 5\n", text: "zzz"))
        #expect(ex.text == window(3...7))
        #expect(ex.highlightRange.map { String(ex.text[$0]) } == "Sentence 5")
    }

    @Test("Exact matching is case-insensitive and highlights the original casing")
    func caseInsensitiveHighlight() throws {
        let t = "Guten Morgen. Ich muss ANDREAS Anrufen wegen Montag. Danke."
        let ex = try #require(select(t, text: "andreas anrufen"))
        #expect(ex.text == t)
        #expect(ex.highlightRange.map { String(ex.text[$0]) } == "ANDREAS Anrufen")
    }

    @Test("The first sentence containing the needle wins")
    func firstExactMatchWins() throws {
        let t = (["Budget zuerst."] + (2...8).map { "Satz \($0)." } + ["Budget zuletzt."])
            .joined(separator: " ")
        let ex = try #require(select(t, text: "budget"))
        #expect(ex.text.hasPrefix("Budget zuerst."))
        #expect(ex.highlightRange.map { String(ex.text[$0]) } == "Budget")
    }

    // MARK: - Token overlap

    @Test("A paraphrase falls back to the sentence sharing the most tokens")
    func tokenOverlapPicksBestSentence() throws {
        let t = [
            "Heute war viel los.",
            "Die Sitzung dauerte lange.",
            "Wir sprachen über das Budget für Marketing.",
            "Dann gab es Mittagessen.",
            "Am Ende noch ein Anruf.",
            "Wetter war schön.",
            "Ich ging nach Hause.",
        ].joined(separator: " ")
        let ex = try #require(select(t, text: "Marketing Budget prüfen"))
        // Match is sentence 3 (index 2) → window is sentences 1-5.
        #expect(ex.text.hasPrefix("Heute war viel los."))
        #expect(ex.text.hasSuffix("Am Ende noch ein Anruf."))
        // The paraphrase isn't a substring, so nothing is highlighted.
        #expect(ex.highlightRange == nil)
    }

    @Test("Token overlap ignores tokens shorter than four characters")
    func shortTokensIgnored() throws {
        let t = transcript(9)
        // "ich", "und", "zu" are all too short: no match → tail window.
        let ex = try #require(select(t, text: "ich und zu"))
        #expect(ex.text == window(5...9))
        #expect(ex.highlightRange == nil)
    }

    @Test("Ties in token overlap go to the earliest sentence")
    func tokenOverlapTieGoesToFirst() throws {
        let t = (["Anruf bei Andreas."] + (2...8).map { "Satz \($0)." } + ["Anruf bei Andreas."])
            .joined(separator: " ")
        let ex = try #require(select(t, text: "Andreas später anrufen Anruf"))
        #expect(ex.text.hasPrefix("Anruf bei Andreas."))
    }

    // MARK: - Empty input

    @Test("An empty or whitespace-only transcript yields no excerpt")
    func emptyTranscript() {
        #expect(select("", text: "Anruf") == nil)
        #expect(select("  \n\t ", text: "Anruf") == nil)
    }

    @Test("An empty needle matches nothing, so it shows the tail with no highlight")
    func emptyNeedle() throws {
        let ex = try #require(select(transcript(9), text: ""))
        #expect(ex.text == window(5...9))
        #expect(ex.highlightRange == nil)
    }

    // MARK: - Sentence splitting

    @Test("Sentences split on . ! ? and keep an unterminated tail")
    func sentenceSplitting() {
        #expect(TranscriptExcerpt.sentences(in: "Eins. Zwei! Drei?  Vier ohne Punkt")
                == ["Eins.", "Zwei!", "Drei?", "Vier ohne Punkt"])
    }

    @Test("Sentence splitting drops empties and whitespace")
    func sentenceSplittingTrims() {
        #expect(TranscriptExcerpt.sentences(in: "  \n Eins.\n\n Zwei.  ") == ["Eins.", "Zwei."])
        #expect(TranscriptExcerpt.sentences(in: "").isEmpty)
    }
}
