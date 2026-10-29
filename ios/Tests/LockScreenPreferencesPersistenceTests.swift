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

    @Test("the exact prior object is restored on the normal and throwing paths")
    func restoresPriorObject() {
        let defaults = UserDefaults.standard
        let outer = defaults.object(forKey: Self.key)
        defer { Self.restore(outer, forKey: Self.key) }

        // A prior explicit true survives a block that writes false.
        defaults.set(true, forKey: Self.key)
        withIsolatedKey {
            #expect(defaults.object(forKey: Self.key) == nil)
            LockScreenPreferences.setShowWhenPaused(false)
        }
        #expect(defaults.object(forKey: Self.key) as? Bool == true)

        // A prior explicit false stays an explicit false, not an absent key.
        defaults.set(false, forKey: Self.key)
        withIsolatedKey {
            LockScreenPreferences.setShowWhenPaused(true)
        }
        #expect(defaults.object(forKey: Self.key) as? Bool == false)

        // A prior absent key is removed again.
        defaults.removeObject(forKey: Self.key)
        withIsolatedKey {
            LockScreenPreferences.setShowWhenPaused(true)
        }
        #expect(defaults.object(forKey: Self.key) == nil)

        // The same holds when the block throws.
        defaults.set(true, forKey: Self.key)
        #expect(throws: Abort.self) {
            try withIsolatedKey {
                LockScreenPreferences.setShowWhenPaused(false)
                throw Abort()
            }
        }
        #expect(defaults.object(forKey: Self.key) as? Bool == true)

        defaults.removeObject(forKey: Self.key)
        #expect(throws: Abort.self) {
            try withIsolatedKey {
                LockScreenPreferences.setShowWhenPaused(true)
                throw Abort()
            }
        }
        #expect(defaults.object(forKey: Self.key) == nil)
    }
}
