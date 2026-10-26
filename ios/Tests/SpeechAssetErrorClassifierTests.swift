import Foundation
import Testing
@testable import VoiceDiary

// Which speech-recognition errors the wake-word "Test" button reads as
// "the language asset isn't installed". Synthetic domain/code pairs only;
// no recognizer runs and no permission is requested.

@Suite("SpeechAssetErrorClassifier")
struct SpeechAssetErrorClassifierTests {
    @Test("the two allowlisted domain/code pairs mean the asset is missing",
          arguments: [
            ("SFSpeechErrorDomain", 7),
            ("kAFAssistantErrorDomain", 203),
          ])
    func missing(domain: String, code: Int) {
        #expect(SpeechAssetErrorClassifier.indicatesMissingAsset(domain: domain, code: code))
    }

    @Test("neighbouring codes and the other domain's code do not",
          arguments: [
            ("SFSpeechErrorDomain", 6),
            ("SFSpeechErrorDomain", 8),
            ("SFSpeechErrorDomain", 203),
            ("kAFAssistantErrorDomain", 202),
            ("kAFAssistantErrorDomain", 204),
            ("kAFAssistantErrorDomain", 7),
          ])
    func adjacentCodes(domain: String, code: Int) {
        #expect(!SpeechAssetErrorClassifier.indicatesMissingAsset(domain: domain, code: code))
    }

    @Test("the no-speech codes from an empty request are not missing",
          arguments: [
            ("kAFAssistantErrorDomain", 1107),
            ("kAFAssistantErrorDomain", 216),
            ("kAFAssistantErrorDomain", 1110),
          ])
    func noSpeech(domain: String, code: Int) {
        #expect(!SpeechAssetErrorClassifier.indicatesMissingAsset(domain: domain, code: code))
    }

    @Test("matching codes in unrelated domains are not missing",
          arguments: [
            (NSCocoaErrorDomain, 7),
            (NSCocoaErrorDomain, 203),
            (NSURLErrorDomain, 7),
            (NSURLErrorDomain, 203),
            ("com.apple.speech.localspeechrecognition", 7),
          ])
    func unrelatedDomains(domain: String, code: Int) {
        #expect(!SpeechAssetErrorClassifier.indicatesMissingAsset(domain: domain, code: code))
    }

    @Test("the whole domain string must match, not a prefix, suffix or other case",
          arguments: [
            ("SFSpeechErrorDomain.extra", 7),
            ("XSFSpeechErrorDomain", 7),
            ("sfspeecherrordomain", 7),
            ("SFSpeechErrorDomain ", 7),
            ("kAFAssistantErrorDomain2", 203),
            ("kafassistanterrordomain", 203),
          ])
    func wholeDomain(domain: String, code: Int) {
        #expect(!SpeechAssetErrorClassifier.indicatesMissingAsset(domain: domain, code: code))
    }

    @Test("an empty domain is not missing, whatever the code",
          arguments: [7, 203, 0])
    func emptyDomain(code: Int) {
        #expect(!SpeechAssetErrorClassifier.indicatesMissingAsset(domain: "", code: code))
    }
}
