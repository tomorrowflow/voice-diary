import Foundation

// User-controlled wake-word toggle. Independent of the on-device-asset
// capability check (`AppleStreamingRecognizer.supportsOnDeviceRecognition`)
// — that's a system fact, this is user intent.
//
// The walkthrough's wake-word path skips opening a listen window when
// either gate is false:
//   1. user disabled it here, or
//   2. the active language has no on-device dictation asset installed.
//
// Stored in plain UserDefaults — same reasoning as `VoicePreferences`:
// presentation preferences, not secrets.

public enum WakeWordPreferences {
    private static let enabledKey = "voicediary.wakeword.enabled"

    /// Default to true so existing users keep the current behaviour.
    /// Devices that never had the German dictation asset installed will
    /// silently no-op the wake-word path (the capability gate handles
    /// that case); they don't need to flip a toggle.
    public static var isEnabled: Bool {
        // `object(forKey:)` lets us tell "never set" (→ default) from
        // "explicitly set to false". `bool(forKey:)` would conflate them.
        guard let stored = UserDefaults.standard.object(forKey: enabledKey) as? Bool else {
            return true
        }
        return stored
    }

    public static func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: enabledKey)
    }
}
