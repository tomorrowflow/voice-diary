import AVFoundation

/// Which installed Apple voices `VoiceSettingsView` offers for a language,
/// and in what order. Pure: it reads only the `Descriptor` of each voice,
/// never the installed catalog, so the rule is testable without any voices
/// present.
///
/// The rule is exactly: `language.hasPrefix(code)` (case-sensitive, no
/// normalisation), `quality == .premium` (Enhanced and Default tiers sound
/// noticeably worse than Premium and Piper, and the long unfiltered list
/// overwhelms the picker), then ascending `name < name`. There is no
/// deduplication and no fallback when nothing qualifies.
enum AppleVoicePickerPolicy {

    struct Descriptor: Equatable, Sendable {
        let identifier: String
        let language: String
        let name: String
        let quality: AVSpeechSynthesisVoiceQuality
    }

    /// The voices to show for `language`, in display order. Returns the
    /// caller's own elements, so rows and preview keep the real voice
    /// objects and nothing is looked up by identifier.
    static func ordered<Voice>(
        _ voices: [Voice],
        language: String,
        describing describe: (Voice) -> Descriptor
    ) -> [Voice] {
        voices
            .filter {
                let voice = describe($0)
                return voice.language.hasPrefix(language) && voice.quality == .premium
            }
            .sorted { describe($0).name < describe($1).name }
    }
}

extension AppleVoicePickerPolicy.Descriptor {
    init(_ voice: AVSpeechSynthesisVoice) {
        self.init(
            identifier: voice.identifier,
            language: voice.language,
            name: voice.name,
            quality: voice.quality
        )
    }
}
