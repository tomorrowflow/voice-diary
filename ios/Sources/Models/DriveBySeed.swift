import Foundation

// On-disk record for a single note capture (M2). Surfaced in the
// evening walkthrough at the matching event time (M10).
//
// One pause/resume cycle during capture produces an additional chunk:
// the m4a is finalised at pause, a fresh m4a starts at resume, both
// live in the same `driveby_seeds/{ts}/` directory. Legacy single-shot
// recordings have `chunks == nil`; multi-chunk recordings populate the
// array (first entry mirrors `audio_file_url` / `transcript` /
// `duration_seconds` so callers that only know about the legacy fields
// still play / read the first chunk correctly).

public struct VoiceNoteChunk: Codable, Sendable, Hashable, Identifiable {
    /// File name relative to the recording directory (e.g. `audio.m4a`,
    /// `audio_002.m4a`). Resolved to a URL by callers that know the
    /// directory.
    public var filename: String
    public var duration_seconds: Double
    public var language: String
    public var transcript: String

    public var id: String { filename }

    public init(
        filename: String,
        duration_seconds: Double,
        language: String,
        transcript: String
    ) {
        self.filename = filename
        self.duration_seconds = duration_seconds
        self.language = language
        self.transcript = transcript
    }
}

public struct VoiceNote: Codable, Sendable, Identifiable {
    public var seed_id: String
    public var captured_at: Date
    public var duration_seconds: Double
    public var language: String
    public var transcript: String
    public var audio_file_url: URL
    /// Multi-chunk recordings list each pause/resume span here. Nil for
    /// legacy single-shot recordings — callers should treat that as a
    /// one-element array containing the legacy fields.
    public var chunks: [VoiceNoteChunk]?

    public var id: String { seed_id }

    public init(
        seed_id: String,
        captured_at: Date,
        duration_seconds: Double,
        language: String,
        transcript: String,
        audio_file_url: URL,
        chunks: [VoiceNoteChunk]? = nil
    ) {
        self.seed_id = seed_id
        self.captured_at = captured_at
        self.duration_seconds = duration_seconds
        self.language = language
        self.transcript = transcript
        self.audio_file_url = audio_file_url
        self.chunks = chunks
    }
}
