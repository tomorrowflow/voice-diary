import Foundation
import Testing
@testable import VoiceDiary

/// These tests write the real `UserDefaults.standard` key
/// `voicediary.lockscreen.showWhenPaused`, so the suite is serialized, touches
/// only that key, and restores its exact prior object afterwards (removing it
/// when it was originally absent). No defaults domain is ever reset.
@Suite("LockScreenPreferences persistence", .serialized)
struct LockScreenPreferencesPersistenceTests {

    /// Pinned independently of the implementation: renaming the production
    /// key would silently drop every user's saved choice.
    private static let key = "voicediary.lockscreen.showWhenPaused"

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

    @Test("an absent key reads as false")
    func absentKeyDefaultsToFalse() {
        withIsolatedKey {
            #expect(UserDefaults.standard.object(forKey: Self.key) == nil)
            #expect(LockScreenPreferences.showWhenPaused == false)
        }
    }

    @Test("an explicit true is stored under the pinned key and read back")
    func explicitTruePersists() {
        withIsolatedKey {
            LockScreenPreferences.setShowWhenPaused(true)

            #expect(UserDefaults.standard.object(forKey: Self.key) as? Bool == true)
            #expect(LockScreenPreferences.showWhenPaused == true)
        }
    }

    @Test("an explicit false is stored as a value, not as an absent key")
    func explicitFalsePersists() {
        withIsolatedKey {
            LockScreenPreferences.setShowWhenPaused(false)

            #expect(UserDefaults.standard.object(forKey: Self.key) as? Bool == false)
            #expect(LockScreenPreferences.showWhenPaused == false)
        }
    }

    @Test("every read after a sequence of writes sees the latest value")
    func sequentialWritesReadFresh() {
        withIsolatedKey {
            for enabled in [true, false, false, true, true, false] {
                LockScreenPreferences.setShowWhenPaused(enabled)

                #expect(LockScreenPreferences.showWhenPaused == enabled)
                #expect(UserDefaults.standard.object(forKey: Self.key) as? Bool == enabled)
            }
        }
    }

    @Test("removing the key returns to the default after either explicit value")
    func removalRestoresDefault() {
        withIsolatedKey {
            for enabled in [true, false] {
                LockScreenPreferences.setShowWhenPaused(enabled)
                UserDefaults.standard.removeObject(forKey: Self.key)

                #expect(LockScreenPreferences.showWhenPaused == false)
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
                LockScreenPreferences.setShowWhenPaused(prior as? Bool != true)
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
