import AVFoundation
import Foundation

// User-selected voice per language (de, en). The stored identifier is one of:
//
//   • An `AVSpeechSynthesisVoice.identifier` (Apple Premium voice), e.g.
//     "com.apple.voice.premium.de-DE.Markus".
//   • A Piper voice ID prefixed with `piper:`, e.g. "piper:de_DE-thorsten-high".
//
// `VoiceRegistry.engine(for:)` inspects the prefix to route to either
// `AppleSpeechTTS` or `PiperTTS`. Storing both kinds in the same key
// removes the need for a separate engine picker — the chosen voice
// determines both the engine *and* which voice within it.
//
// Stored in plain UserDefaults — these are presentation preferences,
// not secrets, and we want them to survive app launches without going
// near Keychain. AppleSpeechTTS / PiperTTS re-read the preference on
// every utterance so changes take effect immediately.

public enum VoicePreferences {
    private static let prefix = "voicediary.tts.voice."
    public static let piperPrefix = "piper:"

    /// Returns the user-chosen voice identifier for `language`, or nil
    /// when none is set / the previously chosen voice is no longer
    /// available (Apple voice uninstalled, Piper bootstrap not run).
    public static func selectedVoiceID(for language: String) -> String? {
        let key = storageKey(for: language)
        guard let stored = UserDefaults.standard.string(forKey: key),
              !stored.isEmpty else { return nil }
        if stored.hasPrefix(piperPrefix) {
            // Drop the preference if the Piper voice it refers to is no
            // longer registered (e.g. we removed it from the bundled list).
            let stem = String(stored.dropFirst(piperPrefix.count))
            if PiperTTS.voice(stem: stem) == nil {
                UserDefaults.standard.removeObject(forKey: key)
                return nil
            }
            return stored
        }
        // Apple voice — drop the preference if the user uninstalled it
        // via Settings → Accessibility so the picker reflects reality.
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

    /// Convenience: if the selected voice for `language` is a Piper
    /// voice, return its stem (without the `piper:` prefix). Returns
    /// nil for Apple voices or no selection.
    public static func selectedPiperStem(for language: String) -> String? {
        guard let id = selectedVoiceID(for: language),
              id.hasPrefix(piperPrefix) else { return nil }
        return String(id.dropFirst(piperPrefix.count))
    }

    public static func isPiperVoiceID(_ identifier: String?) -> Bool {
        identifier?.hasPrefix(piperPrefix) ?? false
    }

    private static func storageKey(for language: String) -> String {
        prefix + String(language.prefix(2)).lowercased()
    }
}
