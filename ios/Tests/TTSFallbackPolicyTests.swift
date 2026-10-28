import Foundation
import Testing
@testable import VoiceDiary

// `TTSFallbackPolicy.decide` is the V1 rule for "Voxtral failed on one
// utterance, what now?": every failure falls back to Piper when
// `Preferences.preferredPiperStem` yields a stem for the language, and to
// Apple speech otherwise. The error is ignored and `.giveUp` is never
// returned today.
//
// Every test injects a fake `Preferences`, so none reads `VoicePreferences`,
// the bundled Piper assets, audio, or the network.

@Suite("TTSFallbackPolicy")
struct TTSFallbackPolicyTests {
    private enum SampleError: Error {
        case rejected
    }

    private static let errors: [(name: String, error: any Error)] = [
        ("URLError timeout", URLError(.timedOut)),
        ("URLError offline", URLError(.notConnectedToInternet)),
        ("NSError 401", NSError(domain: "VoxtralTTS", code: 401)),
        ("CancellationError", CancellationError()),
        ("custom enum", SampleError.rejected),
    ]

    private static let languages = ["de-DE", "en", "xx-unknown"]

    @Test("a supplied Piper stem is returned exactly", arguments: languages)
    func returnsSuppliedStem(language: String) {
        let preferences = TTSFallbackPolicy.Preferences(preferredPiperStem: { _ in "voice-Stem_01" })

        let decision = TTSFallbackPolicy.decide(
            error: SampleError.rejected, language: language, preferences: preferences)

        #expect(decision == .usePiper(stem: "voice-Stem_01"))
    }

    @Test("a nil stem selects Apple", arguments: languages)
    func nilStemSelectsApple(language: String) {
        let preferences = TTSFallbackPolicy.Preferences(preferredPiperStem: { _ in nil })

        let decision = TTSFallbackPolicy.decide(
            error: SampleError.rejected, language: language, preferences: preferences)

        #expect(decision == .useApple)
    }

    @Test("the language reaches preferences unchanged when a stem is found", arguments: languages)
    func forwardsLanguageToStem(language: String) {
        let preferences = TTSFallbackPolicy.Preferences(preferredPiperStem: { "stem<\($0)>" })

        let decision = TTSFallbackPolicy.decide(
            error: SampleError.rejected, language: language, preferences: preferences)

        #expect(decision == .usePiper(stem: "stem<\(language)>"))
    }

    @Test("the language reaches preferences unchanged when no stem is found", arguments: languages)
    func forwardsLanguageWhenNoStem(language: String) {
        // Only the exact language yields nil; any altered value would
        // produce a Piper stem instead.
        let preferences = TTSFallbackPolicy.Preferences(preferredPiperStem: { $0 == language ? nil : "altered" })

        let decision = TTSFallbackPolicy.decide(
            error: SampleError.rejected, language: language, preferences: preferences)

        #expect(decision == .useApple)
    }

    @Test("a stem is chosen per language, not shared across languages")
    func stemFollowsLanguage() {
        let preferences = TTSFallbackPolicy.Preferences(preferredPiperStem: { language in
            language == "de-DE" ? "de_DE-thorsten-medium" : nil
        })

        #expect(TTSFallbackPolicy.decide(error: SampleError.rejected, language: "de-DE", preferences: preferences)
            == .usePiper(stem: "de_DE-thorsten-medium"))
        #expect(TTSFallbackPolicy.decide(error: SampleError.rejected, language: "en", preferences: preferences)
            == .useApple)
        #expect(TTSFallbackPolicy.decide(error: SampleError.rejected, language: "xx-unknown", preferences: preferences)
            == .useApple)
    }

    @Test("the error does not change a Piper decision", arguments: errors)
    func errorIgnoredWithStem(name: String, error: any Error) {
        let preferences = TTSFallbackPolicy.Preferences(preferredPiperStem: { _ in "en_US-lessac-medium" })

        let decision = TTSFallbackPolicy.decide(error: error, language: "en", preferences: preferences)

        #expect(decision == .usePiper(stem: "en_US-lessac-medium"), "\(name)")
        #expect(decision != .giveUp, "\(name)")
    }

    @Test("the error does not change an Apple decision", arguments: errors)
    func errorIgnoredWithoutStem(name: String, error: any Error) {
        let preferences = TTSFallbackPolicy.Preferences(preferredPiperStem: { _ in nil })

        let decision = TTSFallbackPolicy.decide(error: error, language: "de-DE", preferences: preferences)

        #expect(decision == .useApple, "\(name)")
        #expect(decision != .giveUp, "\(name)")
    }
}
