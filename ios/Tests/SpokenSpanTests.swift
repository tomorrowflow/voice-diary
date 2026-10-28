import Foundation
import Testing
@testable import VoiceDiary

// `[SpokenSpan].flatten()` and `.coalesced()` (`SpokenScript.swift`) turn a
// language-tagged opener script into either one legacy string or the minimal
// list of per-language utterances. Both trim each span with `.whitespaces`
// (spaces, tabs and other Unicode space separators, not newlines), drop spans
// that trim to empty, and join the survivors with a single space.
//
// Expectations are literal strings and (text, language) arrays, so nothing is
// computed with the code under test. `OpenerTemplatesTests` covers the openers
// that feed these helpers; this suite pins the transformation on its own.

@Suite("SpokenSpan")
struct SpokenSpanTests {
    private static func de(_ text: String) -> SpokenSpan { SpokenSpan(text: text, language: "de") }
    private static func en(_ text: String) -> SpokenSpan { SpokenSpan(text: text, language: "en") }

    /// Compares by literal (text, language) pairs so a failure prints readable values.
    private static func pairs(_ spans: [SpokenSpan]) -> [String] {
        spans.map { "\($0.language)|\($0.text)" }
    }

    // MARK: flatten

    @Test("flatten of no spans is the empty string")
    func flattenEmpty() {
        #expect([SpokenSpan]().flatten() == "")
    }

    @Test("flatten drops spans that are only spaces or tabs")
    func flattenWhitespaceOnly() {
        let spans = [Self.de("   "), Self.en("\t"), Self.de(" \t "), Self.en("")]
        #expect(spans.flatten() == "")
    }

    @Test("flatten joins spans with exactly one space")
    func flattenJoinsWithOneSpace() {
        let spans = [Self.de("Guten Morgen,"), Self.en("Weekly Sync"), Self.de("startet gleich.")]
        #expect(spans.flatten() == "Guten Morgen, Weekly Sync startet gleich.")
    }

    @Test("flatten trims surrounding spaces and tabs but keeps internal text and Unicode")
    func flattenTrimsEdgesOnly() {
        let spans = [Self.de("\t  Grüße  aus München \t"), Self.en("  会議 – ☕️  ")]
        #expect(spans.flatten() == "Grüße  aus München 会議 – ☕️")
    }

    @Test("flatten skips an empty span without leaving a double space")
    func flattenSkipsEmptyBetweenSpans() {
        let spans = [Self.de("Hallo"), Self.en("  "), Self.de("Welt")]
        #expect(spans.flatten() == "Hallo Welt")
    }

    @Test("flatten ignores language, so mixed languages come out in order")
    func flattenKeepsOrderAcrossLanguages() {
        let spans = [Self.en("One"), Self.de("Zwei"), Self.en("Three")]
        #expect(spans.flatten() == "One Zwei Three")
    }

    // MARK: coalesced

    @Test("coalesced of no spans is empty")
    func coalescedEmpty() {
        #expect([SpokenSpan]().coalesced().isEmpty)
    }

    @Test("coalesced drops spans that are only spaces or tabs")
    func coalescedWhitespaceOnly() {
        let spans = [Self.de("   "), Self.en("\t"), Self.de(" \t "), Self.en("")]
        #expect(spans.coalesced().isEmpty)
    }

    @Test("coalesced trims surrounding spaces and tabs but keeps internal text and Unicode")
    func coalescedTrimsEdgesOnly() {
        let spans = [Self.de("\t  Grüße  aus München \t"), Self.en("  会議 – ☕️  ")]
        #expect(Self.pairs(spans.coalesced()) == ["de|Grüße  aus München", "en|会議 – ☕️"])
    }

    @Test("coalesced merges adjacent same-language spans with one space")
    func coalescedMergesAdjacentSameLanguage() {
        let spans = [Self.de("Guten"), Self.de(" Morgen, "), Self.de("Lukas.")]
        #expect(Self.pairs(spans.coalesced()) == ["de|Guten Morgen, Lukas."])
    }

    @Test("coalesced keeps a boundary at each language change and preserves order")
    func coalescedKeepsLanguageBoundaries() {
        let spans = [
            Self.de("Dein nächster Termin ist"),
            Self.de("das"),
            Self.en("Quarterly Planning"),
            Self.en("Review"),
            Self.de("um zehn Uhr."),
        ]
        #expect(Self.pairs(spans.coalesced()) == [
            "de|Dein nächster Termin ist das",
            "en|Quarterly Planning Review",
            "de|um zehn Uhr.",
        ])
    }

    @Test("coalesced does not split same-language spans around an empty span")
    func coalescedEmptySpanBetweenMatchingLanguages() {
        let spans = [Self.de("Guten"), Self.en("   "), Self.de("Morgen")]
        #expect(Self.pairs(spans.coalesced()) == ["de|Guten Morgen"])
    }

    @Test("coalesced of alternating languages keeps every span")
    func coalescedAlternatingLanguages() {
        let spans = [Self.en("A"), Self.de("B"), Self.en("C")]
        #expect(Self.pairs(spans.coalesced()) == ["en|A", "de|B", "en|C"])
    }

    @Test("coalesced is idempotent")
    func coalescedIsIdempotent() {
        let spans = [
            Self.de(" Hallo "),
            Self.de("Welt"),
            Self.en(""),
            Self.de("!"),
            Self.en("\tMeeting  Notes "),
            Self.en("今日"),
        ]
        let once = spans.coalesced()
        #expect(Self.pairs(once) == ["de|Hallo Welt !", "en|Meeting  Notes 今日"])
        #expect(once.coalesced() == once)
    }

    @Test("flatten of the coalesced spans equals flatten of the originals")
    func flattenUnaffectedByCoalescing() {
        let spans = [Self.de("Eins"), Self.de("zwei"), Self.en(" "), Self.en("three"), Self.de("vier")]
        #expect(spans.flatten() == "Eins zwei three vier")
        #expect(spans.coalesced().flatten() == "Eins zwei three vier")
    }
}
