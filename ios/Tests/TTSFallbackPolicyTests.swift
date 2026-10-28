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

    private static func decide(
        error: any Error = SampleError.rejected,
        language: String,
        stemFor: @escaping @Sendable (String) -> String?
    ) -> FallbackDecision {
        TTSFallbackPolicy.decide(
            error: error,
            language: language,
            preferences: TTSFallbackPolicy.Preferences(preferredPiperStem: stemFor))
    }

    @Test("a supplied Piper stem is returned exactly", arguments: languages)
    func returnsSuppliedStem(language: String) {
        let decision = Self.decide(language: language) { _ in "voice-Stem_01" }

        #expect(decision == .usePiper(stem: "voice-Stem_01"))
    }

    @Test("a nil stem selects Apple", arguments: languages)
    func nilStemSelectsApple(language: String) {
        let decision = Self.decide(language: language) { _ in nil }

        #expect(decision == .useApple)
    }

    @Test("the language reaches preferences unchanged when a stem is found", arguments: languages)
    func forwardsLanguageToStem(language: String) {
        let decision = Self.decide(language: language) { "stem<\($0)>" }

        #expect(decision == .usePiper(stem: "stem<\(language)>"))
    }

    @Test("the language reaches preferences unchanged when no stem is found", arguments: languages)
    func forwardsLanguageToNilStemLookup(language: String) {
        // Only the exact language yields nil; any altered value would
        // produce a Piper stem instead.
        let decision = Self.decide(language: language) { $0 == language ? nil : "altered" }

        #expect(decision == .useApple)
    }

    @Test("the error does not change a Piper decision", arguments: errors)
    func errorIgnoredWithStem(name: String, error: any Error) {
        let decision = Self.decide(error: error, language: "en") { _ in "en_US-lessac-medium" }

        #expect(decision == .usePiper(stem: "en_US-lessac-medium"), "\(name)")
        #expect(decision != .giveUp, "\(name)")
    }

    @Test("the error does not change an Apple decision", arguments: errors)
    func errorIgnoredWithoutStem(name: String, error: any Error) {
        let decision = Self.decide(error: error, language: "de-DE") { _ in nil }

        #expect(decision == .useApple, "\(name)")
        #expect(decision != .giveUp, "\(name)")
    }
}
