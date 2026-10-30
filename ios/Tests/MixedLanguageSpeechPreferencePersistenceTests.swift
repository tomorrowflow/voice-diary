import Foundation
import Testing
@testable import VoiceDiary

/// These tests write the real `UserDefaults.standard` key
/// `walkthrough.mixedLanguageSpeech`, so the suite is serialized, touches
/// only that key, and restores its exact prior object afterwards (removing it
/// when it was originally absent). No defaults domain is ever reset.
@Suite("WalkthroughSettingsStore mixed-language speech persistence", .serialized)
struct MixedLanguageSpeechPreferencePersistenceTests {

    /// Pinned independently of the implementation: renaming the production
    /// key would silently drop every user's saved choice.
    private static let key = "walkthrough.mixedLanguageSpeech"

    private static func restore(_ value: Any?, forKey key: String) {
        if let value {
            UserDefaults.standard.set(value, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    private func withIsolatedKey(_ body: () throws -> Void) rethrows {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: Self.key)
        defer { Self.restore(previous, forKey: Self.key) }
        defaults.removeObject(forKey: Self.key)
        try body()
    }

    @Test("an absent key reads as true")
    func absentKeyDefaultsToTrue() {
        withIsolatedKey {
            #expect(UserDefaults.standard.object(forKey: Self.key) == nil)
            #expect(WalkthroughSettingsStore.mixedLanguageSpeech == true)
        }
    }

    @Test("an explicit true is stored under the pinned key and read back")
    func explicitTruePersists() {
        withIsolatedKey {
            WalkthroughSettingsStore.setMixedLanguageSpeech(true)

            #expect(UserDefaults.standard.object(forKey: Self.key) as? Bool == true)
            #expect(WalkthroughSettingsStore.mixedLanguageSpeech == true)
        }
    }

    @Test("an explicit false is stored as a value, not as an absent key")
    func explicitFalsePersists() {
        withIsolatedKey {
            WalkthroughSettingsStore.setMixedLanguageSpeech(false)

            #expect(UserDefaults.standard.object(forKey: Self.key) as? Bool == false)
            #expect(WalkthroughSettingsStore.mixedLanguageSpeech == false)
        }
    }

    @Test("every read after a sequence of writes sees the latest value")
    func sequentialWritesReadFresh() {
        withIsolatedKey {
            for enabled in [true, false, false, true, true, false] {
                WalkthroughSettingsStore.setMixedLanguageSpeech(enabled)

                #expect(WalkthroughSettingsStore.mixedLanguageSpeech == enabled)
                #expect(UserDefaults.standard.object(forKey: Self.key) as? Bool == enabled)
            }
        }
    }

    @Test("removing the key returns to the default after either explicit value")
    func removalRestoresDefault() {
        withIsolatedKey {
            for enabled in [true, false] {
                WalkthroughSettingsStore.setMixedLanguageSpeech(enabled)
                UserDefaults.standard.removeObject(forKey: Self.key)

                #expect(WalkthroughSettingsStore.mixedLanguageSpeech == true)
            }
        }
    }

    private struct Abort: Error {}

    /// Plants `prior` under the key, runs a block that overwrites it, and
    /// checks the exact prior object (or its absence) is back afterwards.
    private func expectRestored(prior: Any?, throwing: Bool, sourceLocation: SourceLocation = #_sourceLocation) {
        let defaults = UserDefaults.standard
        let outer = defaults.object(forKey: Self.key)
        defer { Self.restore(outer, forKey: Self.key) }
        Self.restore(prior, forKey: Self.key)

        do {
            try withIsolatedKey {
                #expect(defaults.object(forKey: Self.key) == nil, sourceLocation: sourceLocation)
                WalkthroughSettingsStore.setMixedLanguageSpeech(prior as? Bool != true)
                if throwing { throw Abort() }
            }
        } catch is Abort {
            #expect(throwing, sourceLocation: sourceLocation)
        } catch {
            Issue.record(error, sourceLocation: sourceLocation)
        }

        let restored = defaults.object(forKey: Self.key)
        if let prior {
            #expect((restored as? NSObject)?.isEqual(prior) == true, "prior \(prior)", sourceLocation: sourceLocation)
        } else {
            #expect(restored == nil, sourceLocation: sourceLocation)
        }
    }

    @Test("the exact prior object is restored on the normal and throwing paths")
    func restoresPriorObject() {
        // true and false stay explicit values, absent stays absent, and a
        // non-Bool object is not normalised into a Bool.
        let priors: [Any?] = [true, false, nil, "sentinel"]
        for prior in priors {
            expectRestored(prior: prior, throwing: false)
            expectRestored(prior: prior, throwing: true)
        }
    }
}
