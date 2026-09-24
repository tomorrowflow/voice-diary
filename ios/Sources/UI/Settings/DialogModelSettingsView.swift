import SwiftUI
import UIKit

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
        case stalled        // loading but no progress for STALL_THRESHOLD seconds
        case loaded         // ready
        case failed(String) // last load attempt failed
    }

    /// Trigger the stalled UI when no progress callback fires for this
    /// long while in `.loading`. Tuned to be much longer than the
    /// typical 100 ms HubClient sampling tick, but short enough that
    /// the user gets feedback before they put the phone down for the
    /// night and miss a real failure.
    private static let stallThresholdSeconds: TimeInterval = 60

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
    /// Last time a progress callback advanced `completedBytes`. The
    /// stall watchdog reads this on a timer to flip into `.stalled`
    /// when the download has been silent too long.
    @State private var lastProgressAt: Date = Date()

    public init() {}

    public var body: some View {
        ZStack(alignment: .top) {
            Theme.color.bg.surface.ignoresSafeArea()

            VStack(spacing: 0) {
                FlowHeader(title: "Dialog model")

                ScrollView {
                    VStack(spacing: Theme.spacing.md) {
                        modelCard
                        if preference == .gemmaE4B {
                            gemmaLoadCard
                        }
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
                Text("Model")
                    .font(Theme.font.headline)
                    .foregroundStyle(Theme.color.text.primary)
                Spacer()
            }

            Picker("Model", selection: $preference) {
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
        .dsCard()
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
                Text("Gemma model")
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
                    Label("Load model (~5 GB)", systemImage: "arrow.down.circle")
                }
                .buttonStyle(DSButtonStyle(variant: .secondary, size: .md, fullWidth: true))
            case .loading, .stalled:
                // Determinate bar + byte counter as soon as Hugging Face
                // reports a total size — even if zero bytes have landed
                // yet. The indeterminate spinner is reserved for the
                // pre-listing phase when MLX hasn't yet enumerated the
                // repo (no `Progress.totalUnitCount` available).
                VStack(alignment: .leading, spacing: Theme.spacing.xs) {
                    if totalBytes > 0 {
                        ProgressView(value: progressFraction)
                            .progressViewStyle(.linear)
                            .tint(loadState == .stalled
                                  ? Theme.color.status.warning
                                  : Theme.color.text.primary)
                        Text(progressCaption)
                            .font(Theme.font.monoCaption)
                            .foregroundStyle(Theme.color.text.subdued)
                    } else {
                        HStack(spacing: Theme.spacing.sm) {
                            ProgressView()
                            Text("Preparing download…")
                                .font(Theme.font.body)
                                .foregroundStyle(Theme.color.text.subdued)
                        }
                    }
                    if loadState == .stalled {
                        // Surface stalls explicitly so the user knows
                        // it isn't just slow. Tap-to-retry first
                        // *cancels* the stalled in-flight load (without
                        // that, `ensureLoaded` would short-circuit on
                        // the still-set `loadTask` and re-await the
                        // same dead Task — the bar would never move
                        // past 32.4 MB), then kicks off a fresh
                        // `preloadGemma()`. The HuggingFace on-disk
                        // cache makes already-downloaded chunks free.
                        Button {
                            Task {
                                await GemmaDialogLLM.shared.cancelLoad()
                                await preloadGemma()
                            }
                        } label: {
                            Label("Stalled — tap to retry", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(DSButtonStyle(variant: .outline, size: .sm, fullWidth: true))
                    }
                }
                .padding(.vertical, Theme.spacing.xs)
            case .loaded:
                EmptyView()
            }
        }
        .padding(Theme.spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dsCard()
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

    /// Run the Gemma download/load with the iOS-side mitigations the
    /// HuggingFace library can't apply for us:
    ///
    ///   * `isIdleTimerDisabled` — stop the screen sleeping mid-download.
    ///     Without this the user pockets the phone, the screen locks,
    ///     iOS suspends us within ~30 s, and the default URLSession
    ///     halts. (See SPEC §13 + the user's "stuck at 32k" report.)
    ///   * `beginBackgroundTask(withName:)` — buys ~30 s of guaranteed
    ///     runtime past backgrounding. Not a substitute for a real
    ///     background URLSession (which we can't install — the
    ///     `#huggingFaceLoadModelContainer` macro owns the session),
    ///     but it pushes the suspension point past brief lock/unlock
    ///     cycles when the user just checks a notification.
    ///   * **Stall watchdog** — fires `Diag.log` and flips the UI into
    ///     `.stalled` if no `Progress` callback advances `completedBytes`
    ///     for `stallThresholdSeconds`. The next stall therefore lands
    ///     in the new Diagnostics view's log window with a clear
    ///     marker, which is the missing piece for diagnosing the 32K
    ///     stall properly.
    ///   * **Auto-activation** — re-assert the preference defensively
    ///     after a successful load. The user has already opted into
    ///     Gemma to see this card, so this is a no-op in the common
    ///     case — but it covers the edge where the preference was
    ///     racy-cleared elsewhere.
    private func preloadGemma() async {
        loadState = .loading
        progressFraction = 0
        completedBytes = 0
        totalBytes = 0
        lastProgressAt = Date()

        UIApplication.shared.isIdleTimerDisabled = true
        var bgTask: UIBackgroundTaskIdentifier = .invalid
        bgTask = UIApplication.shared.beginBackgroundTask(withName: "gemma-download") {
            // Expiration handler — iOS is about to suspend us. End the
            // task cleanly so we don't get killed for misuse.
            if bgTask != .invalid {
                UIApplication.shared.endBackgroundTask(bgTask)
                bgTask = .invalid
            }
            Diag.log("Gemma download: background task expiring")
        }
        defer {
            UIApplication.shared.isIdleTimerDisabled = false
            if bgTask != .invalid {
                UIApplication.shared.endBackgroundTask(bgTask)
            }
        }

        let watchdog = Task { @MainActor in
            // Wake every 10 s. Cheap. When `lastProgressAt` falls more
            // than `stallThresholdSeconds` behind now, mark the UI
            // stalled and emit a Diag line. The watchdog keeps
            // running — if progress resumes the loading callback will
            // flip the state back to .loading.
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                if Task.isCancelled { return }
                let silence = Date().timeIntervalSince(lastProgressAt)
                if silence > Self.stallThresholdSeconds {
                    if loadState == .loading {
                        Diag.log(
                            "Gemma download stall watchdog: \(Int(silence))s without progress at \(completedBytes)/\(totalBytes) bytes"
                        )
                        loadState = .stalled
                    }
                }
            }
        }
        defer { watchdog.cancel() }

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
                    let advanced = completed > completedBytes
                    progressFraction = fraction
                    completedBytes = completed
                    totalBytes = total
                    if advanced {
                        lastProgressAt = Date()
                        if loadState == .stalled {
                            // Recovered from a stall — flip back so the
                            // bar tint goes back to neutral.
                            Diag.log("Gemma download: recovered after stall")
                            loadState = .loading
                        }
                    }
                }
            }
            loadState = .loaded
            progressFraction = 1
            if totalBytes > 0 { completedBytes = totalBytes }
            // Defensive: re-assert the preference. The card only shows
            // when it's already gemmaE4B, so this is a no-op in the
            // common case — but it cleanly covers the edge where the
            // preference was racy-cleared elsewhere (e.g. Danger Zone
            // reset).
            DialogLLMPreference.set(.gemmaE4B)
            preference = .gemmaE4B
            Diag.log("Gemma download: complete, model activated")
        } catch {
            loadState = .failed(String(describing: error))
            Diag.log("Gemma download: failed \(error)")
        }
    }

    /// "120 MB of 5.0 GB downloaded (2 %)". Uses `ByteCountFormatter`
    /// directly so the locale-aware separator matches the rest of the
    /// UI without hardcoding strings.
    private var progressCaption: String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        let done = formatter.string(fromByteCount: max(completedBytes, 0))
        let total = formatter.string(fromByteCount: max(totalBytes, 0))
        let percent = Int((progressFraction * 100).rounded())
        return String(localized: "\(done) of \(total) downloaded (\(percent) %)")
    }

    // MARK: - Visual state

    private var loadIconName: String {
        switch loadState {
        case .idle:        return "circle.dashed"
        case .loading:     return "arrow.down.circle"
        case .stalled:     return "exclamationmark.circle"
        case .loaded:      return "checkmark.circle.fill"
        case .failed:      return "exclamationmark.triangle.fill"
        }
    }

    private var loadIconColor: Color {
        switch loadState {
        case .idle:        return Theme.color.text.subdued
        case .loading:     return Theme.color.text.primary
        case .stalled:     return Theme.color.status.warning
        case .loaded:      return Theme.color.status.success
        case .failed:      return Theme.color.status.destructive
        }
    }

    private var loadStatusText: String {
        switch loadState {
        case .idle:
            return String(localized: "Not downloaded yet. Tap the button below, then keep this page open and the phone unlocked until the download finishes — downloads pause while the app is in the background.")
        case .loading:
            return String(localized: "Downloading ~5 GB. Keep this page open — if you switch apps or lock the phone, the download pauses and resumes when you come back.")
        case .stalled:
            return String(localized: "No progress for over a minute. The download resumes automatically when the network returns, or tap “Retry” to restart — anything already downloaded is kept.")
        case .loaded:
            return String(localized: "Gemma is active and ready for the next walkthrough.")
        case .failed(let reason):
            return Self.friendlyFailureText(reason: reason)
        }
    }

    /// Translate the raw `Error` string from a load failure into
    /// something the user can act on. The biggest offender is the
    /// 2 KB `NSURLErrorNetworkConnectionLost` wall that iOS produces
    /// when our background-task grace runs out — we collapse it to a
    /// one-liner that points at the actual fix (keep the page open).
    private static func friendlyFailureText(reason: String) -> String {
        if reason.contains("-1005") || reason.contains("network connection was lost") {
            return String(localized: "Download paused — the connection was interrupted while the app was in the background. Tap “Load model” to continue where it left off. Until then, the Apple model takes over.")
        }
        if reason.contains("-1009") || reason.contains("not connected to the Internet") {
            return String(localized: "No internet connection. Connect to Wi-Fi and try again. Until then, the Apple model takes over.")
        }
        if reason.contains("-1001") || reason.contains("timed out") {
            return String(localized: "Connection timed out. Try again on a stronger Wi-Fi. Until then, the Apple model takes over.")
        }
        return String(localized: "Load failed: \(reason). Until then, the Apple model takes over.")
    }

    private var loadStatusColor: Color {
        switch loadState {
        case .failed:  return Theme.color.status.destructive
        case .loaded:  return Theme.color.status.success
        case .stalled: return Theme.color.status.warning
        default:       return Theme.color.text.subdued
        }
    }

    private func blurb(for p: DialogLLMPreference) -> String {
        switch p {
        case .appleFoundation:
            return String(localized: "Apple’s built-in model. Always available and fast — German works but is limited.")
        case .gemmaE4B:
            return String(localized: "Stronger German than the Apple model. Downloads ~5 GB once, then runs entirely on-device. If Gemma is ever unavailable, the walkthrough falls back to the Apple model automatically.")
        }
    }
}
