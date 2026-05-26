import SwiftUI

/// Pick the on-device dialog LLM the walkthrough uses for openers,
/// follow-ups, summaries, and implicit-todo extraction.
///
/// Default is Apple Foundation Models — always available, fast, but
/// English-first and weak on free-form German. The Gemma option routes
/// to `GemmaDialogLLM` (Gemma 4 E4B 4-bit via MLX). First Gemma use
/// pulls ~5 GB of weights from HuggingFace; on any failure the
/// `ChainDialogLLM` falls back to Apple FM transparently, so the
/// walkthrough never breaks because of a missing model.
@MainActor
public struct DialogModelSettingsView: View {

    @State private var preference: DialogLLMPreference = DialogLLMPreference.current

    public init() {}

    public var body: some View {
        ZStack(alignment: .top) {
            Theme.color.bg.surface.ignoresSafeArea()

            VStack(spacing: 0) {
                FlowHeader(title: "Dialog-Modell")

                ScrollView {
                    VStack(spacing: Theme.spacing.md) {
                        modelCard
                        rationaleCard
                    }
                    .padding(.horizontal, Theme.spacing.md)
                    .padding(.vertical, Theme.spacing.md)
                }
            }
        }
        .navigationBarHidden(true)
    }

    private var modelCard: some View {
        VStack(alignment: .leading, spacing: Theme.spacing.sm) {
            HStack(spacing: Theme.spacing.sm) {
                Image(systemName: "brain")
                    .font(.title3)
                    .foregroundStyle(Theme.color.text.primary)
                    .frame(width: 28)
                Text("Modell")
                    .font(Theme.font.headline)
                    .foregroundStyle(Theme.color.text.primary)
                Spacer()
            }

            Picker("Modell", selection: $preference) {
                ForEach(DialogLLMPreference.allCases, id: \.self) { p in
                    Text(p.displayName).tag(p)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: preference) { _, new in
                DialogLLMPreference.set(new)
            }

            Text(blurb(for: preference))
                .font(Theme.font.caption)
                .foregroundStyle(Theme.color.text.subdued)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Theme.spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.radius.lg, style: .continuous)
                .fill(Theme.color.bg.container)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radius.lg, style: .continuous)
                .strokeBorder(Theme.color.border.subdued, lineWidth: 1)
        )
    }

    private var rationaleCard: some View {
        VStack(alignment: .leading, spacing: Theme.spacing.sm) {
            HStack(spacing: Theme.spacing.sm) {
                Image(systemName: "info.circle")
                    .font(.title3)
                    .foregroundStyle(Theme.color.text.primary)
                    .frame(width: 28)
                Text("Hinweis")
                    .font(Theme.font.headline)
                    .foregroundStyle(Theme.color.text.primary)
                Spacer()
            }
            Text("""
            Bei Fehlern (Modell nicht geladen, falsche Sprache, \
            Modellgröße zu groß) springt der Walkthrough automatisch \
            auf Apple Foundation Models zurück. Du verlierst also nie \
            den Termin, falls Gemma streikt.
            """)
                .font(Theme.font.caption)
                .foregroundStyle(Theme.color.text.subdued)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Theme.spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.radius.lg, style: .continuous)
                .fill(Theme.color.bg.container)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radius.lg, style: .continuous)
                .strokeBorder(Theme.color.border.subdued, lineWidth: 1)
        )
    }

    private func blurb(for p: DialogLLMPreference) -> String {
        switch p {
        case .appleFoundation:
            return "Apples System-Modell (iOS 26). Immer verfügbar, schnell, ~3 Mrd. Parameter — Deutsch funktioniert, ist aber begrenzt."
        case .gemmaE4B:
            return "Gemma 4 E4B (4-bit) via MLX. Stärkeres Deutsch als Apple FM. Beim ersten Termin werden ~5 GB Modell aus dem Netz geladen — danach läuft alles lokal."
        }
    }
}
