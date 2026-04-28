import AVFoundation
import SwiftUI

// In-app record button. Delegates all state to `CaptureCoordinator` so the
// App Intent (Action Button) and lock-screen widget stay in sync.

@MainActor
public struct CaptureView: View {
    @State private var coordinator = CaptureCoordinator.shared
    @State private var modelState: ParakeetManager.LoadState = .idle
    @State private var modelStatusLine: String = ""

    public init() {}

    public var body: some View {
        NavigationStack {
            ZStack {
                Theme.color.bg.surface.ignoresSafeArea()

                VStack(spacing: Theme.spacing.xxl) {
                    Spacer()

                    Button {
                        Task { await coordinator.toggle() }
                    } label: {
                        ZStack {
                            Circle()
                                .fill(coordinator.isRecording
                                      ? Theme.color.status.destructive
                                      : Theme.color.fg.primary)
                                .frame(width: 160, height: 160)
                                .shadow(color: Theme.color.bg.overlay, radius: 20, y: 8)
                            Image(systemName: coordinator.isRecording ? "stop.fill" : "mic.fill")
                                .font(.system(size: 56))
                                .foregroundStyle(Theme.color.text.inverse)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(coordinator.isRecording ? "Aufnahme beenden" : "Aufnahme starten")

                    Text(timeString(coordinator.elapsedSeconds))
                        .font(.system(size: 32, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Theme.color.text.secondary)

                    if !modelStatusLine.isEmpty {
                        Text(modelStatusLine)
                            .font(Theme.font.callout)
                            .foregroundStyle(Theme.color.text.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, Theme.spacing.md)
                    }

                    if !coordinator.statusLine.isEmpty {
                        Text(coordinator.statusLine)
                            .font(Theme.font.callout)
                            .foregroundStyle(Theme.color.text.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, Theme.spacing.md)
                    }

                    if let seed = coordinator.lastSeed {
                        SeedSummaryCard(seed: seed)
                    }

                    if let lastError = coordinator.lastError {
                        Text(lastError)
                            .font(Theme.font.footnote)
                            .foregroundStyle(Theme.color.status.destructive)
                            .padding(.horizontal, Theme.spacing.md)
                    }

                    Spacer()
                }
                .padding(.horizontal, Theme.spacing.md)
            }
            .navigationTitle("Drive-by")
            .task {
                await ParakeetManager.shared.warmUp()
                modelState = await ParakeetManager.shared.loadState
                if case .loading = modelState {
                    modelStatusLine = "Lade Sprachmodell — beim ersten Start ~1,2 GB."
                } else if case .failed(let msg) = modelState {
                    modelStatusLine = "Sprachmodell konnte nicht geladen werden: \(msg.prefix(120))"
                } else {
                    modelStatusLine = ""
                }
            }
        }
    }

    private func timeString(_ s: Int) -> String {
        String(format: "%02d:%02d", s / 60, s % 60)
    }
}

private struct SeedSummaryCard: View {
    let seed: DriveBySeed

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spacing.xs) {
            Text("Letzter Seed")
                .font(Theme.font.headline)
                .foregroundStyle(Theme.color.text.primary)
            Text(seed.audio_file_url.lastPathComponent)
                .font(Theme.font.monoCaption)
                .foregroundStyle(Theme.color.text.secondary)
            Text("\(String(format: "%.1f", seed.duration_seconds)) s · \(seed.language)")
                .font(Theme.font.caption)
                .foregroundStyle(Theme.color.text.subdued)
            if !seed.transcript.isEmpty {
                Text(seed.transcript)
                    .font(Theme.font.callout)
                    .foregroundStyle(Theme.color.text.primary)
                    .padding(.top, Theme.spacing.xs)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.spacing.md)
        .background(
            RoundedRectangle(cornerRadius: Theme.radius.lg, style: .continuous)
                .fill(Theme.color.bg.container)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radius.lg, style: .continuous)
                .strokeBorder(Theme.color.border.subdued, lineWidth: 1)
        )
        .padding(.horizontal, Theme.spacing.md)
    }
}
