import SwiftUI

/// First-run flow shown over the tabs: server setup, then permission
/// priming. Each step is shown only when `OnboardingGate` says it is
/// still needed, so a returning user sees at most the step they missed.
@MainActor
struct OnboardingFlowView: View {
    enum Step: Identifiable {
        case server
        case permissions

        var id: Self { self }
    }

    @State private var step: Step
    private let onFinish: () -> Void

    init(start: Step, onFinish: @escaping () -> Void) {
        _step = State(initialValue: start)
        self.onFinish = onFinish
    }

    var body: some View {
        switch step {
        case .server:
            ServerSettingsView {
                OnboardingGate.markServerSetupDone()
                Task { await advanceFromServer() }
            }
        case .permissions:
            PermissionPrimingView {
                OnboardingGate.markPermissionPrimingDone()
                onFinish()
            }
        }
    }

    private func advanceFromServer() async {
        if await OnboardingGate.needsPermissionPriming() {
            step = .permissions
        } else {
            onFinish()
        }
    }
}

/// Explains why Voice Diary needs each capture permission, then asks for
/// them when the user taps Continue. No dialog appears before that tap.
@MainActor
struct PermissionPrimingView: View {
    @State private var isRequesting = false
    private let onFinish: () -> Void

    init(onFinish: @escaping () -> Void) {
        self.onFinish = onFinish
    }

    var body: some View {
        ZStack(alignment: .top) {
            Theme.color.bg.surface.ignoresSafeArea()

            VStack(spacing: 0) {
                FlowHeader(title: "Permissions")

                ScrollView {
                    VStack(spacing: Theme.spacing.md) {
                        Text("Voice Diary asks for these next. You can change them later under More → Permissions.")
                            .font(Theme.font.body)
                            .foregroundStyle(Theme.color.text.subdued)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        card(icon: "mic.fill",
                             title: "Microphone",
                             detail: "Voice Diary records your speech to reflect on the day chronologically. Without this, no event can be recorded.")
                        card(icon: "waveform.badge.mic",
                             title: "Speech recognition",
                             detail: "Recognises commands like “next” or “done” on-device so you can steer the walkthrough even with the screen locked. Without this, wake-word detection in the walkthrough is off; tapping still works.")
                        card(icon: "bell",
                             title: "Notifications",
                             detail: "A quiet note when a recording has been saved. Recording works without it.")
                    }
                    .padding(.horizontal, Theme.spacing.md)
                    .padding(.vertical, Theme.spacing.md)
                }

                BottomActionStack {
                    Button(action: advance) {
                        if isRequesting {
                            ProgressView().controlSize(.small)
                                .frame(maxWidth: .infinity)
                        } else {
                            Text("Continue")
                        }
                    }
                    .buttonStyle(DSButtonStyle(variant: .primary, size: .lg, fullWidth: true))
                    .disabled(isRequesting)
                }
            }
        }
        .navigationBarHidden(true)
    }

    private func card(icon: String, title: LocalizedStringKey, detail: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: Theme.spacing.sm) {
            HStack(spacing: Theme.spacing.sm) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(Theme.color.text.primary)
                    .frame(width: 28)
                Text(title)
                    .font(Theme.font.headline)
                    .foregroundStyle(Theme.color.text.primary)
                Spacer()
            }
            Text(detail)
                .font(Theme.font.caption)
                .foregroundStyle(Theme.color.text.subdued)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Theme.spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dsCard()
    }

    private func advance() {
        isRequesting = true
        Task {
            await Permissions.requestUndecided()
            isRequesting = false
            onFinish()
        }
    }
}
