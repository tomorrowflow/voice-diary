import Foundation
import SwiftUI
import Observation

// App-wide language preference, driving both
//   (a) SwiftUI `Text("…")` lookups against `Localizable.xcstrings`, and
//   (b) the default `OpenerLanguage` fed to the walkthrough state machine
//       (per-utterance `LanguageDetector` overrides still win for event
//       titles spoken inside an opener — see `OpenerTemplates.script`).
//
// Two modes — `.system` (default) and `.german` (force). On a German
// device, `.system` resolves to German; on any other device it falls back
// to English (the project's Base / development language). Forcing English
// is not a separate mode because English IS the base — users who want
// English on a German phone uninstall German from their iOS language list
// or pick a different system language.
//
// Behaviour parity with `AppLanguage.shared.effective` is what makes
// localized prompts work — when the user toggles to Deutsch, the next
// opener the coordinator renders flips to the German template table; the
// settings screen also flips immediately because we re-tag `Bundle.main`
// (see below) and bump `bundleVersion` so every observing view rebuilds.

@MainActor
@Observable
public final class AppLanguage {

    public enum Mode: String, Sendable, CaseIterable, Identifiable {
        case system
        case german
        public var id: String { rawValue }
    }

    public static let shared = AppLanguage()

    /// Persisted user choice. Setter applies the bundle override + bumps
    /// `bundleVersion` so views observing this singleton rebuild against
    /// the new strings table on the same render tick.
    public var mode: Mode {
        didSet {
            guard mode != oldValue else { return }
            UserDefaults.standard.set(mode.rawValue, forKey: Self.modeKey)
            Self.applyBundleOverride(for: mode)
            bundleVersion &+= 1
        }
    }

    /// Incremented whenever `mode` changes. Views attach
    /// `.id(AppLanguage.shared.bundleVersion)` to force a rebuild against
    /// the freshly-swapped string bundle. Modular addition so we never
    /// trip overflow on the (impossibly long) toggling session.
    public var bundleVersion: UInt32 = 0

    /// Two-letter BCP-47 tag — "de" or "en". The single canonical answer
    /// for "what language should the app behave as right now". Used by
    /// (a) the bundle override above, (b) the walkthrough state machine
    /// to seed `OpenerLanguage`, (c) AVSpeechSynthesisVoice / Piper
    /// lookups, (d) the LanguageDetector fallback when an event title is
    /// language-neutral. Per-utterance detection still overrides this for
    /// individual TTS spans — see `OpenerTemplates.script`.
    public var bcp47: String {
        switch mode {
        case .german: return "de"
        case .system: return Self.systemPreferredCode()
        }
    }

    /// True iff the app should present German UI + speak German by default.
    public var isGerman: Bool { bcp47 == "de" }

    /// Locale fed to `.environment(\.locale, …)` on the root view so date
    /// formatters and `Text(date, style:)` follow the same setting.
    public var locale: Locale {
        isGerman ? Locale(identifier: "de_DE") : Locale(identifier: "en_US")
    }

    private init() {
        // Read persisted mode first (default = .system) so the bundle
        // override below is calculated against the user's prior choice.
        let raw = UserDefaults.standard.string(forKey: Self.modeKey) ?? Mode.system.rawValue
        self.mode = Mode(rawValue: raw) ?? .system
        Self.applyBundleOverride(for: self.mode)
    }

    // MARK: - Bundle override -------------------------------------------------
    //
    // SwiftUI looks up `LocalizedStringKey`s against `Bundle.main` with the
    // current `Locale`. To switch languages without an app restart we
    //
    //   1. swap `Bundle.main`'s isa pointer to `LocalizedMainBundle` once
    //      (cheap; idempotent — guarded by `swappedClass`), and
    //   2. associate a child `Bundle` (the `de.lproj` or `en.lproj` inside
    //      the main bundle) with that object so the override
    //      `localizedString(forKey:value:table:)` reads from it.
    //
    // The same hook is used by `LocalizedStringResource` and by `String(
    // localized: ..., bundle: .main, ...)`, so spoken-prompt strings that
    // currently live in code can also be migrated to the catalog if we
    // want, with no change at the call site.

    private static let modeKey = "voiceDiary.appLanguage.mode.v1"

    nonisolated static func applyBundleOverride(for mode: Mode) {
        let lang: String?
        switch mode {
        case .german: lang = "de"
        case .system: lang = nil   // ← let iOS pick from Bundle.main's
                                   //   `preferredLocalizations`. Base is
                                   //   en, so non-DE devices land on
                                   //   English without further work.
        }
        Bundle.setLanguage(lang)
    }

    nonisolated static func systemPreferredCode() -> String {
        // `preferredLocalizations` is filtered against the bundle's
        // available languages, so on a Chinese device with only en + de
        // in the bundle we'll get "en" back, which is the right answer
        // for "Base falls back to English".
        let preferred = Bundle.main.preferredLocalizations.first
            ?? Locale.preferredLanguages.first
            ?? "en"
        return preferred.lowercased().hasPrefix("de") ? "de" : "en"
    }
}

// MARK: - Bundle swap glue ---------------------------------------------------

// Address-key only — `objc_setAssociatedObject` reads its address, never
// the byte's contents — so the value is never actually mutated. The
// `nonisolated(unsafe)` opt-out keeps Swift 6 strict concurrency happy
// without paying for an actor hop on every Text resolve.
private nonisolated(unsafe) var languageBundleAssocKey: UInt8 = 0

/// Replacement for `Bundle.main`'s class. Looks up strings against the
/// associated child bundle when one is set; falls back to default
/// behaviour otherwise so `.system` mode still picks the user's iOS
/// preferred localization.
private final class LocalizedMainBundle: Bundle, @unchecked Sendable {
    override func localizedString(
        forKey key: String,
        value: String?,
        table tableName: String?
    ) -> String {
        if let assoc = objc_getAssociatedObject(self, &languageBundleAssocKey) as? Bundle {
            return assoc.localizedString(forKey: key, value: value, table: tableName)
        }
        return super.localizedString(forKey: key, value: value, table: tableName)
    }
}

private let bundleSwapOnce: Void = {
    object_setClass(Bundle.main, LocalizedMainBundle.self)
}()

extension Bundle {
    /// Set the runtime localization. Pass `nil` to clear the override
    /// (the `.system` path).
    static func setLanguage(_ language: String?) {
        _ = bundleSwapOnce          // ensure isa-swap happened exactly once
        let assoc: Bundle?
        if let language,
           let path = Bundle.main.path(forResource: language, ofType: "lproj"),
           let inner = Bundle(path: path) {
            assoc = inner
        } else {
            assoc = nil
        }
        objc_setAssociatedObject(
            Bundle.main,
            &languageBundleAssocKey,
            assoc,
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
    }
}
