import AVFoundation
import Foundation
import Testing
@testable import VoiceDiary

@Suite("AppleVoicePickerPolicy")
struct AppleVoicePickerPolicyTests {

    private typealias Descriptor = AppleVoicePickerPolicy.Descriptor

    private func voice(
        _ identifier: String,
        language: String,
        name: String,
        quality: AVSpeechSynthesisVoiceQuality = .premium
    ) -> Descriptor {
        Descriptor(identifier: identifier, language: language, name: name, quality: quality)
    }

    /// Identifiers the picker would show for `language`, in order.
    private func shown(_ catalog: [Descriptor], language: String) -> [String] {
        AppleVoicePickerPolicy.ordered(catalog, language: language, describing: { $0 }).map(\.identifier)
    }

    @Test("keeps regional variants of the requested language")
    func regionalVariants() {
        let catalog = [
            voice("de-DE.anna", language: "de-DE", name: "Anna"),
            voice("de-AT.bernd", language: "de-AT", name: "Bernd"),
            voice("de-CH.clara", language: "de-CH", name: "Clara"),
            voice("en-US.dave", language: "en-US", name: "Dave"),
            voice("en-GB.emma", language: "en-GB", name: "Emma"),
        ]
        #expect(shown(catalog, language: "de") == ["de-DE.anna", "de-AT.bernd", "de-CH.clara"])
        #expect(shown(catalog, language: "en") == ["en-US.dave", "en-GB.emma"])
    }

    @Test("a more specific code only matches that region")
    func specificCodeNarrows() {
        let catalog = [
            voice("a", language: "en-US", name: "A"),
            voice("b", language: "en-GB", name: "B"),
        ]
        #expect(shown(catalog, language: "en-GB") == ["b"])
    }

    @Test("drops voices of other languages")
    func nonMatchingLanguages() {
        let catalog = [
            voice("fr", language: "fr-FR", name: "Amelie"),
            voice("es", language: "es-ES", name: "Sabine"),
        ]
        #expect(shown(catalog, language: "de").isEmpty)
        #expect(shown(catalog, language: "en").isEmpty)
    }

    @Test("language matching is a case-sensitive prefix test")
    func caseMismatchedLanguages() {
        let catalog = [
            voice("upper", language: "DE-DE", name: "Upper"),
            voice("mixed", language: "En-us", name: "Mixed"),
            voice("lower", language: "de-DE", name: "Lower"),
        ]
        #expect(shown(catalog, language: "de") == ["lower"])
        #expect(shown(catalog, language: "DE") == ["upper"])
        #expect(shown(catalog, language: "en").isEmpty)
    }

    @Test("a voice whose language merely contains the code is not a match")
    func prefixOnly() {
        let catalog = [voice("x", language: "pt-de", name: "X")]
        #expect(shown(catalog, language: "de").isEmpty)
    }

    @Test("only premium voices are included")
    func premiumOnly() {
        let catalog = [
            voice("default", language: "en-US", name: "A", quality: .default),
            voice("enhanced", language: "en-US", name: "B", quality: .enhanced),
            voice("premium", language: "en-US", name: "C", quality: .premium),
        ]
        #expect(shown(catalog, language: "en") == ["premium"])
    }

    @Test("a catalog without premium voices yields nothing, with no fallback")
    func noPremiumNoFallback() {
        let catalog = [
            voice("default", language: "de-DE", name: "A", quality: .default),
            voice("enhanced", language: "de-DE", name: "B", quality: .enhanced),
        ]
        #expect(shown(catalog, language: "de").isEmpty)
    }

    @Test("an empty catalog yields nothing")
    func emptyCatalog() {
        #expect(shown([], language: "de").isEmpty)
    }

    @Test("orders by name with plain string comparison")
    func sortedByName() {
        let catalog = [
            voice("zoe", language: "en-US", name: "Zoe"),
            voice("alex", language: "en-US", name: "Alex"),
            voice("lower", language: "en-US", name: "alice"),
            voice("mia", language: "en-GB", name: "Mia"),
        ]
        // Uppercase sorts before lowercase under `<`, so "alice" lands last.
        #expect(shown(catalog, language: "en") == ["alex", "mia", "zoe", "lower"])
    }

    @Test("equal names order exactly as a plain sort of the filtered voices")
    func equalNamesMatchPlainSort() {
        let catalog = [
            voice("d", language: "de-DE", name: "Anna"),
            voice("a", language: "de-AT", name: "Anna"),
            voice("c", language: "de-CH", name: "Anna"),
            voice("b", language: "de-DE", name: "Anna"),
            voice("e", language: "de-DE", name: "Zed"),
            voice("f", language: "de-DE", name: "Anna"),
        ]
        let reference = catalog
            .filter { $0.language.hasPrefix("de") && $0.quality == .premium }
            .sorted { $0.name < $1.name }
            .map(\.identifier)
        #expect(shown(catalog, language: "de") == reference)
    }

    // Stand-in for a retained `AVSpeechSynthesisVoice`.
    private final class Row {
        let descriptor: Descriptor
        init(_ descriptor: Descriptor) { self.descriptor = descriptor }
    }

    @Test("returns the caller's own objects, not copies or lookups")
    func identifierToObjectMapping() {
        let beta = Row(voice("b", language: "de-DE", name: "Beta"))
        let alpha = Row(voice("a", language: "de-DE", name: "Alpha"))
        let skipped = Row(voice("skip", language: "de-DE", name: "Gamma", quality: .enhanced))
        let other = Row(voice("en", language: "en-US", name: "Aaron"))

        let result = AppleVoicePickerPolicy.ordered(
            [beta, alpha, skipped, other], language: "de", describing: \.descriptor
        )
        #expect(result.count == 2)
        #expect(result[0] === alpha)
        #expect(result[1] === beta)
    }

    @Test("duplicate identifiers are neither merged nor swapped for another voice")
    func duplicateIdentifiersKeepTheirOwnObjects() {
        let rejected = Row(voice("x", language: "fr-FR", name: "Amelie", quality: .default))
        let first = Row(voice("x", language: "de-DE", name: "Anna"))
        let second = Row(voice("x", language: "de-DE", name: "Bernd"))

        let result = AppleVoicePickerPolicy.ordered(
            [rejected, first, second], language: "de", describing: \.descriptor
        )
        #expect(result.count == 2)
        #expect(result[0] === first)
        #expect(result[1] === second)
    }
}
