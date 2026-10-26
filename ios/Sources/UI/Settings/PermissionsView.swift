import AVFoundation
import Speech
import SwiftUI
import UIKit

/// Manual fallback for the first-run permission priming
/// (`PermissionPrimingView`). Shows the *current*
/// status of microphone and speech-recognition access and lets the
/// user trigger the system request again. iOS silently no-ops the
/// request once a status has been cached — the only way to flip
/// "Don't Allow" → "Allow" is then via the iOS Settings app, which
/// the caption beneath each card calls out explicitly.
@MainActor
public struct PermissionsView: View {
    // Apple uses a lowercase type name here (`AVAudioApplication.recordPermission`)
    // — unusual, but matches the framework header.
    @State private var micStatus: AVAudioApplication.recordPermission = AVAudioApplication.shared.recordPermission
    @State private var speechStatus: SFSpeechRecognizerAuthorizationStatus = SFSpeechRecognizer.authorizationStatus()
    @State private var isRequestingMic: Bool = false
    @State private var isRequestingSpeech: Bool = false

    public init() {}

    public var body: some View {
        ZStack(alignment: .top) {
            Theme.color.bg.surface.ignoresSafeArea()

            VStack(spacing: 0) {
                FlowHeader(title: "Permissions")

                ScrollView {
                    VStack(spacing: Theme.spacing.md) {
                        permissionCard(
                            icon: "mic.fill",
                            title: String(localized: "Microphone"),
                            statusText: micStatusText,
                            statusColor: micStatusColor,
                            description: String(localized: "Voice Diary records your speech to reflect on the day chronologically. Without this, no event can be recorded."),
                            actionLabel: actionLabel(for: micActionState),
                            actionState: micActionState,
                            isBusy: isRequestingMic,
                            action: micAction
                        )

                        permissionCard(
                            icon: "waveform.badge.mic",
                            title: String(localized: "Speech recognition"),
                            statusText: speechStatusText,
                            statusColor: speechStatusColor,
                            description: String(localized: "Recognises commands like “next” or “done” on-device so you can steer the walkthrough even with the screen locked. Without this, wake-word detection in the walkthrough is off; tapping still works."),
                            actionLabel: actionLabel(for: speechActionState),
                            actionState: speechActionState,
                            isBusy: isRequestingSpeech,
                            action: speechAction
                        )

                        // Footer note: explain why the button might
                        // not show a dialog. Tap target opens iOS
                        // Settings as the recovery path.
                        Button(action: openSystemSettings) {
                            HStack(spacing: Theme.spacing.xs) {
                                Image(systemName: "gear")
                                    .font(Theme.font.caption)
                                Text("If no prompt appears: change in iOS Settings")
                                    .font(Theme.font.caption)
                                    .multilineTextAlignment(.center)
                            }
                            .foregroundStyle(Theme.color.text.subdued)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, Theme.spacing.sm)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, Theme.spacing.md)
                    .padding(.vertical, Theme.spacing.md)
                }
            }
        }
        .navigationBarHidden(true)
        .onAppear { refreshStatus() }
    }

    // MARK: - Card

    private var micActionState: PermissionActionState {
        PermissionActionState(microphone: micStatus)
    }

    private var speechActionState: PermissionActionState {
        PermissionActionState(speech: speechStatus)
    }

    private func actionLabel(for state: PermissionActionState) -> String {
        switch state {
        case .canRequest:     return String(localized: "Request access")
        case .alreadyGranted: return String(localized: "Already granted")
        case .openSettings:   return String(localized: "Change in iOS Settings")
        }
    }

    private func actionIcon(for state: PermissionActionState) -> String {
        switch state {
        case .canRequest:     return "checkmark.shield"
        case .alreadyGranted: return "checkmark.circle.fill"
        case .openSettings:   return "gear"
        }
    }

    /// Concrete `DSButtonStyle` per state. The disabled `dsPrimary`
    /// already greys itself when `.disabled(true)`, so the
    /// `alreadyGranted` button stays primary-styled but un-tappable.
    private func buttonStyle(for state: PermissionActionState) -> DSButtonStyle {
        switch state {
        case .canRequest:     return DSButtonStyle(variant: .primary, size: .md, fullWidth: true)
        case .alreadyGranted: return DSButtonStyle(variant: .secondary, size: .md, fullWidth: true)
        case .openSettings:   return DSButtonStyle(variant: .outline, size: .md, fullWidth: true)
        }
    }

    private func micAction() {
        micActionState.perform(request: requestMic, openSettings: openSystemSettings)
    }

    private func speechAction() {
        speechActionState.perform(request: requestSpeech, openSettings: openSystemSettings)
    }

    @ViewBuilder
    private func permissionCard(
        icon: String,
        title: String,
        statusText: String,
        statusColor: Color,
        description: String,
        actionLabel: String,
        actionState: PermissionActionState,
        isBusy: Bool,
        action: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: Theme.spacing.sm) {
            // Header row: icon + title + status pill (right-aligned).
            HStack(spacing: Theme.spacing.sm) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(Theme.color.text.primary)
                    .frame(width: 28)
                Text(title)
                    .font(Theme.font.headline)
                    .foregroundStyle(Theme.color.text.primary)
                Spacer()
                DSStatusPill(text: statusText, color: statusColor)
            }

            // Description.
            Text(description)
                .font(Theme.font.caption)
                .foregroundStyle(Theme.color.text.subdued)
                .fixedSize(horizontal: false, vertical: true)

            // Action button. Label + behaviour vary by state:
            //   • `canRequest` (notDetermined) → primary, triggers
            //     the system dialog.
            //   • `alreadyGranted` → disabled with confirming label;
            //     iOS won't re-prompt and there's no useful action.
            //   • `openSettings` (denied/restricted) → secondary,
            //     deep-links to iOS Settings (the only way back).
            Button {
                action()
            } label: {
                if isBusy {
                    ProgressView().controlSize(.small)
                        .frame(maxWidth: .infinity)
                } else {
                    Label(actionLabel, systemImage: actionIcon(for: actionState))
                }
            }
            .buttonStyle(buttonStyle(for: actionState))
            .disabled(actionState.isDisabled(isBusy: isBusy))
        }
        .padding(Theme.spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dsCard()
    }

    // MARK: - Status mapping

    private var micStatusText: String {
        switch micStatus {
        case .granted: return String(localized: "Allowed")
        case .denied: return String(localized: "Denied")
        default: return String(localized: "Not requested yet")
        }
    }

    private var micStatusColor: Color {
        switch micStatus {
        case .granted: return Theme.color.status.success
        case .denied: return Theme.color.status.warning
        default: return Theme.color.text.subdued
        }
    }

    private func requestMic() {
        isRequestingMic = true
        // Use a fully `@MainActor`-bound async wrapper so the SwiftUI
        // state mutations stay on the main thread. The completion-
        // handler form was OK in Swift 5 but trips strict-concurrency
        // assertions on iOS 26 / Swift 6 in some edge cases.
        Task { @MainActor in
            let granted: Bool = await withCheckedContinuation { cont in
                AVAudioApplication.requestRecordPermission { granted in
                    cont.resume(returning: granted)
                }
            }
            isRequestingMic = false
            micStatus = AVAudioApplication.shared.recordPermission
            Log.app.info(
                "permissions: mic request → \(granted ? "granted" : "denied", privacy: .public)"
            )
        }
    }

    private var speechStatusText: String {
        switch speechStatus {
        case .authorized: return String(localized: "Allowed")
        case .denied:     return String(localized: "Denied")
        case .restricted: return String(localized: "Restricted")
        default:          return String(localized: "Not requested yet")
        }
    }

    private var speechStatusColor: Color {
        switch speechStatus {
        case .authorized:           return Theme.color.status.success
        case .denied, .restricted:  return Theme.color.status.warning
        default:                    return Theme.color.text.subdued
        }
    }

    private func requestSpeech() {
        isRequestingSpeech = true
        // Use the proven `AppleStreamingRecognizer.requestAuthorization`
        // wrapper instead of calling `SFSpeechRecognizer.requestAuthorization`
        // directly. The latter crashed on iOS 26 when called from a
        // SwiftUI button action (likely a Swift 6 strict-concurrency
        // collision in the completion-handler signature). The wrapper
        // is `withCheckedThrowingContinuation`-based, fully async, and
        // is the same path used by the first-run priming + the
        // walkthrough's wake-word window.
        Task { @MainActor in
            do {
                try await AppleStreamingRecognizer.requestAuthorization()
            } catch {
                // Already-determined statuses throw — that's expected
                // and not a failure of the call itself. We just refresh
                // the displayed status afterward.
            }
            isRequestingSpeech = false
            speechStatus = SFSpeechRecognizer.authorizationStatus()
            Log.app.info(
                "permissions: speech request → status=\(speechStatus.rawValue, privacy: .public)"
            )
        }
    }

    // MARK: - Helpers

    private func refreshStatus() {
        micStatus = AVAudioApplication.shared.recordPermission
        speechStatus = SFSpeechRecognizer.authorizationStatus()
    }

    private func openSystemSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }
}
