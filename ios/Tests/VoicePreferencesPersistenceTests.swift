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

    private func withIsolatedKeys(_ body: () throws -> Void) rethrows {
        let defaults = UserDefaults.standard
        let keys = [Self.keyQX, Self.keyQY]
        let previous = keys.map { defaults.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, previous) { Self.restore(value, forKey: key) }
        }
        for key in keys { defaults.removeObject(forKey: key) }
        try body()
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

    private struct Abort: Error {}

    @Test("the exact prior defaults are restored even when the block throws")
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

        #expect(throws: Abort.self) {
            try withIsolatedKeys {
                #expect(defaults.object(forKey: Self.keyQX) == nil)
                VoicePreferences.setSelectedVoiceID("voxtral:qx_one", for: "qx")
                VoicePreferences.setSelectedVoiceID("voxtral:qy_one", for: "qy")
                throw Abort()
            }
        }

        #expect(defaults.string(forKey: Self.keyQX) == "sentinel-qx")
        #expect(defaults.object(forKey: Self.keyQY) == nil)
    }

    /// (identifier, isPiper, isVoxtral)
    private static let classifierCases: [(String?, Bool, Bool)] = [
        (nil, false, false),
        ("piper:", true, false),
        ("piper:de_DE-thorsten-high", true, false),
        ("voxtral:", false, true),
        ("voxtral:de_male", false, true),
        ("Piper:de_DE-thorsten-high", false, false),
        ("PIPER:x", false, false),
        ("Voxtral:de_male", false, false),
        ("VOXTRAL:x", false, false),
        (" piper:x", false, false),
        (" voxtral:x", false, false),
        ("piper", false, false),
        ("voxtral", false, false),
        ("", false, false),
        ("de_DE-thorsten-high", false, false),
        ("com.apple.voice.premium.de-DE.Markus", false, false)
    ]

    @Test("prefix classifiers accept only the exact lowercase prefixes", arguments: classifierCases)
    func prefixClassifiers(identifier: String?, isPiper: Bool, isVoxtral: Bool) {
        #expect(VoicePreferences.isPiperVoiceID(identifier) == isPiper)
        #expect(VoicePreferences.isVoxtralVoiceID(identifier) == isVoxtral)
    }
}
