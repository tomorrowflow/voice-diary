import Foundation

// Picks the transcript excerpt shown under a todo on the CLOSING
// confirmation card: a five-sentence window around the phrase the todo
// came from, plus the range of that phrase inside the window so the view
// can emphasise it.
//
// Pure-logic, no SwiftUI. Tested in `TranscriptExcerptTests`.

public enum TranscriptExcerpt {

    /// The selected window. `highlightRange` indexes into `text` and is
    /// `nil` when the phrase couldn't be located inside the window, in
    /// which case the caller still renders the window without a highlight.
    public struct Selection: Equatable, Sendable {
        public let text: String
        public let highlightRange: Range<String.Index>?
    }

    /// Number of sentences in the excerpt window.
    private static let windowSize = 5

    /// Build the excerpt for a todo. The phrase to find is the verbatim
    /// `sourceQuote` when it is non-blank (always exact for explicit
    /// todos; populated by the LLM for implicit ones when it complied),
    /// otherwise `candidateText`. Returns `nil` when the transcript has
    /// no sentences.
    public static func select(
        transcript: String,
        sourceQuote: String?,
        candidateText: String
    ) -> Selection? {
        let needle = (sourceQuote?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap {
            $0.isEmpty ? nil : $0
        } ?? candidateText

        // The corrected transcripts are usually one long paragraph, so
        // sentence-split on .!? rather than \n.
        let lines = sentences(in: transcript)
        guard !lines.isEmpty else { return nil }

        let lowerLines = lines.map { $0.lowercased() }
        let lowerNeedle = needle.lowercased()

        var matchIdx = lowerLines.firstIndex { $0.contains(lowerNeedle) }
        if matchIdx == nil {
            // Token-overlap fallback for paraphrased implicit todos.
            matchIdx = bestTokenOverlap(needle: lowerNeedle, lines: lowerLines)
        }

        // Always show 5 sentences centred on the match (or the tail of the
        // transcript when no match could be located).
        let center = matchIdx ?? max(lines.count - 1, 0)
        let start = max(center - 2, 0)
        let end = min(start + windowSize, lines.count)
        let actualStart = max(end - windowSize, 0)
        let joined = lines[actualStart..<end].joined(separator: " ")

        if let matchIdx,
           matchIdx >= actualStart, matchIdx < end,
           let span = locate(needle: needle, in: joined) {
            return Selection(text: joined, highlightRange: span)
        }
        return Selection(text: joined, highlightRange: nil)
    }

    /// Sentence-split a transcript on `.`, `!`, `?`. Strips empties and
    /// surrounding whitespace.
    static func sentences(in text: String) -> [String] {
        var out: [String] = []
        var current = ""
        for ch in text {
            current.append(ch)
            if ch == "." || ch == "!" || ch == "?" {
                let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { out.append(trimmed) }
                current = ""
            }
        }
        let tail = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { out.append(tail) }
        return out
    }

    /// Cheap fuzzy match: split the needle into tokens (lowercased,
    /// length ≥ 4) and pick the line with the highest token-presence
    /// count. Returns nil when no line shares any meaningful tokens.
    private static func bestTokenOverlap(needle: String, lines: [String]) -> Int? {
        let tokens = needle
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 4 }
        guard !tokens.isEmpty else { return nil }

        var bestIdx: Int?
        var bestScore = 0
        for (i, line) in lines.enumerated() {
            let score = tokens.reduce(0) { $0 + (line.contains($1) ? 1 : 0) }
            if score > bestScore {
                bestScore = score
                bestIdx = i
            }
        }
        return bestScore >= 1 ? bestIdx : nil
    }

    /// Locate a substring case-insensitively. Returns the range over
    /// the *original* (cased) string so the returned slice preserves
    /// the transcript's casing.
    private static func locate(needle: String, in haystack: String) -> Range<String.Index>? {
        haystack.range(of: needle, options: .caseInsensitive)
    }
}
