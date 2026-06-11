import Foundation

// Lock-screen / Dynamic Island presentation toggles.
//
// The only setting today is whether the Live Activity for a *paused*
// session stays visible. Default: hidden — pausing the app means the
// user has stepped away from the flow, so the banner shouldn't continue
// to claim space on the lock screen. When the user opts in, the paused
// activity stays visible with a frozen counter so they have a single-tap
// way back into the dedicated screen.
//
// Plain UserDefaults — presentation preferences, not secrets. Same
// reasoning as `WakeWordPreferences` + `VoicePreferences`.

public enum LockScreenPreferences {
    private static let showWhenPausedKey = "voicediary.lockscreen.showWhenPaused"

    /// True keeps the Live Activity on the lock screen / Dynamic Island
    /// while the session is paused; false ends it on pause and recreates
    /// it on resume. Defaults to false per the user's stated intent.
    public static var showWhenPaused: Bool {
        // `object(forKey:)` distinguishes "never set" (→ default false)
        // from "explicitly set to false". `bool(forKey:)` would conflate.
        guard let stored = UserDefaults.standard.object(forKey: showWhenPausedKey) as? Bool else {
            return false
        }
        return stored
    }

    public static func setShowWhenPaused(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: showWhenPausedKey)
    }
}
