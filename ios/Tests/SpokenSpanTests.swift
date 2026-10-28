import Foundation
import Testing
@testable import VoiceDiary

// `[SpokenSpan].flatten()` and `.coalesced()` (`SpokenScript.swift`) turn a
// language-tagged opener script into either one legacy string or the minimal
// list of per-language utterances. Both trim each span with `.whitespaces`
// (spaces, tabs and other Unicode space separators), drop spans that trim to
// empty, and join the survivors with a single space.
//
// Expectations are literal strings and literal span arrays, so nothing is
// computed with the code under test. `OpenerTemplatesTests` covers the openers
// that feed these helpers; this suite pins the transformation on its own.

@Suite("SpokenSpan")
struct SpokenSpanTests {
    private static func de(_ text: String) -> SpokenSpan { SpokenSpan(text: text, language: "de") }
    private static func en(_ text: String) -> SpokenSpan { SpokenSpan(text: text, language: "en") }

    private static let blankSpans = [de("   "), en("\t"), de(" \t "), en("")]
    private static let paddedSpans = [de("\t  Grüße  aus München \t"), en("  会議 – ☕️  ")]

    // MARK: flatten

    @Test("flatten of no spans is the empty string")
    func flattenEmpty() {
        #expect([SpokenSpan]().flatten() == "")
    }

    @Test("flatten drops spans that are only spaces or tabs")
    func flattenWhitespaceOnly() {
        #expect(Self.blankSpans.flatten() == "")
    }

    @Test("flatten joins spans with exactly one space")
    func flattenJoinsWithOneSpace() {
        let spans = [Self.de("Guten Morgen,"), Self.en("Weekly Sync"), Self.de("startet gleich.")]
        #expect(spans.flatten() == "Guten Morgen, Weekly Sync startet gleich.")
    }

    @Test("flatten trims surrounding spaces and tabs but keeps internal text and Unicode")
    func flattenTrimsEdgesOnly() {
        #expect(Self.paddedSpans.flatten() == "Grüße  aus München 会議 – ☕️")
    }

    @Test("flatten skips an empty span without leaving a double space")
    func flattenSkipsEmptyBetweenSpans() {
        let spans = [Self.de("Hallo"), Self.en("  "), Self.de("Welt")]
        #expect(spans.flatten() == "Hallo Welt")
    }

    // MARK: coalesced

    @Test("coalesced of no spans is empty")
    func coalescedEmpty() {
        #expect([SpokenSpan]().coalesced() == [])
    }

    @Test("coalesced drops spans that are only spaces or tabs")
    func coalescedWhitespaceOnly() {
        #expect(Self.blankSpans.coalesced() == [])
    }

    @Test("coalesced trims surrounding spaces and tabs but keeps internal text and Unicode")
    func coalescedTrimsEdgesOnly() {
        #expect(Self.paddedSpans.coalesced() == [Self.de("Grüße  aus München"), Self.en("会議 – ☕️")])
    }

    @Test("coalesced merges adjacent same-language spans with one space")
    func coalescedMergesAdjacentSameLanguage() {
        let spans = [Self.de("Guten"), Self.de(" Morgen, "), Self.de("Lukas.")]
        #expect(spans.coalesced() == [Self.de("Guten Morgen, Lukas.")])
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
        #expect(spans.coalesced() == [
            Self.de("Dein nächster Termin ist das"),
            Self.en("Quarterly Planning Review"),
            Self.de("um zehn Uhr."),
        ])
    }

    @Test("coalesced does not split same-language spans around an empty span")
    func coalescedEmptySpanBetweenMatchingLanguages() {
        let otherLanguage = [Self.de("Guten"), Self.en("   "), Self.de("Morgen")]
        #expect(otherLanguage.coalesced() == [Self.de("Guten Morgen")])

        let sameLanguage = [Self.de("Guten"), Self.de(" \t"), Self.de("Morgen")]
        #expect(sameLanguage.coalesced() == [Self.de("Guten Morgen")])
    }

    @Test("coalesced of alternating languages keeps every span")
    func coalescedAlternatingLanguages() {
        let spans = [Self.en("A"), Self.de("B"), Self.en("C")]
        #expect(spans.coalesced() == [Self.en("A"), Self.de("B"), Self.en("C")])
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
        #expect(once == [Self.de("Hallo Welt !"), Self.en("Meeting  Notes 今日")])
        #expect(once.coalesced() == once)
    }
}
