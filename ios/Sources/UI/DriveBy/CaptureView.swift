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
                FlowHeader(title: "Aufnahme")

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
                            Text(lastError)
                                .font(Theme.font.footnote)
                                .foregroundStyle(Theme.color.status.destructive)
                                .padding(.horizontal, Theme.spacing.md)
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
                        // Destructive variant for "Stopp" — same shape +
                        // size as walkthrough's primary CTA, just
                        // tinted red so the active recording state
                        // reads at a glance.
                        Button {
                            Task { await coordinator.toggle() }
                        } label: {
                            Label("Stopp", systemImage: "stop.fill")
                        }
                        .buttonStyle(.dsDestructive(size: .lg, fullWidth: true))
                        .accessibilityLabel("Aufnahme beenden")
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
                        .accessibilityLabel("Aufnahme starten")
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
            Label("Aufnahme starten", systemImage: "mic.fill")
        case .idle:
            HStack(spacing: Theme.spacing.xs) {
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(Theme.color.text.inverse)
                Text("Sprachmodell wird vorbereitet…")
            }
        case .loading:
            HStack(spacing: Theme.spacing.xs) {
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(Theme.color.text.inverse)
                Text("Lade Sprachmodell — ~1,2 GB")
            }
        case .failed(let msg):
            Label("Sprachmodell-Fehler: \(msg.prefix(40))",
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
                Text("Schnell festhalten")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(Theme.color.text.primary)
                Text("Halte einen Gedanken fest. Er taucht abends im Walkthrough wieder auf.")
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
            Text(timeString(coordinator.elapsedSeconds))
                .font(.system(size: 64, weight: .regular, design: .monospaced))
                .foregroundStyle(Theme.color.text.primary)
                .monospacedDigit()
                .frame(height: 80)             // fixed slot — no vertical jump
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
        var hint = AttributedString(coordinator.isRecording
                                    ? "Sage „hey voice diary“ um eine Frage zu stellen."
                                    : "Oder drücke den Action-Knopf.")
        if let range = hint.range(of: "hey voice diary") {
            hint[range].font = Theme.font.monoCaption
            hint[range].foregroundColor = Theme.color.text.secondary
        }
        if let range = hint.range(of: "Action-Knopf") {
            hint[range].foregroundColor = Theme.color.text.secondary
        }
        return hint
    }

    private func timeString(_ s: Int) -> String {
        String(format: "%02d:%02d", s / 60, s % 60)
    }
}

// CaptureRoundButtonStyle removed — Aufnahme starten / Stopp now
// share `dsPrimary` / `dsDestructive` shapes with the rest of the
// app (Walkthrough, TodoConfirm) for visual consistency.

// SeedSummaryCard removed — last-seed playback + metadata now lives
// in the Verlauf tab so the recording screen stays single-purpose.
