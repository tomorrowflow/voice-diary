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
        case recording  // note capture
        case speaking   // editor TTS playback
        case listening  // walkthrough waiting on the user
    }

    public struct ContentState: Codable, Hashable, Sendable {
        public var startedAt: Date
        public var elapsedSeconds: Int
        public var kind: Kind
        /// True while the user has paused the session. The widget uses
        /// this to switch from a self-incrementing `Text(timerInterval:)`
        /// (which would tick even while paused) to a static elapsed
        /// snapshot. Default false preserves the schema for any existing
        /// in-flight activity payload.
        public var isPaused: Bool

        public init(startedAt: Date,
                    elapsedSeconds: Int,
                    kind: Kind = .recording,
                    isPaused: Bool = false) {
            self.startedAt = startedAt
            self.elapsedSeconds = elapsedSeconds
            self.kind = kind
            self.isPaused = isPaused
        }

        // Decode tolerates payloads from older builds that didn't include
        // `isPaused`. ActivityKit can carry a state from a pre-update
        // launch into a newer build; missing fields would otherwise fail
        // to decode and orphan the activity.
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.startedAt = try c.decode(Date.self, forKey: .startedAt)
            self.elapsedSeconds = try c.decode(Int.self, forKey: .elapsedSeconds)
            self.kind = try c.decode(Kind.self, forKey: .kind)
            self.isPaused = try c.decodeIfPresent(Bool.self, forKey: .isPaused) ?? false
        }
    }

    public init() {}
}
