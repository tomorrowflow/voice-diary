import AVFoundation
import Foundation

// User-selected `AVSpeechSynthesisVoice.identifier` per language (de, en).
// When set, AppleSpeechTTS uses the override and bypasses the
// auto-selection (which picks the first Premium voice it finds).
//
// Stored in plain UserDefaults — these are presentation preferences,
// not secrets, and we want them to survive app launches without going
// near Keychain. The walkthrough coordinator does NOT cache the chosen
// voice; AppleSpeechTTS re-reads the preference on every utterance so
// changes take effect immediately.

public enum VoicePreferences {
    private static let prefix = "voicediary.tts.voice."

    /// Returns the user-chosen voice identifier for `language` (or nil
    /// when none is set / the previously chosen voice is no longer
    /// installed).
    public static func selectedVoiceID(for language: String) -> String? {
        let key = storageKey(for: language)
        guard let stored = UserDefaults.standard.string(forKey: key),
              !stored.isEmpty else { return nil }
        // Voice may have been uninstalled in Settings → Accessibility.
        // Drop the stale preference so the picker reflects reality.
        if AVSpeechSynthesisVoice(identifier: stored) == nil {
            UserDefaults.standard.removeObject(forKey: key)
            return nil
        }
        return stored
    }

    public static func setSelectedVoiceID(_ identifier: String?, for language: String) {
        let key = storageKey(for: language)
        if let identifier, !identifier.isEmpty {
            UserDefaults.standard.set(identifier, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    private static func storageKey(for language: String) -> String {
        prefix + String(language.prefix(2)).lowercased()
    }
}
