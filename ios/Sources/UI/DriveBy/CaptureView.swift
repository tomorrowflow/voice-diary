import AVFoundation
import SwiftUI

// In-app record button. Delegates all state to `CaptureCoordinator` so the
// App Intent (Action Button) and lock-screen widget stay in sync.

@MainActor
public struct CaptureView: View {
    @State private var coordinator = CaptureCoordinator.shared
    @State private var modelState: ParakeetManager.LoadState = .idle

    public init() {}

    public var body: some View {
        ZStack(alignment: .top) {
            Theme.color.bg.surface.ignoresSafeArea()

            VStack(spacing: 0) {
                FlowHeader(title: "Recording")

                ScrollView {
                    VStack(spacing: Theme.spacing.xl) {
                        Spacer().frame(height: Theme.spacing.xxxl)

                        // Both states occupy the same fixed slot so the
                        // sticky button below never shifts. Tall enough
                        // for the idle copy on three lines + the hint.
                        Group {
                            if coordinator.isRecording {
                                recordingBody
                            } else {
                                idleBody
                            }
                        }
                        .frame(height: 360)

                        // The "Lade Sprachmodell…" banner is gone — the
                        // CTA below carries the load state via its
                        // disabled + loading label, mirroring the
                        // walkthrough's Sitzung-starten button.

                        if let lastError = coordinator.lastError {
                            CaptureErrorText(message: lastError)
                        }
                    }
                    .padding(.horizontal, Theme.spacing.md)
                    .padding(.bottom, 200) // reserve room for the sticky button
                }
            }

            // State signal is in the Dynamic Island via the live activity
            // (CaptureCoordinator.startLiveActivity). The on-screen overlay
            // would duplicate the island per Apple HIG — leave it out.

            VStack {
                Spacer()
                BottomActionStack {
                    if coordinator.isRecording {
                        // Two-button bottom while recording: Stop +
                        // Pause/Resume side-by-side at the same height.
                        // Stop is destructive (red) so the end-session
                        // action stays the visually heaviest signal;
                        // Pause/Resume is a calmer secondary that
                        // doesn't compete for attention.
                        HStack(spacing: Theme.spacing.sm) {
                            Button {
                                Task { await coordinator.toggle() }
                            } label: {
                                Label("Stop", systemImage: "stop.fill")
                            }
                            .buttonStyle(.dsDestructive(size: .lg, fullWidth: true))
                            .accessibilityLabel(Text("End recording"))

                            Button {
                                Task {
                                    if coordinator.isPaused {
                                        await coordinator.resume()
                                    } else {
                                        await coordinator.pause()
                                    }
                                }
                            } label: {
                                Label(
                                    coordinator.isPaused ? "Resume" : "Pause",
                                    systemImage: coordinator.isPaused
                                        ? "play.fill"
                                        : "pause.fill"
                                )
                            }
                            .buttonStyle(.dsSecondary(size: .lg, fullWidth: true))
                            .accessibilityLabel(Text(
                                coordinator.isPaused
                                    ? "Resume recording"
                                    : "Pause recording"
                            ))
                        }
                    } else {
                        // Idle CTA — disabled until Parakeet finished
                        // loading, exactly like the walkthrough's
                        // Sitzung-starten button. Loading label swaps
                        // in a spinner + caption.
                        Button {
                            Task { await coordinator.toggle() }
                        } label: {
                            startCtaLabel
                        }
                        .buttonStyle(.dsPrimary(size: .lg, fullWidth: true))
                        .disabled(!isModelReady)
                        .accessibilityLabel(Text("Start recording"))
                    }
                }
            }
            .ignoresSafeArea(.keyboard)
        }
        .task {
            await ParakeetManager.shared.warmUp()
            modelState = await ParakeetManager.shared.loadState
        }
    }

    private var isModelReady: Bool {
        if case .ready = modelState { return true }
        return false
    }

    /// Label inside the idle "Aufnahme starten" button. Mirrors the
    /// walkthrough's `startCtaLabel` so both screens behave identically
    /// while the on-device speech model is still loading.
    @ViewBuilder
    private var startCtaLabel: some View {
        switch modelState {
        case .ready:
            Label("Start recording", systemImage: "mic.fill")
        case .idle:
            HStack(spacing: Theme.spacing.xs) {
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(Theme.color.text.inverse)
                Text("Preparing speech model…")
            }
        case .loading:
            HStack(spacing: Theme.spacing.xs) {
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(Theme.color.text.inverse)
                Text("Loading speech model — ~1.2 GB")
            }
        case .failed(let msg):
            // `\(String(...))` so the formatted prefix passes through as
            // a String argument to the LocalizedStringKey, which we want
            // — otherwise `msg.prefix(...)` would block catalog lookup.
            Label("Speech model error: \(String(msg.prefix(40)))",
                  systemImage: "exclamationmark.triangle.fill")
        }
    }

    private var idleBody: some View {
        VStack(spacing: Theme.spacing.xl) {
            ZStack {
                Circle()
                    .fill(Theme.color.bg.containerInset)
                    .frame(width: 120, height: 120)
                Image(systemName: "mic.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(Theme.color.text.primary)
            }
            VStack(spacing: 8) {
                Text("Quick capture")
                    .font(Theme.font.title2)
                    .foregroundStyle(Theme.color.text.primary)
                Text("Catch a thought now. It resurfaces during this evening's walkthrough.")
                    .font(Theme.font.body)
                    .foregroundStyle(Theme.color.text.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Theme.spacing.md)
                Text(captureHint)
                    .font(Theme.font.caption)
                    .foregroundStyle(Theme.color.text.subdued)
                    .multilineTextAlignment(.center)
                    .padding(.top, Theme.spacing.xs)
            }
        }
    }

    private var recordingBody: some View {
        VStack(spacing: Theme.spacing.sm) {
            DisplayTimer(seconds: coordinator.elapsedSeconds)
            // Hint lives directly under the timer so it doesn't sit
            // below the sticky round button (which would shift the
            // button's Y between recording / idle).
            Text(captureHint)
                .font(Theme.font.caption)
                .foregroundStyle(Theme.color.text.subdued)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Theme.spacing.md)
        }
    }

    private var captureHint: AttributedString {
        // Plain `String(localized:)` so we can post-process the
        // AttributedString (styling the wake-word + Action button
        // mention). Uses `Bundle.main` which is already isa-swapped to
        // `LocalizedMainBundle` by `AppLanguage`, so the active
        // language is honoured.
        let raw: String
        if coordinator.isPaused {
            raw = String(localized: "Paused. Tap Resume to continue.")
        } else if coordinator.isRecording {
            raw = String(localized: "Say \u{201C}hey voice diary\u{201D} to ask a question.")
        } else {
            raw = String(localized: "Or press the Action button.")
        }
        var hint = AttributedString(raw)
        if let range = hint.range(of: "hey voice diary") {
            hint[range].font = Theme.font.monoCaption
            hint[range].foregroundColor = Theme.color.text.secondary
        }
        // Match either localized variant — German renders "Action-Knopf".
        let actionMarker = AppLanguage.shared.isGerman ? "Action-Knopf" : "Action button"
        if let range = hint.range(of: actionMarker) {
            hint[range].foregroundColor = Theme.color.text.secondary
        }
        return hint
    }
}

// CaptureRoundButtonStyle removed — Aufnahme starten / Stopp now
// share `dsPrimary` / `dsDestructive` shapes with the rest of the
// app (Walkthrough, TodoConfirm) for visual consistency.

// SeedSummaryCard removed — last-note playback + metadata now lives
// in the Verlauf tab so the recording screen stays single-purpose.

/// Inline capture-failure line under the record area. Its own view so the
/// recovery copy can be rendered in isolation (light / dark) by tests.
struct CaptureErrorText: View {
    let message: String

    var body: some View {
        Text(message)
            .font(Theme.font.footnote)
            .foregroundStyle(Theme.color.status.destructive)
            .multilineTextAlignment(.center)
            .padding(.horizontal, Theme.spacing.md)
    }
}
