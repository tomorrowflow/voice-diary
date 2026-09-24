import SwiftUI

/// Settings surface for the app-level language toggle. Two modes:
///
///   • System (default) — UI + spoken prompts follow `Bundle.main`'s
///     preferred localization, which collapses to English on any device
///     whose iOS language isn't German (Base = en).
///   • German — locks both UI and spoken prompts to German, regardless
///     of the iOS system language.
///
/// The selection is persisted in `AppLanguage`. The Bundle.main isa-swap
/// + `bundleVersion` change happen synchronously inside the setter, so
/// every Text in the view tree re-resolves its `LocalizedStringKey`
/// against the new lproj on the same render tick — no restart prompt.
///
/// Per-event language detection in the walkthrough (`LanguageDetector` on
/// a calendar title) keeps working on top of this: a German title inside
/// an English-mode walkthrough is still spoken in the German voice, the
/// English frame around it stays English. The toggle here only changes
/// the *default* — what the app falls back to when no explicit signal
/// exists (system prompts, empty blocks, the free-reflection closer).
public struct LanguageSettingsView: View {
    @State private var appLanguage = AppLanguage.shared

    public init() {}

    public var body: some View {
        ZStack(alignment: .top) {
            Theme.color.bg.surface.ignoresSafeArea()

            VStack(spacing: 0) {
                FlowHeader(title: "Language")

                Form {
                    Section {
                        // `tag: AppLanguage.Mode` for the picker's
                        // selection binding. Inline-style so both
                        // options are visible at once and the chosen
                        // row carries a checkmark — matches the iOS
                        // Settings → General → Language pattern.
                        Picker(selection: $appLanguage.mode) {
                            Text("System (recommended)")
                                .tag(AppLanguage.Mode.system)
                            Text("Deutsch")
                                .tag(AppLanguage.Mode.german)
                        } label: {
                            Text("App language")
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                    } header: {
                        Text("App language")
                    } footer: {
                        Text("\"System\" follows your iPhone language. Voice Diary ships with English and German — any other system language falls back to English. \"Deutsch\" forces German regardless of the system setting.")
                    }

                    Section {
                        // Read-only summary so the user can confirm what
                        // \"System\" currently means on their device.
                        // Updates immediately when the picker changes.
                        HStack {
                            Text("UI + prompts")
                            Spacer()
                            Text(currentLanguageLabel)
                                .foregroundStyle(Theme.color.text.subdued)
                        }
                    } header: {
                        Text("Active right now")
                    } footer: {
                        Text("Per-event voice routing isn\u{2019}t affected: a German-titled calendar event in an English session is still spoken with the German voice.")
                    }
                }
                .scrollContentBackground(.hidden)
            }
        }
        .navigationBarHidden(true)
    }

    /// Human-readable summary of `AppLanguage.effective`. Routed
    /// through `String(localized:)` so the row label translates with
    /// the chosen mode itself.
    private var currentLanguageLabel: String {
        appLanguage.isGerman
            ? String(localized: "Deutsch")
            : String(localized: "English")
    }
}

#Preview {
    NavigationStack { LanguageSettingsView() }
}
