import AVFoundation

/// Which installed Apple voices `VoiceSettingsView` offers for a language,
/// and in what order. Pure: it sees synthetic `Descriptor`s, never the
/// installed catalog, so the rule is testable without any voices present.
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

    /// Identifiers of the voices to show for `language`, in display order.
    static func orderedIdentifiers(from voices: [Descriptor], language: String) -> [String] {
        voices
            .filter { $0.language.hasPrefix(language) && $0.quality == .premium }
            .sorted { $0.name < $1.name }
            .map(\.identifier)
    }

    /// Maps ordered identifiers back onto the voice objects they came from,
    /// so rows and preview keep using the real voice. Relies on installed
    /// voice identifiers being unique, as the picker's `ForEach` already does.
    /// An identifier with no matching object is skipped.
    static func resolve<Voice>(
        _ identifiers: [String],
        in voices: [Voice],
        identifier: (Voice) -> String
    ) -> [Voice] {
        var byIdentifier: [String: Voice] = [:]
        for voice in voices where byIdentifier[identifier(voice)] == nil {
            byIdentifier[identifier(voice)] = voice
        }
        return identifiers.compactMap { byIdentifier[$0] }
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
