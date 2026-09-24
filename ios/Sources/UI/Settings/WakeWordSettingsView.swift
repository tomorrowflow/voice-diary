import Speech
import SwiftUI
import UIKit

/// Lets the user toggle wake-word recognition on/off, see whether
/// Apple's on-device dictation asset is installed for each supported
/// language, and run a real recognition probe after they fix it in iOS
/// Settings.
///
/// Why a separate page from PermissionsView: speech-recognition
/// *authorization* is a yes/no permission, but on-device recognition
/// also requires a per-language **asset** that ships out-of-band from
/// iOS itself. The user has to enable Dictation, add the language, and
/// then iOS downloads the asset whenever it feels like it (Wi-Fi +
/// often power required). There's no public API to force the download —
/// only to observe whether it has finished. Hence the caption
/// explaining the manual steps and the "Test" button below.
///
/// Status freshness is achieved three ways:
///   1. `SFSpeechRecognizerDelegate.speechRecognizer(_:availabilityDidChange:)`
///      — fires whenever iOS itself flips the per-language asset state,
///      which is the source of truth.
///   2. `scenePhase == .active` — covers the "return from iOS Settings
///      app" path. iOS won't always post `availabilityDidChange` across
///      app suspension; re-creating the recognizer on resume re-reads it.
///   3. The Test button actually starts a brief on-device recognition
///      task. `supportsOnDeviceRecognition` can lie (stale `false`) on
///      iOS 17+ — running a task is the only way to get a real answer
///      *and* to nudge iOS into starting the asset download if it
///      hasn't already.
@MainActor
public struct WakeWordSettingsView: View {
    @State private var enabled: Bool = WakeWordPreferences.isEnabled
    @StateObject private var monitor = SpeechAssetMonitor()
    @State private var testResult: TestResult = .idle
    @Environment(\.scenePhase) private var scenePhase

    /// One outcome for both languages so the row UI can swap its pill in place.
    enum TestOutcome: Equatable {
        case installed
        case notInstalled(reason: String)
        case unauthorized
        case unavailable
        case timeout
    }

    enum TestResult: Equatable {
        case idle
        case running
        case done(de: TestOutcome, en: TestOutcome)
    }

    public init() {}

    public var body: some View {
        ZStack(alignment: .top) {
            Theme.color.bg.surface.ignoresSafeArea()

            VStack(spacing: 0) {
                FlowHeader(title: "Wake word")

                ScrollView {
                    VStack(spacing: Theme.spacing.md) {
                        toggleCard
                        languagesCard
                        instructionsCard
                        testButton
                        openSettingsButton
                    }
                    .padding(.horizontal, Theme.spacing.md)
                    .padding(.vertical, Theme.spacing.md)
                }
            }
        }
        .navigationBarHidden(true)
        .onAppear { monitor.refresh() }
        .onChange(of: scenePhase) { _, new in
            // When the user returns from the iOS Settings app (where
            // they enabled Dictation or added a language), iOS may have
            // finished downloading the asset while we were suspended.
            // Re-creating the recognizer re-reads the live state and
            // re-binds the delegate.
            if new == .active { monitor.refresh() }
        }
    }

    // MARK: - Cards

    /// Top-level on/off. Disabled when no language supports on-device
    /// recognition — flipping it on would have no effect anyway, and a
    /// disabled-but-explanatory toggle is clearer than an enabled
    /// toggle that silently does nothing.
    private var toggleCard: some View {
        VStack(alignment: .leading, spacing: Theme.spacing.sm) {
            HStack(spacing: Theme.spacing.sm) {
                Image(systemName: "waveform.and.mic")
                    .font(.title3)
                    .foregroundStyle(Theme.color.text.primary)
                    .frame(width: 28)
                Text("Enable wake word")
                    .font(Theme.font.headline)
                    .foregroundStyle(Theme.color.text.primary)
                Spacer()
                Toggle("", isOn: Binding(
                    get: { enabled && anySupported },
                    set: { newValue in
                        enabled = newValue
                        WakeWordPreferences.setEnabled(newValue)
                    }
                ))
                .labelsHidden()
                .disabled(!anySupported)
            }

            Text(toggleCaption)
                .font(Theme.font.caption)
                .foregroundStyle(Theme.color.text.subdued)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Theme.spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dsCard()
    }

    /// One row per supported walkthrough language. The status pill
    /// reflects the live delegate + scenePhase observation. The Test
    /// button below can override the pill text with the concrete
    /// outcome of a real recognition probe — useful when the cached
    /// `supportsOnDeviceRecognition` flag lies.
    private var languagesCard: some View {
        VStack(alignment: .leading, spacing: Theme.spacing.sm) {
            HStack(spacing: Theme.spacing.sm) {
                Image(systemName: "globe")
                    .font(.title3)
                    .foregroundStyle(Theme.color.text.primary)
                    .frame(width: 28)
                Text("On-device recognition")
                    .font(Theme.font.headline)
                    .foregroundStyle(Theme.color.text.primary)
                Spacer()
            }

            languageRow(
                label: String(localized: "German"),
                installed: monitor.deInstalled,
                probeOutcome: probeOutcome(\.de)
            )
            Divider().background(Theme.color.border.subdued)
            languageRow(
                label: String(localized: "English"),
                installed: monitor.enInstalled,
                probeOutcome: probeOutcome(\.en)
            )

            Text("Voice Diary uses Apple’s dictation asset for wake-word recognition. While a language’s asset is missing, the wake word is off in that language — tapping still works, and the automatic silence detection keeps working.")
                .font(Theme.font.caption)
                .foregroundStyle(Theme.color.text.subdued)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Theme.spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dsCard()
    }

    private func languageRow(label: String, installed: Bool, probeOutcome: TestOutcome?) -> some View {
        HStack {
            Text(label)
                .font(Theme.font.body)
                .foregroundStyle(Theme.color.text.primary)
            Spacer()
            statusPill(installed: installed, probeOutcome: probeOutcome)
        }
    }

    @ViewBuilder
    private func statusPill(installed: Bool, probeOutcome: TestOutcome?) -> some View {
        // Probe outcome trumps the live flag — it's the empirical truth.
        if let outcome = probeOutcome {
            switch outcome {
            case .installed:
                DSStatusPill(text: String(localized: "Installed"), color: Theme.color.status.success)
            case .notInstalled:
                DSStatusPill(text: String(localized: "Not installed"), color: Theme.color.status.warning)
            case .unauthorized:
                DSStatusPill(text: String(localized: "No permission"), color: Theme.color.status.destructive)
            case .unavailable:
                DSStatusPill(text: String(localized: "Unavailable"), color: Theme.color.status.warning)
            case .timeout:
                DSStatusPill(text: String(localized: "Test timed out"), color: Theme.color.status.warning)
            }
        } else {
            DSStatusPill(
                text: installed ? String(localized: "Installed") : String(localized: "Downloading"),
                color: installed ? Theme.color.status.success : Theme.color.status.warning
            )
        }
    }

    /// What to actually do if German says "Downloading". There is no
    /// public API to force-download the asset — these are the levers
    /// iOS exposes.
    private var instructionsCard: some View {
        VStack(alignment: .leading, spacing: Theme.spacing.sm) {
            HStack(spacing: Theme.spacing.sm) {
                Image(systemName: "arrow.down.circle")
                    .font(.title3)
                    .foregroundStyle(Theme.color.text.primary)
                    .frame(width: 28)
                Text("Download asset")
                    .font(Theme.font.headline)
                    .foregroundStyle(Theme.color.text.primary)
                Spacer()
            }

            instructionRow(index: 1, text: String(localized: "iOS Settings → General → Keyboard → enable Dictation."))
            instructionRow(index: 2, text: String(localized: "In the same screen, open “Dictation Languages” and add German (Germany)."))
            instructionRow(index: 3, text: String(localized: "Connect to Wi-Fi and ideally plug in the device."))
            instructionRow(index: 4, text: String(localized: "Open the keyboard once, tap the microphone icon, and briefly dictate in German — that nudges iOS to start the download."))
            instructionRow(index: 5, text: String(localized: "Wait (sometimes minutes, sometimes hours), then tap “Test” below to verify."))
        }
        .padding(Theme.spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dsCard()
    }

    private func instructionRow(index: Int, text: String) -> some View {
        // SF Symbol numbered circles in primary foreground colour. iOS
        // Settings uses this pattern for ordered steps; the previous
        // blue link-coloured digits read as hyperlinks even though
        // they aren't tappable.
        HStack(alignment: .top, spacing: Theme.spacing.sm) {
            Image(systemName: "\(index).circle.fill")
                .font(Theme.font.body)
                .foregroundStyle(Theme.color.text.primary)
                .accessibilityLabel(Text("Step \(index)"))
            Text(text)
                .font(Theme.font.caption)
                .foregroundStyle(Theme.color.text.subdued)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var testButton: some View {
        Button {
            Task { await runTest() }
        } label: {
            HStack(spacing: Theme.spacing.sm) {
                if case .running = testResult {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(.white)
                } else {
                    Image(systemName: "checkmark.seal")
                }
                Text(testResult == .running
                     ? String(localized: "Testing…")
                     : String(localized: "Test"))
            }
        }
        .buttonStyle(DSButtonStyle(variant: .primary, size: .md, fullWidth: true))
        .disabled(testResult == .running)
    }

    private var openSettingsButton: some View {
        Button {
            openSystemSettings()
        } label: {
            Label("Open iOS Settings", systemImage: "gear")
        }
        .buttonStyle(DSButtonStyle(variant: .outline, size: .md, fullWidth: true))
    }

    // MARK: - State

    private var anySupported: Bool {
        monitor.deInstalled || monitor.enInstalled || lastProbeShowsAnyInstalled
    }

    private var lastProbeShowsAnyInstalled: Bool {
        guard case .done(let de, let en) = testResult else { return false }
        return de == .installed || en == .installed
    }

    private var toggleCaption: String {
        if !anySupported {
            return String(localized: "No dictation asset installed yet — wake word can’t be enabled. Follow the steps below and tap “Test”.")
        }
        if enabled {
            return String(localized: "Wake word is on. During an event, after 3 s of silence a listening window opens: “next” / “weiter” → next event, “done” / “fertig” → end the walkthrough.")
        }
        return String(localized: "Wake word is off. Keep tapping the arrow at the bottom right to step through events.")
    }

    private func probeOutcome(_ keyPath: KeyPath<ProbePair, TestOutcome>) -> TestOutcome? {
        guard case .done(let de, let en) = testResult else { return nil }
        return ProbePair(de: de, en: en)[keyPath: keyPath]
    }

    private struct ProbePair {
        let de: TestOutcome
        let en: TestOutcome
    }

    // MARK: - Actions

    private func runTest() async {
        testResult = .running
        // Run both probes sequentially. Each takes at most 5 s.
        // Sequential rather than parallel because SFSpeechRecognizer
        // doesn't love overlapping tasks on the same process and the
        // total wait — up to 10 s — is still tolerable.
        let de = await SpeechAssetProbe.run(language: "de")
        let en = await SpeechAssetProbe.run(language: "en")
        testResult = .done(de: de, en: en)
        Diag.log("WakeWordSettings test: de=\(describe(de)) en=\(describe(en))")

        // If the probe says either language is installed but the live
        // flag was false, refresh — the act of running a recognition
        // task often invalidates the cached `supportsOnDeviceRecognition`.
        if de == .installed || en == .installed {
            monitor.refresh()
        }
        if !anySupported && enabled {
            enabled = false
            WakeWordPreferences.setEnabled(false)
        }
    }

    private func describe(_ outcome: TestOutcome) -> String {
        switch outcome {
        case .installed:                return "installed"
        case .notInstalled(let r):      return "not_installed(\(r))"
        case .unauthorized:             return "unauthorized"
        case .unavailable:              return "unavailable"
        case .timeout:                  return "timeout"
        }
    }

    private func openSystemSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }
}

// MARK: - Live availability observer

/// Subscribes to `SFSpeechRecognizerDelegate.availabilityDidChange` so
/// the status pills flip without polling. The recognizer instances
/// themselves are re-created in `refresh()` because that's how Apple
/// invalidates its cached `supportsOnDeviceRecognition` answer for a
/// fresh per-language asset state.
@MainActor
private final class SpeechAssetMonitor: NSObject, SFSpeechRecognizerDelegate, ObservableObject {
    @Published var deInstalled: Bool = false
    @Published var enInstalled: Bool = false

    private var deRecognizer: SFSpeechRecognizer?
    private var enRecognizer: SFSpeechRecognizer?

    override init() {
        super.init()
        refresh()
    }

    func refresh() {
        let de = SFSpeechRecognizer(locale: Locale(identifier: "de-DE"))
        let en = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        deRecognizer = de
        enRecognizer = en
        de?.delegate = self
        en?.delegate = self
        deInstalled = (de?.isAvailable == true) && (de?.supportsOnDeviceRecognition == true)
        enInstalled = (en?.isAvailable == true) && (en?.supportsOnDeviceRecognition == true)
    }

    // Delegate callback. Apple doesn't document the thread; hop to the
    // MainActor so the @Published writes inside `refresh()` are safe.
    nonisolated func speechRecognizer(
        _ recognizer: SFSpeechRecognizer,
        availabilityDidChange available: Bool
    ) {
        Task { @MainActor [weak self] in
            self?.refresh()
        }
    }
}

// MARK: - Empirical asset probe

/// Runs a brief on-device recognition task with no audio buffers to
/// determine, empirically, whether iOS has the asset for the requested
/// locale. Faster and more truthful than `supportsOnDeviceRecognition`,
/// which on iOS 17+ can return stale `false` even when the asset has
/// just been installed.
///
/// Cost: at most ~5 s wall-clock per language. No audio is captured;
/// the mic is not opened.
private enum SpeechAssetProbe {

    static func run(language: String) async -> WakeWordSettingsView.TestOutcome {
        // Authorization first — `requestAuthorization` is a no-op once
        // the user has answered, so this is cheap on repeat calls.
        do {
            try await AppleStreamingRecognizer.requestAuthorization()
        } catch {
            return .unauthorized
        }

        let locale: Locale = language == "de"
            ? Locale(identifier: "de-DE")
            : Locale(identifier: "en-US")
        guard let recognizer = SFSpeechRecognizer(locale: locale),
              recognizer.isAvailable else {
            return .unavailable
        }

        return await withCheckedContinuation { (cont: CheckedContinuation<WakeWordSettingsView.TestOutcome, Never>) in
            let req = SFSpeechAudioBufferRecognitionRequest()
            req.requiresOnDeviceRecognition = true
            req.shouldReportPartialResults = false

            let gate = ProbeGate(cont: cont)

            let task = recognizer.recognitionTask(with: req) { result, error in
                // Reaching this callback at all means the on-device
                // recognizer accepted the request — which is only
                // possible when the per-language asset is installed.
                // The earlier version of this code treated *any*
                // error as "not installed", but that's wrong: with no
                // audio buffers submitted, iOS produces a "no
                // speech" / "empty audio" error from a fully-loaded
                // recognizer. We only filter the very small set of
                // codes that explicitly mean "the language asset
                // isn't downloaded"; everything else is `.installed`.
                if let err = error as NSError? {
                    if Self.indicatesMissingAsset(err) {
                        gate.resolveOnce(.notInstalled(reason: "\(err.domain):\(err.code)"))
                    } else {
                        gate.resolveOnce(.installed)
                    }
                } else if result?.isFinal == true {
                    gate.resolveOnce(.installed)
                }
            }
            // `SFSpeechRecognitionTask` isn't declared `Sendable` in
            // Apple's headers, so wrap it in an `@unchecked Sendable`
            // box before capturing it across the timeout `Task` boundary.
            let taskBox = SFRTaskBox(task)

            // Tell the engine no more audio is coming. With no buffers
            // pushed, iOS settles within a couple of seconds with a
            // "no speech" error, which our handler maps to `.installed`
            // because reaching that point proves the asset works.
            req.endAudio()

            // Hard timeout — Apple has been known to take several
            // seconds before producing the final / error callback when
            // the asset is mid-download. Don't block the UI longer
            // than 5 s. Detached so the closure doesn't inherit any
            // actor isolation that would conflict with the gate's
            // already-Sendable nature.
            Task.detached {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                if gate.resolveOnce(.timeout) {
                    taskBox.task.cancel()
                }
            }
        }
    }
}

/// Sendable wrapper for `SFSpeechRecognitionTask` so we can capture it
/// across the timeout `Task.detached` boundary. The task is a Foundation
/// class that's safe to use from any thread per Apple's documentation —
/// we just can't tell the Swift 6 compiler that without this shim.
private final class SFRTaskBox: @unchecked Sendable {
    let task: SFSpeechRecognitionTask
    init(_ task: SFSpeechRecognitionTask) { self.task = task }
}

extension SpeechAssetProbe {
    /// Conservative allowlist of error codes that empirically mean
    /// "the per-language dictation asset isn't installed". Everything
    /// else — including the common `kAFAssistantErrorDomain` 1107 /
    /// 216 "no speech" returned when we submit no audio buffers — is
    /// interpreted as `.installed` because reaching this callback at
    /// all required the recognizer to spin up successfully.
    ///
    /// References:
    ///   * `SFSpeechErrorDomain` with `unsupportedLocale` / -ish codes
    ///     surfaces when the locale's model isn't on disk.
    ///   * `kAFAssistantErrorDomain` 203 has been reported for
    ///     "request was canceled because language isn't available".
    ///
    /// Keep this list short and conservative — false positives here
    /// (treating an installed asset as missing) are exactly the bug
    /// the user just hit. False negatives only mean "Test" claims
    /// installed for one extra error we haven't catalogued; that's
    /// graceful because the wake-word listen window will then fail
    /// gracefully at the actual use site.
    static func indicatesMissingAsset(_ err: NSError) -> Bool {
        // SFSpeechErrorDomain (Swift 5.7+/iOS 17). The exact case set
        // depends on the SDK; rather than enum-match (which would
        // tie us to the SDK shape), we compare against the codes
        // Apple uses for "language not supported" / "asset not
        // available". `unsupportedLocale` is the canonical one.
        if err.domain == "SFSpeechErrorDomain" {
            // Code 7 corresponds to `.unsupportedLocale` on current
            // iOS. We deliberately don't add other SFSpeechError
            // codes because they overwhelmingly mean transient
            // recognition failures, not "asset missing".
            return err.code == 7
        }
        // kAFAssistantErrorDomain 203 has been observed when the
        // assistant subsystem refuses the request because the
        // language model isn't on disk. The same domain's 1107 / 216
        // are "no speech" / "empty audio" — those are NOT
        // asset-missing and should map to `.installed`.
        if err.domain == "kAFAssistantErrorDomain" {
            return err.code == 203
        }
        return false
    }
}

private final class ProbeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var resolved = false
    private let cont: CheckedContinuation<WakeWordSettingsView.TestOutcome, Never>

    init(cont: CheckedContinuation<WakeWordSettingsView.TestOutcome, Never>) {
        self.cont = cont
    }

    /// Returns true if this call was the one that produced the outcome.
    @discardableResult
    func resolveOnce(_ outcome: WakeWordSettingsView.TestOutcome) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !resolved else { return false }
        resolved = true
        cont.resume(returning: outcome)
        return true
    }
}
