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
    /// Inbox slot for actions raised by the App Intent / lock-screen widget.
    /// Values: "toggle", "start", "stop". The host app consumes this on
    /// `scenePhase == .active`. Cleared after dispatch.
    public static let pendingActionKey = "capturePendingAction"
    public static let pendingActionAtKey = "capturePendingActionAt"
}

/// Helpers for cross-process action handoff (App Intent + Widget Link → app).
public enum CaptureIntentInbox {
    public enum Action: String, Sendable {
        case toggle, start, stop
    }

    /// Darwin notification name fired when a new action is written. Any
    /// process with this name registered will be woken regardless of
    /// whether it owns the active scene. Used to bridge "app already in
    /// foreground" scenarios where SwiftUI's scenePhase doesn't transition.
    public static let darwinNotificationName = "com.tomorrowflow.voice-diary.captureIntent"

    /// Drop an action into the App Group inbox. Safe to call from any
    /// process that has the App Group entitlement (host app, App Intent
    /// extension, widget extension).
    public static func write(_ action: Action) {
        guard let defaults = UserDefaults(suiteName: AppGroup.identifier) else { return }
        defaults.set(action.rawValue, forKey: AppGroup.pendingActionKey)
        defaults.set(Date().timeIntervalSince1970, forKey: AppGroup.pendingActionAtKey)
        defaults.synchronize()
        postDarwin()
    }

    /// Atomically read + clear the pending action. Called by the host app
    /// once it's foreground and ready to act on it. Stale entries (older
    /// than 30 s) are dropped — they're nearly always orphaned.
    public static func consume() -> Action? {
        guard let defaults = UserDefaults(suiteName: AppGroup.identifier),
              let raw = defaults.string(forKey: AppGroup.pendingActionKey),
              let action = Action(rawValue: raw) else {
            return nil
        }
        let writtenAt = defaults.double(forKey: AppGroup.pendingActionAtKey)
        defaults.removeObject(forKey: AppGroup.pendingActionKey)
        defaults.removeObject(forKey: AppGroup.pendingActionAtKey)
        if writtenAt > 0,
           Date().timeIntervalSince1970 - writtenAt > 30 {
            return nil
        }
        return action
    }

    private static func postDarwin() {
        let name = CFNotificationName(darwinNotificationName as CFString)
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            name,
            nil,  // object
            nil,  // userInfo
            true  // deliverImmediately
        )
    }
}
