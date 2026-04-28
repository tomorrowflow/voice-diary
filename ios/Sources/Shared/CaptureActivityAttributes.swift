import ActivityKit
import Foundation

// Shared between the main app target (which starts/updates the activity)
// and the widget extension (which renders the lock-screen + Dynamic
// Island layouts). This file is added to BOTH targets via project.yml.

public struct CaptureActivityAttributes: ActivityAttributes, Sendable {
    public struct ContentState: Codable, Hashable, Sendable {
        public var startedAt: Date
        public var elapsedSeconds: Int

        public init(startedAt: Date, elapsedSeconds: Int) {
            self.startedAt = startedAt
            self.elapsedSeconds = elapsedSeconds
        }
    }

    public init() {}
}
