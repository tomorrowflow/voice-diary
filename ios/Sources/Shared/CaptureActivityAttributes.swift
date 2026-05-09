import ActivityKit
import Foundation

// Shared between the main app target (which starts/updates the activity)
// and the widget extension (which renders the lock-screen + Dynamic
// Island layouts). This file is added to BOTH targets via project.yml.

public struct CaptureActivityAttributes: ActivityAttributes, Sendable {
    /// What's currently happening — surfaces in the Dynamic Island as
    /// the canonical state indicator (per the design transcript decision
    /// to make the island THE anchor for "is the mic open / who's
    /// talking?").
    public enum Kind: String, Codable, Hashable, Sendable {
        case recording  // drive-by capture
        case speaking   // editor TTS playback
        case listening  // walkthrough waiting on the user
    }

    public struct ContentState: Codable, Hashable, Sendable {
        public var startedAt: Date
        public var elapsedSeconds: Int
        public var kind: Kind

        public init(startedAt: Date,
                    elapsedSeconds: Int,
                    kind: Kind = .recording) {
            self.startedAt = startedAt
            self.elapsedSeconds = elapsedSeconds
            self.kind = kind
        }
    }

    public init() {}
}
