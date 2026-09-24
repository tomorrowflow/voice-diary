import SwiftUI

/// Controls how Voice Diary surfaces on the lock screen and in the
/// Dynamic Island. Today there's one toggle: whether the Live Activity
/// for a *paused* session stays visible. Default off — pausing is the
/// "step away from the flow" signal, and most users don't want a frozen
/// banner sitting on their lock screen until they come back.
@MainActor
public struct LockScreenSettingsView: View {
    @State private var showWhenPaused: Bool = LockScreenPreferences.showWhenPaused

    public init() {}

    public var body: some View {
        ZStack(alignment: .top) {
            Theme.color.bg.surface.ignoresSafeArea()

            VStack(spacing: 0) {
                FlowHeader(title: "Lock screen")

                ScrollView {
                    VStack(spacing: Theme.spacing.md) {
                        pausedToggleCard
                    }
                    .padding(.horizontal, Theme.spacing.md)
                    .padding(.vertical, Theme.spacing.md)
                }
            }
        }
        .navigationBarHidden(true)
    }

    private var pausedToggleCard: some View {
        VStack(alignment: .leading, spacing: Theme.spacing.sm) {
            HStack(spacing: Theme.spacing.sm) {
                Image(systemName: "pause.circle")
                    .font(.title3)
                    .foregroundStyle(Theme.color.text.primary)
                    .frame(width: 28)
                Text("Show paused session")
                    .font(Theme.font.headline)
                    .foregroundStyle(Theme.color.text.primary)
                Spacer()
                Toggle("", isOn: Binding(
                    get: { showWhenPaused },
                    set: { newValue in
                        showWhenPaused = newValue
                        LockScreenPreferences.setShowWhenPaused(newValue)
                    }
                ))
                .labelsHidden()
            }

            Text(showWhenPaused
                 ? String(localized: "While paused, the lock screen and Dynamic Island keep showing a frozen banner so you can jump straight back into the session.")
                 : String(localized: "Pausing hides the lock-screen banner and Dynamic Island. They re-appear automatically when you resume."))
                .font(Theme.font.caption)
                .foregroundStyle(Theme.color.text.subdued)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Theme.spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dsCard()
    }
}
