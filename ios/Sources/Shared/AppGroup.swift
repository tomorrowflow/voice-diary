import Foundation

// Shared between the main app target and the widget extension. Holds the
// App Group identifier and the keys we use in `UserDefaults(suiteName:)`
// for cross-process state.

public enum AppGroup {
    public static let identifier = "group.com.tomorrowflow.voice-diary"
    public static let recordingActiveKey = "captureRecordingActive"
    public static let recordingStartedAtKey = "captureRecordingStartedAt"
    public static let lastSeedTranscriptKey = "lastSeedTranscript"
    public static let lastSeedDurationKey = "lastSeedDurationSeconds"
}
