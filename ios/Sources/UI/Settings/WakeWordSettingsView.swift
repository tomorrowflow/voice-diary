import Speech
import SwiftUI
import UIKit

/// Lets the user toggle wake-word recognition on/off, see whether
/// Apple's on-device dictation asset is installed for each supported
/// language, and recheck the status after they go fix it in iOS
/// Settings.
///
/// Why a separate page from PermissionsView: speech-recognition
/// *authorization* is a yes/no permission, but on-device recognition
/// also requires a per-language **asset** that ships out-of-band from
/// iOS itself. The user has to enable Dictation, add the language, and
/// then iOS downloads the asset whenever it feels like it (Wi-Fi +
/// often power required). There's no public API to force the download —
/// only to observe whether it has finished. Hence the caption
/// explaining the manual steps and the "erneut prüfen" button.
@MainActor
public struct WakeWordSettingsView: View {
    @State private var enabled: Bool = WakeWordPreferences.isEnabled
    @State private var deSupported: Bool =
        AppleStreamingRecognizer.supportsOnDeviceRecognition(language: "de")
    @State private var enSupported: Bool =
        AppleStreamingRecognizer.supportsOnDeviceRecognition(language: "en")

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
                        recheckButton
                        openSettingsButton
                    }
                    .padding(.horizontal, Theme.spacing.md)
                    .padding(.vertical, Theme.spacing.md)
                }
            }
        }
        .navigationBarHidden(true)
        .onAppear { recheck() }
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
        .background(
            RoundedRectangle(cornerRadius: Theme.radius.lg, style: .continuous)
                .fill(Theme.color.bg.container)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radius.lg, style: .continuous)
                .strokeBorder(Theme.color.border.subdued, lineWidth: 1)
        )
    }

    /// One row per supported walkthrough language. The status pill
    /// reflects `SFSpeechRecognizer.supportsOnDeviceRecognition` — i.e.
    /// whether the asset is *currently* installed. Goes green the
    /// moment iOS finishes downloading it and we re-poll.
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

            languageRow(label: String(localized: "German (de-DE)"), supported: deSupported)
            Divider().background(Theme.color.border.subdued)
            languageRow(label: String(localized: "English (en-US)"), supported: enSupported)

            Text("Voice Diary uses Apple’s dictation asset for wake-word recognition. While a language’s asset is missing, the wake word is off in that language — tapping still works, and all silence timers (3 / 6 / 15 / 20 s) fire unchanged.")
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

    private func languageRow(label: String, supported: Bool) -> some View {
        HStack {
            Text(label)
                .font(Theme.font.body)
                .foregroundStyle(Theme.color.text.primary)
            Spacer()
            StatusPill(
                text: supported ? String(localized: "Installed") : String(localized: "Downloading"),
                color: supported ? Theme.color.status.success : Theme.color.status.warning
            )
        }
    }

    /// What to actually do if German says "Wird geladen". There is no
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

            instructionRow(number: "1", text: String(localized: "iOS Settings → General → Keyboard → enable Dictation."))
            instructionRow(number: "2", text: String(localized: "In the same screen, open “Dictation Languages” and add German (Germany)."))
            instructionRow(number: "3", text: String(localized: "Connect to Wi-Fi and ideally plug in the device."))
            instructionRow(number: "4", text: String(localized: "Open the keyboard once, tap the microphone icon, and briefly dictate in German — that nudges iOS to start the download."))
            instructionRow(number: "5", text: String(localized: "Wait (sometimes minutes, sometimes hours), then tap “Re-check” below."))
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

    private func instructionRow(number: String, text: String) -> some View {
        HStack(alignment: .top, spacing: Theme.spacing.sm) {
            Text(number)
                .font(Theme.font.caption.weight(.semibold))
                .foregroundStyle(Theme.color.text.link)
                .frame(width: 20, alignment: .leading)
            Text(text)
                .font(Theme.font.caption)
                .foregroundStyle(Theme.color.text.subdued)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var recheckButton: some View {
        Button {
            recheck()
        } label: {
            Label("Re-check", systemImage: "arrow.clockwise")
        }
        .buttonStyle(DSButtonStyle(variant: .primary, size: .md, fullWidth: true))
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

    private var anySupported: Bool { deSupported || enSupported }

    private var toggleCaption: String {
        if !anySupported {
            return String(localized: "No dictation asset installed yet — wake word can’t be enabled. Follow the steps below and tap “Re-check”.")
        }
        if enabled {
            return String(localized: "Wake word is on. During an event, after 3 s of silence a listening window opens: “next” / “weiter” → next event, “done” / “fertig” → end the walkthrough.")
        }
        return String(localized: "Wake word is off. Keep tapping the arrow at the bottom right to step through events.")
    }

    private func recheck() {
        // Re-poll. SFSpeechRecognizer caches `supportsOnDeviceRecognition`
        // briefly so a fresh init each time picks up the latest state.
        deSupported = AppleStreamingRecognizer.supportsOnDeviceRecognition(language: "de")
        enSupported = AppleStreamingRecognizer.supportsOnDeviceRecognition(language: "en")

        // If neither language supports it any more, force-disable the
        // pref so the row state matches the toggle state on next launch.
        if !anySupported && enabled {
            enabled = false
            WakeWordPreferences.setEnabled(false)
        }
    }

    private func openSystemSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }
}

/// Compact status pill — same shape as the one in `PermissionsView`.
/// Inlined here rather than extracted because the two views are the
/// only consumers and a separate file would just add a hop.
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
