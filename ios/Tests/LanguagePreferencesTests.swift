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

    // MARK: - Storage key compatibility
    //
    // Saved choices from earlier installs live under these literal keys. They
    // are spelled out here, not read from `storageKey`, so renaming a key in
    // production fails these tests instead of silently dropping saved choices.

    private static let legacyRecordingKey = "voiceDiary.recordingLanguage.v1"
    private static let legacyResponseKey = "voiceDiary.responseLanguage.v1"

    /// Saves the exact prior objects of the two legacy keys only, and puts
    /// them back when `body` returns or throws.
    private func withLegacyKeysRestored<T>(_ body: (UserDefaults) throws -> T) rethrows -> T {
        let defaults = UserDefaults.standard
        let keys = [Self.legacyRecordingKey, Self.legacyResponseKey]
        let previous = keys.map { defaults.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, previous) {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }
        return try body(defaults)
    }

    @Test("storage keys keep the strings earlier installs saved under")
    func storageKeysMatchLegacyLiterals() {
        #expect(RecordingLanguage.storageKey == "voiceDiary.recordingLanguage.v1")
        #expect(ResponseLanguage.storageKey == "voiceDiary.responseLanguage.v1")
    }

    @Test("recording language: every choice saved under the legacy key is read back, in sequence")
    func recordingReadsLegacyKey() {
        withLegacyKeysRestored { defaults in
            defaults.removeObject(forKey: Self.legacyRecordingKey)
            #expect(RecordingLanguage.current == .auto)
            for choice in RecordingLanguage.allCases + RecordingLanguage.allCases.reversed() {
                defaults.set(choice.rawValue, forKey: Self.legacyRecordingKey)
                #expect(RecordingLanguage.current == choice)
            }
            defaults.set("klingon", forKey: Self.legacyRecordingKey)
            #expect(RecordingLanguage.current == .auto)
        }
    }

    @Test("response language: every choice saved under the legacy key is read back, in sequence")
    func responseReadsLegacyKey() {
        withLegacyKeysRestored { defaults in
            defaults.removeObject(forKey: Self.legacyResponseKey)
            #expect(ResponseLanguage.current == .match)
            for choice in ResponseLanguage.allCases + ResponseLanguage.allCases.reversed() {
                defaults.set(choice.rawValue, forKey: Self.legacyResponseKey)
                #expect(ResponseLanguage.current == choice)
            }
            defaults.set("klingon", forKey: Self.legacyResponseKey)
            #expect(ResponseLanguage.current == .match)
        }
    }

    @Test("recording and response choices are stored independently under their legacy keys")
    func legacyKeysAreIndependent() {
        withLegacyKeysRestored { defaults in
            defaults.set("en", forKey: Self.legacyRecordingKey)
            defaults.removeObject(forKey: Self.legacyResponseKey)
            #expect(RecordingLanguage.current == .en)
            #expect(ResponseLanguage.current == .match)

            defaults.removeObject(forKey: Self.legacyRecordingKey)
            defaults.set("de", forKey: Self.legacyResponseKey)
            #expect(RecordingLanguage.current == .auto)
            #expect(ResponseLanguage.current == .de)

            defaults.set("de", forKey: Self.legacyRecordingKey)
            defaults.set("en", forKey: Self.legacyResponseKey)
            #expect(RecordingLanguage.current == .de)
            #expect(ResponseLanguage.current == .en)
        }
    }

    @Test("legacy key helper restores the exact prior objects, also when the body throws")
    func legacyKeyHelperRestores() {
        struct Boom: Error {}
        withLegacyKeysRestored { defaults in
            defaults.set("de", forKey: Self.legacyRecordingKey)
            defaults.removeObject(forKey: Self.legacyResponseKey)
            do {
                try withLegacyKeysRestored { inner in
                    inner.set("en", forKey: Self.legacyRecordingKey)
                    inner.set("en", forKey: Self.legacyResponseKey)
                    throw Boom()
                }
            } catch {}
            #expect(defaults.string(forKey: Self.legacyRecordingKey) == "de")
            #expect(defaults.object(forKey: Self.legacyResponseKey) == nil)
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
