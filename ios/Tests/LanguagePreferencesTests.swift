import Foundation
import Testing
@testable import VoiceDiary

/// These tests write the real `UserDefaults.standard` keys, so the suite is
/// serialized and restores whatever was stored before.
@Suite("LanguagePreferences", .serialized)
struct LanguagePreferencesTests {

    private func withStored<T>(
        _ key: String,
        _ value: String?,
        _ body: () throws -> T
    ) rethrows -> T {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: key)
        defer {
            if let previous { defaults.set(previous, forKey: key) } else { defaults.removeObject(forKey: key) }
        }
        if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
        return try body()
    }

    @Test("recording language: auto follows the session, de/en force")
    func recordingResolve() {
        #expect(RecordingLanguage.auto.resolve(auto: .de) == .de)
        #expect(RecordingLanguage.auto.resolve(auto: .en) == .en)
        #expect(RecordingLanguage.de.resolve(auto: .en) == .de)
        #expect(RecordingLanguage.en.resolve(auto: .de) == .en)
    }

    @Test("recording language: transcript tag keeps the de default under auto")
    func recordingTranscriptTag() {
        #expect(RecordingLanguage.auto.transcriptLanguage == "de")
        #expect(RecordingLanguage.de.transcriptLanguage == "de")
        #expect(RecordingLanguage.en.transcriptLanguage == "en")
    }

    @Test("response language: match follows the session, de/en force")
    func responseResolve() {
        #expect(ResponseLanguage.match.resolve(match: .de) == .de)
        #expect(ResponseLanguage.match.resolve(match: .en) == .en)
        #expect(ResponseLanguage.de.resolve(match: .en) == .de)
        #expect(ResponseLanguage.en.resolve(match: .de) == .en)
    }

    @Test("response language: manifest value keeps the SPEC §10 strings")
    func responseManifestValue() {
        #expect(ResponseLanguage.match.manifestValue == "match_input")
        #expect(ResponseLanguage.de.manifestValue == "de")
        #expect(ResponseLanguage.en.manifestValue == "en")
    }

    @Test("unset or unreadable storage falls back to the follow-the-session choice")
    func defaults() {
        withStored(RecordingLanguage.storageKey, nil) {
            #expect(RecordingLanguage.current == .auto)
        }
        withStored(ResponseLanguage.storageKey, nil) {
            #expect(ResponseLanguage.current == .match)
        }
        withStored(RecordingLanguage.storageKey, "klingon") {
            #expect(RecordingLanguage.current == .auto)
        }
        withStored(ResponseLanguage.storageKey, "klingon") {
            #expect(ResponseLanguage.current == .match)
        }
    }

    @Test("stored choices are read back")
    func persistence() {
        for choice in RecordingLanguage.allCases {
            withStored(RecordingLanguage.storageKey, choice.rawValue) {
                #expect(RecordingLanguage.current == choice)
            }
        }
        for choice in ResponseLanguage.allCases {
            withStored(ResponseLanguage.storageKey, choice.rawValue) {
                #expect(ResponseLanguage.current == choice)
            }
        }
    }

    @Test("spoken AI language follows the response override, not the recording one")
    @MainActor
    func openerLanguageHonoursResponseOverride() {
        let appDefault: OpenerLanguage = AppLanguage.shared.isGerman ? .de : .en
        withStored(ResponseLanguage.storageKey, nil) {
            #expect(OpenerLanguage.current == appDefault)
        }
        withStored(ResponseLanguage.storageKey, "en") {
            #expect(OpenerLanguage.current == .en)
        }
        withStored(ResponseLanguage.storageKey, "de") {
            #expect(OpenerLanguage.current == .de)
        }
        withStored(RecordingLanguage.storageKey, "en") {
            withStored(ResponseLanguage.storageKey, nil) {
                #expect(OpenerLanguage.current == appDefault)
            }
        }
    }
}
