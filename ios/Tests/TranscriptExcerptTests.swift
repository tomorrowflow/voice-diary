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

    // MARK: - Window boundary

    /// Six sentences with no shared four-letter tokens, so a query for one
    /// can neither match another exactly nor overlap it.
    private static let boundarySentences = [
        "Apfelkuchen backen.",
        "Brief schreiben.",
        "Computer reparieren.",
        "Dachfenster putzen.",
        "Einkaufsliste ergänzen.",
        "Fahrrad aufpumpen.",
    ]

    /// Where the needle sits in the transcript.
    enum BoundaryMatch {
        case first, last, unmatched
    }

    struct BoundaryCase: CustomTestStringConvertible {
        let count: Int
        let match: BoundaryMatch
        /// Inclusive, 1-based sentences expected in the excerpt.
        let window: ClosedRange<Int>

        var testDescription: String { "\(count) sentences, \(match) match" }
    }

    private static let boundaryCases: [BoundaryCase] = [
        .init(count: 4, match: .first, window: 1...4),
        .init(count: 4, match: .last, window: 1...4),
        .init(count: 5, match: .first, window: 1...5),
        .init(count: 5, match: .last, window: 1...5),
        .init(count: 6, match: .first, window: 1...5),
        .init(count: 6, match: .last, window: 2...6),
        .init(count: 6, match: .unmatched, window: 2...6),
    ]

    @Test("The window holds at most five sentences: whole up to five, sliding from six",
          arguments: boundaryCases)
    func windowBoundary(_ c: BoundaryCase) throws {
        let sentences = Array(Self.boundarySentences.prefix(c.count))
        let transcript = sentences.joined(separator: " ")
        let expected = sentences[(c.window.lowerBound - 1)..<c.window.upperBound]
            .joined(separator: " ")

        let matched: String?
        switch c.match {
        case .first: matched = sentences[0]
        case .last: matched = sentences[c.count - 1]
        case .unmatched: matched = nil
        }
        // Lowercased and without the full stop: matching must be exact
        // enough to find it, and the highlight must keep the original case.
        let query = matched.map { String($0.dropLast()).lowercased() }
            ?? "Quartalsbericht abgeben"

        let ex = try #require(select(transcript, text: query))
        #expect(ex.text == expected)
        if let matched {
            #expect(ex.highlightRange.map { String(ex.text[$0]) } == String(matched.dropLast()))
        } else {
            #expect(ex.highlightRange == nil)
        }
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

    @Test("An unmatched source quote does not fall back to the candidate text")
    func unmatchedQuoteIgnoresCandidate() throws {
        // "Sentence 2" would match sentence 2 (window 1-5), but the
        // non-blank quote is the needle and matches nothing: tail window.
        let ex = try #require(select(
            transcript(9), quote: "Unauffindbarer Beleg", text: "Sentence 2"))
        #expect(ex.text == window(5...9))
        #expect(ex.highlightRange == nil)
    }

    @Test("A blank source quote with the same candidate text matches the candidate")
    func blankQuoteMatchesCandidate() throws {
        let ex = try #require(select(transcript(9), quote: "  ", text: "Sentence 2"))
        #expect(ex.text == window(1...5))
        #expect(ex.highlightRange.map { String(ex.text[$0]) } == "Sentence 2")
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

    /// One sentence with a ZWJ family emoji (7 scalars, 25 UTF-8 bytes, one
    /// grapheme) before the phrase and a decomposed "é" ("e" + U+0301)
    /// inside it, so character, scalar and byte offsets all differ.
    private static let unicodeTranscript =
        "Heute 👨‍👩‍👧‍👦 rufe ich ANDRE\u{301}AS Anrufen wegen Montag. Danke."

    /// The phrase as written in `unicodeTranscript`, original casing.
    private static let unicodePhrase = "ANDRE\u{301}AS Anrufen"

    @Test("Highlight range survives an emoji before and a decomposed accent inside the phrase",
          arguments: [
            (quote: String?.none, text: "andre\u{301}as anrufen"),
            (quote: "  andre\u{301}as anrufen\n", text: "zzz"),
          ])
    func unicodeHighlightRange(quote: String?, text: String) throws {
        try expectUnicodeHighlight(
            in: Self.unicodeTranscript, quote: quote, text: text,
            before: "Heute 👨‍👩‍👧‍👦 rufe ich ")
    }

    /// Three "İ" (U+0130) before the phrase. Lowercasing turns each into
    /// "i" + U+0307: one extra scalar and one extra UTF-8 byte apiece
    /// (2 bytes become 3), though the Character count stays the same. A
    /// range found in `haystack.lowercased()` therefore lands 3 bytes late
    /// when applied to the original excerpt.
    private static let lowercaseShiftTranscript =
        "İİİ rufe ich ANDRE\u{301}AS Anrufen wegen Montag. Danke."

    @Test("Highlight range is taken from the original text even where lowercasing changes its offsets",
          arguments: [
            (quote: String?.none, text: "andre\u{301}as anrufen"),
            (quote: "  andre\u{301}as anrufen\n", text: "zzz"),
          ])
    func lowercasingShiftedHighlightRange(quote: String?, text: String) throws {
        try expectUnicodeHighlight(
            in: Self.lowercaseShiftTranscript, quote: quote, text: text,
            before: "İİİ rufe ich ")
    }

    /// Expects the whole one-window transcript back, with the highlight on
    /// `unicodePhrase` exactly as written and `before` / the shared tail
    /// around it.
    private func expectUnicodeHighlight(
        in transcript: String,
        quote: String?,
        text: String,
        before: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let ex = try #require(
            select(transcript, quote: quote, text: text), sourceLocation: sourceLocation)
        #expect(ex.text == transcript, sourceLocation: sourceLocation)
        let range = try #require(ex.highlightRange, sourceLocation: sourceLocation)
        let slice = String(ex.text[range])
        // `String ==` treats composed and decomposed accents as equal, so
        // compare scalars to pin the exact original representation.
        #expect(Array(slice.unicodeScalars) == Array(Self.unicodePhrase.unicodeScalars),
                sourceLocation: sourceLocation)
        #expect(slice.count == 15, sourceLocation: sourceLocation)
        #expect(ex.text[..<range.lowerBound] == before[...], sourceLocation: sourceLocation)
        #expect(ex.text[range.upperBound...] == " wegen Montag. Danke.",
                sourceLocation: sourceLocation)
    }

    @Test("The first sentence containing the needle wins")
    func firstExactMatchWins() throws {
        let t = (["Budget zuerst."] + (2...8).map { "Satz \($0)." } + ["Budget zuletzt."])
            .joined(separator: " ")
        let ex = try #require(select(t, text: "budget"))
        #expect(ex.text.hasPrefix("Budget zuerst."))
        #expect(ex.highlightRange.map { String(ex.text[$0]) } == "Budget")
    }

    // MARK: - Exact match versus token overlap

    /// First sentences that overlap "Marketing Budget prüfen" without
    /// containing it. The first shares one token. The second shares all
    /// three, tying the exact match on overlap score, so it would win the
    /// earliest-sentence tie-break if overlap were consulted first.
    private static let earlierOverlapSentences = [
        "Budget besprechen.",
        "Prüfen Marketing Budget.",
    ]

    /// Nine sentences: `first`, "Satz 2." … "Satz 8.", then the exact phrase.
    private func collisionTranscript(first: String) -> String {
        ([first] + (2...8).map { "Satz \($0)." } + ["Marketing Budget prüfen."])
            .joined(separator: " ")
    }

    /// Sentences 5-9 of `collisionTranscript(first:)`.
    private let collisionTailWindow = ((5...8).map { "Satz \($0)." } + ["Marketing Budget prüfen."])
        .joined(separator: " ")

    @Test("A later exact match beats an earlier partial overlap",
          arguments: earlierOverlapSentences)
    func exactMatchBeatsEarlierOverlap(first: String) throws {
        let ex = try #require(select(
            collisionTranscript(first: first), text: "Marketing Budget prüfen"))
        #expect(ex.text == collisionTailWindow)
        #expect(ex.highlightRange.map { String(ex.text[$0]) } == "Marketing Budget prüfen")
    }

    @Test("A source quote matching exactly beats an earlier overlap and highlights the original casing",
          arguments: earlierOverlapSentences)
    func exactSourceQuoteBeatsEarlierOverlap(first: String) throws {
        let ex = try #require(select(
            collisionTranscript(first: first),
            quote: "MARKETING BUDGET PRÜFEN",
            text: "Budget"))
        #expect(ex.text == collisionTailWindow)
        #expect(ex.highlightRange.map { String(ex.text[$0]) } == "Marketing Budget prüfen")
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

    /// Nine sentences: a weak one-token overlap first, then "Satz 2." …
    /// "Satz 8.", then a stronger two-token overlap last.
    private let unequalOverlapTranscript = (
        ["Budget besprechen."] + (2...8).map { "Satz \($0)." } + ["Marketing und Budget."]
    ).joined(separator: " ")

    /// Sentences 5-9 of `unequalOverlapTranscript`.
    private let unequalOverlapTailWindow = (
        (5...8).map { "Satz \($0)." } + ["Marketing und Budget."]
    ).joined(separator: " ")

    @Test("A later higher overlap score beats an earlier weaker one")
    func higherOverlapBeatsEarlierWeakOverlap() throws {
        // "Marketing Budget prüfen" is no substring. Sentence 1 shares one
        // token (budget), sentence 9 shares two (marketing, budget): the
        // best score wins, not the first positive one (window 1-5).
        let ex = try #require(select(
            unequalOverlapTranscript, text: "Marketing Budget prüfen"))
        #expect(ex.text == unequalOverlapTailWindow)
        #expect(ex.highlightRange == nil)
    }

    @Test("A source quote's higher overlap beats an earlier weaker one over unrelated candidate text")
    func higherSourceQuoteOverlapBeatsEarlierWeakOverlap() throws {
        let ex = try #require(select(
            unequalOverlapTranscript,
            quote: "Marketing Budget prüfen",
            text: "zzz"))
        #expect(ex.text == unequalOverlapTailWindow)
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

    /// Nine sentences: `first`, then "Satz 2." … "Satz 9.".
    private func boundaryTranscript(first: String) -> String {
        ([first] + (2...9).map { "Satz \($0)." }).joined(separator: " ")
    }

    /// The window text for sentences `range` of `boundaryTranscript(first:)`.
    private func boundaryWindow(_ range: ClosedRange<Int>, first: String) -> String {
        range.map { $0 == 1 ? first : "Satz \($0)." }.joined(separator: " ")
    }

    @Test("A four-character token is enough for token overlap to pick a sentence")
    func fourCharacterTokenCounts() throws {
        // "plan" (4) matches the first sentence; "prüfen" matches nothing,
        // and the query is not a substring, so this is overlap, not exact.
        let first = "Plan heute."
        let ex = try #require(select(
            boundaryTranscript(first: first), text: "Plan prüfen"))
        #expect(ex.text == boundaryWindow(1...5, first: first))
        #expect(ex.highlightRange == nil)
    }

    @Test("A three-character token is ignored, so the tail window shows")
    func threeCharacterTokenIgnored() throws {
        // Same shape as above, but "tag" (3) is too short to count and
        // "prüfen" matches nothing: no overlap, so the transcript tail.
        let first = "Tag heute."
        let ex = try #require(select(
            boundaryTranscript(first: first), text: "Tag prüfen"))
        #expect(ex.text == boundaryWindow(5...9, first: first))
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
