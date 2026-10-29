import Foundation
import Testing
@testable import VoiceDiary

/// These tests write the real `UserDefaults.standard` key
/// `voicediary.wakeword.enabled`, so the suite is serialized, touches only
/// that key, and restores the exact prior object afterwards (removing it
/// when it was originally absent). No defaults domain is ever reset.
@Suite("WakeWordPreferences persistence", .serialized)
struct WakeWordPreferencesPersistenceTests {

    /// Spelled out here on purpose: the test pins the stored key
    /// independently of the implementation's private constant.
    private static let key = "voicediary.wakeword.enabled"

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

    @Test("an absent key reads as enabled")
    func absentKeyDefaultsToEnabled() {
        withIsolatedKey {
            #expect(UserDefaults.standard.object(forKey: Self.key) == nil)
            #expect(WakeWordPreferences.isEnabled == true)
        }
    }

    @Test("an explicit true is stored under the key and read back")
    func explicitTrueSurvives() {
        withIsolatedKey {
            WakeWordPreferences.setEnabled(true)

            #expect(UserDefaults.standard.object(forKey: Self.key) as? Bool == true)
            #expect(WakeWordPreferences.isEnabled == true)
        }
    }

    @Test("an explicit false is stored under the key and read back")
    func explicitFalseSurvives() {
        withIsolatedKey {
            WakeWordPreferences.setEnabled(false)

            #expect(UserDefaults.standard.object(forKey: Self.key) as? Bool == false)
            #expect(WakeWordPreferences.isEnabled == false)
        }
    }

    @Test("each sequential write is visible to the next read")
    func sequentialWritesAreReadFresh() {
        withIsolatedKey {
            for enabled in [false, true, false, false, true, true, false] {
                WakeWordPreferences.setEnabled(enabled)

                #expect(WakeWordPreferences.isEnabled == enabled)
                #expect(UserDefaults.standard.object(forKey: Self.key) as? Bool == enabled)
            }
        }
    }

    @Test("removing the key returns to the documented default")
    func removalRestoresDefault() {
        withIsolatedKey {
            for enabled in [false, true] {
                WakeWordPreferences.setEnabled(enabled)
                UserDefaults.standard.removeObject(forKey: Self.key)

                #expect(UserDefaults.standard.object(forKey: Self.key) == nil)
                #expect(WakeWordPreferences.isEnabled == true)
            }
        }
    }

    private struct Abort: Error {}

    @Test("the exact prior object is restored on the normal and throwing paths")
    func restoresPriorObject() {
        let defaults = UserDefaults.standard
        let outer = defaults.object(forKey: Self.key)
        defer { Self.restore(outer, forKey: Self.key) }

        // Originally present: the sentinel comes back after a normal run.
        defaults.set(false, forKey: Self.key)
        withIsolatedKey {
            #expect(defaults.object(forKey: Self.key) == nil)
            WakeWordPreferences.setEnabled(true)
        }
        #expect(defaults.object(forKey: Self.key) as? Bool == false)

        // Originally present: the sentinel comes back after a throw.
        #expect(throws: Abort.self) {
            try withIsolatedKey {
                WakeWordPreferences.setEnabled(true)
                throw Abort()
            }
        }
        #expect(defaults.object(forKey: Self.key) as? Bool == false)

        // Originally absent: the key is removed again after a normal run.
        defaults.removeObject(forKey: Self.key)
        withIsolatedKey {
            WakeWordPreferences.setEnabled(false)
        }
        #expect(defaults.object(forKey: Self.key) == nil)

        // Originally absent: the key is removed again after a throw.
        #expect(throws: Abort.self) {
            try withIsolatedKey {
                WakeWordPreferences.setEnabled(false)
                throw Abort()
            }
        }
        #expect(defaults.object(forKey: Self.key) == nil)
    }
}
