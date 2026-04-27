import Foundation

// On-disk record for a single drive-by capture (M2). Surfaced in the
// evening walkthrough at the matching event time (M10).

public struct DriveBySeed: Codable, Sendable, Identifiable {
    public var seed_id: String
    public var captured_at: Date
    public var duration_seconds: Double
    public var language: String
    public var transcript: String
    public var audio_file_url: URL

    public var id: String { seed_id }

    public init(
        seed_id: String,
        captured_at: Date,
        duration_seconds: Double,
        language: String,
        transcript: String,
        audio_file_url: URL
    ) {
        self.seed_id = seed_id
        self.captured_at = captured_at
        self.duration_seconds = duration_seconds
        self.language = language
        self.transcript = transcript
        self.audio_file_url = audio_file_url
    }
}
