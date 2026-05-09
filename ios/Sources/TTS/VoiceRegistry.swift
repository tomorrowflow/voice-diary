import Foundation

// Routes a request to speak in language X to the right TTS engine.
// The user's `selectedVoiceID(for:)` is the source of truth — its prefix
// determines the engine:
//
//   • `piper:<stem>` → PiperTTS (bundled VITS via sherpa-onnx)
//   • anything else  → AppleSpeechTTS (system AVSpeechSynthesizer)
//   • nothing stored → AppleSpeechTTS (default; AppleSpeechTTS auto-picks
//                       the best installed Premium voice)
//
// If the user has selected a Piper voice but the bundled assets are
// missing (bootstrap script not run, or a previously-installed voice
// was removed from the bundle), we fall back to `AppleSpeechTTS` rather
// than fail silent — the picker UI surfaces the missing-assets state
// explicitly, but the walkthrough keeps speaking.

public enum VoiceRegistry {
    public static func engine(for language: String) -> any TTSEngine {
        if let stem = VoicePreferences.selectedPiperStem(for: language),
           PiperTTS.assets(forStem: stem) != nil {
            return PiperTTS.shared
        }
        return AppleSpeechTTS.shared
    }
}
