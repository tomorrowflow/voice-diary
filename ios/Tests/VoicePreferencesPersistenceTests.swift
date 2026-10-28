import Foundation
import Testing
@testable import VoiceDiary

/// These tests write real `UserDefaults.standard` keys, so the suite is
/// serialized, uses only the reserved synthetic languages `qx` and `qy`
/// (never `de`/`en`), and restores the exact prior objects afterwards.
/// Stored values are Voxtral-prefixed or cleared so no Apple voice, Piper
/// asset or network lookup is involved.
@Suite("VoicePreferences persistence", .serialized)
struct VoicePreferencesPersistenceTests {

    private static let keyPrefix = "voicediary.tts.voice."
    private static let keyQX = keyPrefix + "qx"
    private static let keyQY = keyPrefix + "qy"

    private static func restore(_ value: Any?, forKey key: String) {
        if let value {
            UserDefaults.standard.set(value, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    private func withIsolatedKeys<T>(_ body: () throws -> T) rethrows -> T {
        let defaults = UserDefaults.standard
        let keys = [Self.keyQX, Self.keyQY]
        let previous = keys.map { defaults.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, previous) { Self.restore(value, forKey: key) }
        }
        for key in keys { defaults.removeObject(forKey: key) }
        return try body()
    }

    @Test("region and case aliases of a language share one storage key")
    func aliasesShareStorage() {
        withIsolatedKeys {
            let defaults = UserDefaults.standard
            VoicePreferences.setSelectedVoiceID("voxtral:qx_one", for: "qx-AA")

            #expect(defaults.string(forKey: Self.keyQX) == "voxtral:qx_one")
            for alias in ["qx", "QX", "Qx", "qx_BB", "qx-aa", "qxy"] {
                #expect(VoicePreferences.selectedVoiceID(for: alias) == "voxtral:qx_one", "alias \(alias)")
            }

            VoicePreferences.setSelectedVoiceID("voxtral:qx_two", for: "QX_bb")
            #expect(defaults.string(forKey: Self.keyQX) == "voxtral:qx_two")
            #expect(VoicePreferences.selectedVoiceID(for: "qx") == "voxtral:qx_two")
        }
    }

    @Test("another language keeps its own selection")
    func languagesStayIndependent() {
        withIsolatedKeys {
            VoicePreferences.setSelectedVoiceID("voxtral:qx_one", for: "qx")
            #expect(VoicePreferences.selectedVoiceID(for: "qy") == nil)

            VoicePreferences.setSelectedVoiceID("voxtral:qy_one", for: "qy-CC")
            VoicePreferences.setSelectedVoiceID(nil, for: "qx")

            #expect(UserDefaults.standard.object(forKey: Self.keyQX) == nil)
            #expect(VoicePreferences.selectedVoiceID(for: "QY") == "voxtral:qy_one")
        }
    }

    @Test("a Voxtral identifier is read back verbatim")
    func voxtralReadsVerbatim() {
        withIsolatedKeys {
            for identifier in ["voxtral:de_male", "voxtral:", "voxtral:voxtral:nested", "voxtral: spaced id "] {
                VoicePreferences.setSelectedVoiceID(identifier, for: "qx")
                #expect(VoicePreferences.selectedVoiceID(for: "qx") == identifier)
            }
        }
    }

    @Test("selectedVoxtralVoice strips only the leading prefix")
    func voxtralVoiceStripsPrefix() {
        withIsolatedKeys {
            VoicePreferences.setSelectedVoiceID("voxtral:de_male", for: "qx")
            #expect(VoicePreferences.selectedVoxtralVoice(for: "qx") == "de_male")

            VoicePreferences.setSelectedVoiceID("voxtral:voxtral:nested", for: "qx")
            #expect(VoicePreferences.selectedVoxtralVoice(for: "qx") == "voxtral:nested")

            VoicePreferences.setSelectedVoiceID("voxtral:", for: "qx")
            #expect(VoicePreferences.selectedVoxtralVoice(for: "qx") == "")

            #expect(VoicePreferences.selectedVoxtralVoice(for: "qy") == nil)
        }
    }

    @Test("nil and empty writes clear the stored key")
    func nilAndEmptyClear() {
        withIsolatedKeys {
            let defaults = UserDefaults.standard
            for cleared in [nil, ""] as [String?] {
                VoicePreferences.setSelectedVoiceID("voxtral:qx_one", for: "qx")
                #expect(defaults.object(forKey: Self.keyQX) != nil)

                VoicePreferences.setSelectedVoiceID(cleared, for: "QX-AA")

                #expect(defaults.object(forKey: Self.keyQX) == nil)
                #expect(VoicePreferences.selectedVoiceID(for: "qx") == nil)
                #expect(VoicePreferences.selectedVoxtralVoice(for: "qx") == nil)
            }
        }
    }

    @Test("an empty stored value reads as no selection")
    func emptyStoredValueReadsAsNil() {
        withIsolatedKeys {
            UserDefaults.standard.set("", forKey: Self.keyQX)
            #expect(VoicePreferences.selectedVoiceID(for: "qx") == nil)
        }
    }

    @Test("the exact prior defaults are restored after the isolated block")
    func restoresPriorDefaults() {
        let defaults = UserDefaults.standard
        let priorQX = defaults.object(forKey: Self.keyQX)
        let priorQY = defaults.object(forKey: Self.keyQY)
        defer {
            Self.restore(priorQX, forKey: Self.keyQX)
            Self.restore(priorQY, forKey: Self.keyQY)
        }
        defaults.set("sentinel-qx", forKey: Self.keyQX)
        defaults.removeObject(forKey: Self.keyQY)

        withIsolatedKeys {
            #expect(defaults.object(forKey: Self.keyQX) == nil)
            VoicePreferences.setSelectedVoiceID("voxtral:qx_one", for: "qx")
            VoicePreferences.setSelectedVoiceID("voxtral:qy_one", for: "qy")
        }

        #expect(defaults.string(forKey: Self.keyQX) == "sentinel-qx")
        #expect(defaults.object(forKey: Self.keyQY) == nil)
    }

    @Test("the prefixes are the exact stored strings")
    func prefixConstants() {
        #expect(VoicePreferences.piperPrefix == "piper:")
        #expect(VoicePreferences.voxtralPrefix == "voxtral:")
    }

    @Test("isPiperVoiceID accepts only the exact lowercase prefix")
    func piperClassifier() {
        #expect(!VoicePreferences.isPiperVoiceID(nil))
        #expect(VoicePreferences.isPiperVoiceID("piper:"))
        #expect(VoicePreferences.isPiperVoiceID("piper:de_DE-thorsten-high"))
        #expect(!VoicePreferences.isPiperVoiceID("Piper:de_DE-thorsten-high"))
        #expect(!VoicePreferences.isPiperVoiceID("PIPER:x"))
        #expect(!VoicePreferences.isPiperVoiceID(" piper:x"))
        #expect(!VoicePreferences.isPiperVoiceID("piper"))
        #expect(!VoicePreferences.isPiperVoiceID(""))
        #expect(!VoicePreferences.isPiperVoiceID("de_DE-thorsten-high"))
        #expect(!VoicePreferences.isPiperVoiceID("voxtral:de_male"))
        #expect(!VoicePreferences.isPiperVoiceID("com.apple.voice.premium.de-DE.Markus"))
    }

    @Test("isVoxtralVoiceID accepts only the exact lowercase prefix")
    func voxtralClassifier() {
        #expect(!VoicePreferences.isVoxtralVoiceID(nil))
        #expect(VoicePreferences.isVoxtralVoiceID("voxtral:"))
        #expect(VoicePreferences.isVoxtralVoiceID("voxtral:de_male"))
        #expect(!VoicePreferences.isVoxtralVoiceID("Voxtral:de_male"))
        #expect(!VoicePreferences.isVoxtralVoiceID("VOXTRAL:x"))
        #expect(!VoicePreferences.isVoxtralVoiceID(" voxtral:x"))
        #expect(!VoicePreferences.isVoxtralVoiceID("voxtral"))
        #expect(!VoicePreferences.isVoxtralVoiceID(""))
        #expect(!VoicePreferences.isVoxtralVoiceID("de_male"))
        #expect(!VoicePreferences.isVoxtralVoiceID("piper:de_DE-thorsten-high"))
        #expect(!VoicePreferences.isVoxtralVoiceID("com.apple.voice.premium.de-DE.Markus"))
    }
}
