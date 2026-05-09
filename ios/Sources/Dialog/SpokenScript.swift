import Foundation

// A spoken sentence broken into language-tagged spans, so a German
// opener that contains an English meeting title can route the title to
// the bundled English voice while the surrounding frame stays in the
// German voice. See SPEC §11 (opener templates) + §9 (multilingual
// support) — the per-language voice routing already exists; this type
// is the wire format that carries which fragment goes to which engine.
//
// `language` is the broad routing bucket ("de" / "en") that
// `VoiceRegistry.engine(for:)` understands. Spans whose text trims to
// empty are dropped at speak time, so callers can build scripts without
// worrying about empty fragments.

public struct SpokenSpan: Sendable, Equatable {
    public let text: String
    public let language: String

    public init(text: String, language: String) {
        self.text = text
        self.language = language
    }
}

public extension Array where Element == SpokenSpan {
    /// Concatenate all span texts with single spaces — the legacy
    /// single-language form, used when mixed-language speech is off
    /// or for logging.
    func flatten() -> String {
        map(\.text)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Coalesce neighbouring same-language spans into one. Keeps span
    /// count minimal and avoids two German spans being uttered as two
    /// separate AVSpeech utterances with a tiny gap between them.
    func coalesced() -> [SpokenSpan] {
        var out: [SpokenSpan] = []
        for span in self {
            let trimmed = span.text.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if let last = out.last, last.language == span.language {
                out[out.count - 1] = SpokenSpan(
                    text: last.text + " " + trimmed,
                    language: span.language
                )
            } else {
                out.append(SpokenSpan(text: trimmed, language: span.language))
            }
        }
        return out
    }
}
