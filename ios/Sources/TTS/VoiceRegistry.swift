import Foundation

// Routes a request to speak in language X to the right TTS engine. For
// M5 there's only one engine (AppleSpeechTTS) and it handles every
// language we care about. M9 (multilingual + Piper) extends this.

public enum VoiceRegistry {
    public static func engine(for _: String) -> any TTSEngine {
        AppleSpeechTTS.shared
    }
}
