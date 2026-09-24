import Foundation

// Routes a request to speak in language X to the right TTS engine.
// The user's `selectedVoiceID(for:)` is the source of truth — its prefix
// determines the engine:
//
//   • `voxtral:<id>` → VoxtralTTS (server-mediated, requires Tailscale)
//   • `piper:<stem>` → PiperTTS (bundled VITS via sherpa-onnx, on-device)
//   • anything else  → AppleSpeechTTS (system AVSpeechSynthesizer)
//   • nothing stored → AppleSpeechTTS (default; AppleSpeechTTS auto-picks
//                       the best installed Premium voice)
//
// If the user has selected a Piper voice but the bundled assets are
// missing (bootstrap script not run, or a previously-installed voice
// was removed from the bundle), we fall back to `AppleSpeechTTS` rather
// than fail silent — the picker UI surfaces the missing-assets state
// explicitly, but the walkthrough keeps speaking.
//
// Voxtral routing makes no on-device reachability check at registry
// time — that would add a network hop to every utterance and the
// non-throwing `speak(...)` already logs+swallows failures. Slice 05
// will add a `TTSFallbackPolicy` that re-dispatches a failed Voxtral
// utterance through Piper or Apple within the same call.

public enum VoiceRegistry {
    public static func engine(for language: String) -> any TTSEngine {
        if VoicePreferences.isVoxtralVoiceID(VoicePreferences.selectedVoiceID(for: language)) {
            return VoxtralTTS.shared
        }
        if let stem = VoicePreferences.selectedPiperStem(for: language),
           PiperTTS.assets(forStem: stem) != nil {
            return PiperTTS.shared
        }
        return AppleSpeechTTS.shared
    }
}
