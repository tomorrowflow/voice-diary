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

    enum LoadState: Equatable {
        case idle           // not loaded this process
        case loading        // download / load in flight
        case loaded         // ready
        case failed(String) // last load attempt failed
    }

    @State private var preference: DialogLLMPreference = DialogLLMPreference.current
    @State private var loadState: LoadState = .idle
    /// Download fraction in [0, 1]. Only meaningful while `loadState == .loading`.
    @State private var progressFraction: Double = 0
    /// Bytes downloaded so far, mirroring `Progress.completedUnitCount`. Used to
    /// drive a visible byte counter — without it the bar can sit at 0 % for
    /// minutes during the first big file and look frozen.
    @State private var completedBytes: Int64 = 0
    /// Total bytes the download expects, from `Progress.totalUnitCount`. Stays
    /// at 0 during the initial `HubClient.listFiles` phase before file sizes
    /// are known; transitioning above 0 is how we know listing succeeded.
    @State private var totalBytes: Int64 = 0

    public init() {}

    public var body: some View {
        ZStack(alignment: .top) {
            Theme.color.bg.surface.ignoresSafeArea()

            VStack(spacing: 0) {
                FlowHeader(title: "Dialog-Modell")

                ScrollView {
                    VStack(spacing: Theme.spacing.md) {
                        modelCard
                        if preference == .gemmaE4B {
                            gemmaLoadCard
                        }
                        rationaleCard
                    }
                    .padding(.horizontal, Theme.spacing.md)
                    .padding(.vertical, Theme.spacing.md)
                }
            }
        }
        .navigationBarHidden(true)
        .task { await refreshLoadState() }
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
                if new == .gemmaE4B { Task { await refreshLoadState() } }
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

    /// Gemma-specific: lets the user pre-warm the ~5 GB model on Wi-Fi
    /// instead of waiting on the first opener. Only shown when Gemma is
    /// the selected preference. State is per-process — restarting the
    /// app clears the in-memory cache but the on-disk HuggingFace cache
    /// survives, so subsequent loads are fast.
    private var gemmaLoadCard: some View {
        VStack(alignment: .leading, spacing: Theme.spacing.sm) {
            HStack(spacing: Theme.spacing.sm) {
                Image(systemName: loadIconName)
                    .font(.title3)
                    .foregroundStyle(loadIconColor)
                    .frame(width: 28)
                Text("Gemma-Modell")
                    .font(Theme.font.headline)
                    .foregroundStyle(Theme.color.text.primary)
                Spacer()
            }

            Text(loadStatusText)
                .font(Theme.font.caption)
                .foregroundStyle(loadStatusColor)
                .fixedSize(horizontal: false, vertical: true)

            switch loadState {
            case .idle, .failed:
                Button {
                    Task { await preloadGemma() }
                } label: {
                    Label("Modell laden (~5 GB)", systemImage: "arrow.down.circle")
                }
                .buttonStyle(DSButtonStyle(variant: .secondary, size: .md, fullWidth: true))
            case .loading:
                // Determinate bar + byte counter as soon as Hugging Face
                // reports a total size — even if zero bytes have landed
                // yet. The indeterminate spinner is reserved for the
                // pre-listing phase when MLX hasn't yet enumerated the
                // repo (no `Progress.totalUnitCount` available).
                VStack(alignment: .leading, spacing: Theme.spacing.xs) {
                    if totalBytes > 0 {
                        ProgressView(value: progressFraction)
                            .progressViewStyle(.linear)
                            .tint(Theme.color.text.primary)
                        Text(progressCaption)
                            .font(Theme.font.monoCaption)
                            .foregroundStyle(Theme.color.text.subdued)
                    } else {
                        HStack(spacing: Theme.spacing.sm) {
                            ProgressView()
                            Text("Modellliste wird geladen…")
                                .font(Theme.font.body)
                                .foregroundStyle(Theme.color.text.subdued)
                        }
                    }
                }
                .padding(.vertical, Theme.spacing.xs)
            case .loaded:
                EmptyView()
            }
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

    // MARK: - Actions

    private func refreshLoadState() async {
        if await GemmaDialogLLM.shared.isAvailable {
            loadState = .loaded
        } else if await GemmaDialogLLM.shared.isLoading {
            // A previous "Modell laden" tap is still downloading on
            // the shared actor — typical when the user popped this
            // view mid-download and now navigated back. Latch onto
            // the in-flight load by calling `preloadGemma()` again:
            // the broadcaster registers our fresh progress handler
            // and immediately replays the latest known byte count,
            // so the bar resumes from where it actually is instead
            // of looking idle until the load finishes.
            await preloadGemma()
        } else if case .loading = loadState {
            // keep the spinner — another path is still loading
        } else {
            loadState = .idle
        }
    }

    private func preloadGemma() async {
        loadState = .loading
        progressFraction = 0
        completedBytes = 0
        totalBytes = 0
        do {
            try await GemmaDialogLLM.shared.preload { progress in
                // MLX fires this from a downloader thread; hop to the
                // MainActor for the @State write. Clamp NaN (which
                // Progress returns until the total is known) to 0 so
                // the bar doesn't flash artifacts.
                let raw = progress.fractionCompleted
                let fraction = raw.isFinite ? min(max(raw, 0), 1) : 0
                let completed = progress.completedUnitCount
                let total = progress.totalUnitCount
                Task { @MainActor in
                    progressFraction = fraction
                    completedBytes = completed
                    totalBytes = total
                }
            }
            loadState = .loaded
            progressFraction = 1
            if totalBytes > 0 { completedBytes = totalBytes }
        } catch {
            loadState = .failed(String(describing: error))
        }
    }

    /// "120 MB von 5,0 GB geladen (2 %)". Uses `ByteCountFormatter`
    /// directly so the locale-aware separator matches the rest of the
    /// German UI without hardcoding strings.
    private var progressCaption: String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        let done = formatter.string(fromByteCount: max(completedBytes, 0))
        let total = formatter.string(fromByteCount: max(totalBytes, 0))
        let percent = Int((progressFraction * 100).rounded())
        return "\(done) von \(total) geladen (\(percent) %)"
    }

    // MARK: - Visual state

    private var loadIconName: String {
        switch loadState {
        case .idle:        return "circle.dashed"
        case .loading:     return "arrow.down.circle"
        case .loaded:      return "checkmark.circle.fill"
        case .failed:      return "exclamationmark.triangle.fill"
        }
    }

    private var loadIconColor: Color {
        switch loadState {
        case .idle:        return Theme.color.text.subdued
        case .loading:     return Theme.color.text.primary
        case .loaded:      return Theme.color.status.success
        case .failed:      return Theme.color.status.destructive
        }
    }

    private var loadStatusText: String {
        switch loadState {
        case .idle:
            return "Noch nicht geladen. Tippe auf den Button — danach läuft Gemma komplett lokal."
        case .loading:
            return "Lade ~5 GB von Hugging Face. Bei WLAN ein paar Minuten, bei Mobilfunk mehr."
        case .loaded:
            return "Gemma ist geladen und für den nächsten Walkthrough bereit."
        case .failed(let reason):
            return "Laden fehlgeschlagen: \(reason). Apple FM übernimmt heute."
        }
    }

    private var loadStatusColor: Color {
        switch loadState {
        case .failed: return Theme.color.status.destructive
        case .loaded: return Theme.color.status.success
        default:      return Theme.color.text.subdued
        }
    }

    private func blurb(for p: DialogLLMPreference) -> String {
        switch p {
        case .appleFoundation:
            return "Apples System-Modell (iOS 26). Immer verfügbar, schnell, ~3 Mrd. Parameter — Deutsch funktioniert, ist aber begrenzt."
        case .gemmaE4B:
            return "Gemma 4 E4B (4-bit) via MLX. Stärkeres Deutsch als Apple FM. Beim ersten Mal werden ~5 GB Modell aus dem Netz geladen — danach läuft alles lokal."
        }
    }
}
