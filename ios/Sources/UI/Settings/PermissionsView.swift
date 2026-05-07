import AVFoundation
import Speech
import SwiftUI
import UIKit

/// Manual fallback for the auto-request that runs at app launch
/// (`Permissions.requestStartupPermissions()`). Shows the *current*
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
                FlowHeader(title: "Berechtigungen")

                ScrollView {
                    VStack(spacing: Theme.spacing.md) {
                        permissionCard(
                            icon: "mic.fill",
                            title: "Mikrofon",
                            statusText: micStatusText,
                            statusColor: micStatusColor,
                            description: "Voice Diary nimmt deine Sprache auf, um den Tag chronologisch zu reflektieren. Ohne diese Erlaubnis kann kein Termin aufgenommen werden.",
                            actionLabel: actionLabel(for: micActionState),
                            actionState: micActionState,
                            isBusy: isRequestingMic,
                            action: micAction
                        )

                        permissionCard(
                            icon: "waveform.badge.mic",
                            title: "Spracherkennung",
                            statusText: speechStatusText,
                            statusColor: speechStatusColor,
                            description: "Erkennt Befehle wie „weiter\" oder „fertig\" lokal auf dem Gerät, damit du den Walkthrough auch bei gesperrtem Bildschirm steuern kannst. Ohne diese Erlaubnis ist die Wake-Word-Erkennung im Walkthrough deaktiviert; tippen funktioniert weiterhin.",
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
                                Text("Falls keine Abfrage erscheint: in iOS-Einstellungen ändern")
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

    /// What the button will actually do when tapped — labels and the
    /// disabled state derive from this, so the UI can never claim to
    /// "request access" when the system has already cached an answer.
    private enum ActionState: Equatable {
        /// First-time ask. Tapping triggers the system dialog.
        case canRequest
        /// Already granted. Button is disabled with a confirming label.
        case alreadyGranted
        /// Denied or restricted. Button deep-links to iOS Settings,
        /// because that's the only path back to "granted".
        case openSettings
    }

    private var micActionState: ActionState {
        switch micStatus {
        case .granted:     return .alreadyGranted
        case .denied:      return .openSettings
        default:           return .canRequest
        }
    }

    private var speechActionState: ActionState {
        switch speechStatus {
        case .authorized:           return .alreadyGranted
        case .denied, .restricted:  return .openSettings
        default:                    return .canRequest
        }
    }

    private func actionLabel(for state: ActionState) -> String {
        switch state {
        case .canRequest:     return "Zugriff anfragen"
        case .alreadyGranted: return "Bereits erlaubt"
        case .openSettings:   return "In iOS-Einstellungen ändern"
        }
    }

    private func actionIcon(for state: ActionState) -> String {
        switch state {
        case .canRequest:     return "checkmark.shield"
        case .alreadyGranted: return "checkmark.circle.fill"
        case .openSettings:   return "gear"
        }
    }

    /// Concrete `DSButtonStyle` per state. The disabled `dsPrimary`
    /// already greys itself when `.disabled(true)`, so the
    /// `alreadyGranted` button stays primary-styled but un-tappable.
    private func buttonStyle(for state: ActionState) -> DSButtonStyle {
        switch state {
        case .canRequest:     return DSButtonStyle(variant: .primary, size: .md, fullWidth: true)
        case .alreadyGranted: return DSButtonStyle(variant: .secondary, size: .md, fullWidth: true)
        case .openSettings:   return DSButtonStyle(variant: .outline, size: .md, fullWidth: true)
        }
    }

    private func micAction() {
        switch micActionState {
        case .canRequest:     requestMic()
        case .alreadyGranted: break
        case .openSettings:   openSystemSettings()
        }
    }

    private func speechAction() {
        switch speechActionState {
        case .canRequest:     requestSpeech()
        case .alreadyGranted: break
        case .openSettings:   openSystemSettings()
        }
    }

    @ViewBuilder
    private func permissionCard(
        icon: String,
        title: String,
        statusText: String,
        statusColor: Color,
        description: String,
        actionLabel: String,
        actionState: ActionState,
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
                StatusPill(text: statusText, color: statusColor)
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
            .disabled(isBusy || actionState == .alreadyGranted)
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

    // MARK: - Status mapping

    private var micStatusText: String {
        switch micStatus {
        case .granted: return "Erlaubt"
        case .denied: return "Nicht erlaubt"
        default: return "Noch nicht angefragt"
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
        case .authorized: return "Erlaubt"
        case .denied:     return "Nicht erlaubt"
        case .restricted: return "Eingeschränkt"
        default:          return "Noch nicht angefragt"
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
        // is the same path used at app launch + by the walkthrough's
        // wake-word window.
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

/// Compact status pill — same shape used elsewhere in the app for
/// state badges (cf. `QualityBadge` / `PiperBadge` in
/// `VoiceSettingsView`). Uses the DS palette so the pill colours
/// follow the same dark/light mode rules as the rest of the system.
private struct StatusPill: View {
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: Theme.spacing.xs) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(text)
                .font(Theme.font.caption2.weight(.medium))
                .foregroundStyle(color)
        }
        .padding(.horizontal, Theme.spacing.xs)
        .padding(.vertical, 3)
        .background(
            Capsule().fill(color.opacity(0.10))
        )
    }
}
