import Testing
@testable import VoiceDiary

// Projection behind the bearer summary row in ServerSettingsView. The view
// keeps the Keychain read, the localized "(empty)" label and the exact
// `len=<count> · …<suffix>` rendering; these tests pin how a supplied
// string becomes empty versus a Character count and its last four
// Characters. Synthetic strings only: nothing here reads the Keychain,
// and short tokens are shown whole, as before.

@Suite("BearerSummaryProjection")
struct BearerSummaryProjectionTests {
    @Test("an empty string projects to empty")
    func empty() {
        #expect(BearerSummaryProjection("") == .empty)
    }

    @Test("lengths 1 to 5 keep the count and the last four Characters",
          arguments: [
            ("a", 1, "a"),
            ("ab", 2, "ab"),
            ("abc", 3, "abc"),
            ("abcd", 4, "abcd"),
            ("abcde", 5, "bcde"),
          ])
    func shortStrings(token: String, count: Int, suffix: String) {
        #expect(BearerSummaryProjection(token) == .present(count: count, suffix: suffix))
    }

    @Test("a long string keeps its full count and only the last four Characters")
    func longString() {
        let token = String(repeating: "x", count: 60) + "WXYZ"
        #expect(BearerSummaryProjection(token) == .present(count: 64, suffix: "WXYZ"))
    }

    @Test("whitespace counts as Characters and is not trimmed")
    func whitespace() {
        #expect(BearerSummaryProjection("   ") == .present(count: 3, suffix: "   "))
        #expect(BearerSummaryProjection("abc \n") == .present(count: 5, suffix: "bc \n"))
        #expect(BearerSummaryProjection("\n") == .present(count: 1, suffix: "\n"))
    }

    @Test("an emoji is one Character, including a multi-scalar sequence")
    func emoji() {
        #expect(BearerSummaryProjection("ab🙂cd🔑") == .present(count: 6, suffix: "🙂cd🔑"))
        // Family emoji: five scalars joined by ZWJ, one Character.
        #expect(BearerSummaryProjection("k👨‍👩‍👧x") == .present(count: 3, suffix: "k👨‍👩‍👧x"))
        #expect(BearerSummaryProjection("a🇩🇪b🇫🇷c") == .present(count: 5, suffix: "🇩🇪b🇫🇷c"))
    }

    @Test("composed and decomposed Unicode count by grapheme cluster")
    func composedUnicode() {
        let composed = "ab\u{00E9}cd"          // é as one scalar
        let decomposed = "ab\u{0065}\u{0301}cd" // e + combining acute
        #expect(BearerSummaryProjection(composed) == .present(count: 5, suffix: "b\u{00E9}cd"))
        #expect(BearerSummaryProjection(decomposed) == .present(count: 5, suffix: "b\u{0065}\u{0301}cd"))
        // A trailing combining mark stays attached to its base Character.
        #expect(BearerSummaryProjection("tok\u{0065}\u{0301}") == .present(count: 4, suffix: "tok\u{0065}\u{0301}"))
    }
}
