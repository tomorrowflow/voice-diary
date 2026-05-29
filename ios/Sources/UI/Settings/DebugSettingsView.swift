import SwiftUI

/// Server connection settings. Lets the user paste their Tailscale
/// server URL + bearer token into Keychain and sanity-check
/// reachability against `/health`.
@MainActor
public struct DebugSettingsView: View {
    @State private var serverURL: String = KeychainStore.read(.serverURL) ?? "http://"
    @State private var bearerToken: String = KeychainStore.read(.bearerToken) ?? ""
    @State private var lastError: String?
    @State private var voxtralBusy: Bool = false
    @StateObject private var reachability = Reachability()

    public init() {}

    public var body: some View {
        ZStack(alignment: .top) {
            Theme.color.bg.surface.ignoresSafeArea()

            VStack(spacing: 0) {
                FlowHeader(title: "Server")

                ScrollView {
                    VStack(spacing: Theme.spacing.md) {
                        tailscaleCard
                        connectionCard
                        voxtralCard
                        if let lastError {
                            errorCard(lastError)
                        }
                    }
                    .padding(.horizontal, Theme.spacing.md)
                    .padding(.vertical, Theme.spacing.md)
                }
            }
        }
        .navigationBarHidden(true)
        .onAppear { Task { await refresh() } }
    }

    // MARK: - Cards

    private var tailscaleCard: some View {
        VStack(alignment: .leading, spacing: Theme.spacing.sm) {
            HStack(spacing: Theme.spacing.sm) {
                Image(systemName: "network")
                    .font(.title3)
                    .foregroundStyle(Theme.color.text.primary)
                    .frame(width: 28)
                Text("Tailscale")
                    .font(Theme.font.headline)
                    .foregroundStyle(Theme.color.text.primary)
                Spacer()
            }

            VStack(alignment: .leading, spacing: Theme.spacing.xs) {
                Text("Server URL")
                    .font(Theme.font.caption)
                    .foregroundStyle(Theme.color.text.subdued)
                TextField("http://my-server.tailnet.ts.net:8000", text: $serverURL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(Theme.font.monoBody)
                    .foregroundStyle(Theme.color.text.primary)
                    .padding(Theme.spacing.sm)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.radius.md, style: .continuous)
                            .fill(Theme.color.bg.surface)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.radius.md, style: .continuous)
                            .strokeBorder(Theme.color.border.subdued, lineWidth: 1)
                    )
            }

            VStack(alignment: .leading, spacing: Theme.spacing.xs) {
                Text("Bearer Token")
                    .font(Theme.font.caption)
                    .foregroundStyle(Theme.color.text.subdued)
                SecureField("IOS_BEARER_TOKEN", text: $bearerToken)
                    .font(Theme.font.monoBody)
                    .foregroundStyle(Theme.color.text.primary)
                    .padding(Theme.spacing.sm)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.radius.md, style: .continuous)
                            .fill(Theme.color.bg.surface)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.radius.md, style: .continuous)
                            .strokeBorder(Theme.color.border.subdued, lineWidth: 1)
                    )
            }

            Button {
                save()
            } label: {
                Label("Save", systemImage: "checkmark")
            }
            .buttonStyle(DSButtonStyle(variant: .primary, size: .md, fullWidth: true))
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

    private var connectionCard: some View {
        VStack(alignment: .leading, spacing: Theme.spacing.sm) {
            HStack(spacing: Theme.spacing.sm) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.title3)
                    .foregroundStyle(Theme.color.text.primary)
                    .frame(width: 28)
                Text("Connection")
                    .font(Theme.font.headline)
                    .foregroundStyle(Theme.color.text.primary)
                Spacer()
                StatusPill(text: statusLabel, color: statusColor)
            }

            HStack {
                Text("Bearer")
                    .font(Theme.font.body)
                    .foregroundStyle(Theme.color.text.primary)
                Spacer()
                Text(bearerSummary)
                    .font(Theme.font.monoCaption)
                    .foregroundStyle(Theme.color.text.subdued)
            }

            Button {
                Task { await refresh() }
            } label: {
                Label("Check server", systemImage: "arrow.clockwise")
            }
            .buttonStyle(DSButtonStyle(variant: .secondary, size: .md, fullWidth: true))
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

    /// Slice 01 of the Voxtral TTS integration: a single button that
    /// synthesises one German line through the new server route and
    /// plays it on the device speaker. Server errors land in the
    /// existing `errorCard`. Once slice 02 ships the picker, this card
    /// can be retired.
    private var voxtralCard: some View {
        VStack(alignment: .leading, spacing: Theme.spacing.sm) {
            HStack(spacing: Theme.spacing.sm) {
                Image(systemName: "waveform.circle")
                    .font(.title3)
                    .foregroundStyle(Theme.color.text.primary)
                    .frame(width: 28)
                Text("Test Voxtral")
                    .font(Theme.font.headline)
                    .foregroundStyle(Theme.color.text.primary)
                Spacer()
            }

            Text("Synthesis via server → \(VoxtralTTS.fallbackVoice) · DE")
                .font(Theme.font.caption)
                .foregroundStyle(Theme.color.text.subdued)

            Button {
                Task { await runVoxtralTest() }
            } label: {
                if voxtralBusy {
                    Label("Playing…", systemImage: "play.circle")
                } else {
                    Label("Play sample", systemImage: "play.circle")
                }
            }
            .buttonStyle(DSButtonStyle(variant: .secondary, size: .md, fullWidth: true))
            .disabled(voxtralBusy)
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

    private func errorCard(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: Theme.spacing.sm) {
            HStack(spacing: Theme.spacing.sm) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.title3)
                    .foregroundStyle(Theme.color.status.destructive)
                    .frame(width: 28)
                Text("Error")
                    .font(Theme.font.headline)
                    .foregroundStyle(Theme.color.text.primary)
                Spacer()
            }
            Text(message)
                .font(Theme.font.caption)
                .foregroundStyle(Theme.color.text.subdued)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Theme.spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.radius.lg, style: .continuous)
                .fill(Theme.color.status.destructive.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radius.lg, style: .continuous)
                .strokeBorder(Theme.color.status.destructive.opacity(0.30), lineWidth: 1)
        )
    }

    // MARK: - Logic

    private func runVoxtralTest() async {
        voxtralBusy = true
        lastError = nil
        defer { voxtralBusy = false }
        do {
            try await VoxtralTTS.shared.speakOrThrow(
                text: "Hallo, ich bin die neue Stimme.",
                voice: VoxtralTTS.fallbackVoice,
                language: "DE"
            )
        } catch let error as VoxtralError {
            lastError = "Voxtral: \(describe(error))"
        } catch {
            lastError = "Voxtral: \(error.localizedDescription)"
        }
    }

    private func describe(_ error: VoxtralError) -> String {
        switch error {
        case .notConfigured:
            return String(localized: "No server URL or bearer in Keychain. Enter them above and tap Save.")
        case .unauthorized:
            return String(localized: "401 — bearer doesn’t match IOS_BEARER_TOKEN.")
        case .unknownVoice(let detail):
            return String(localized: "Voxtral doesn’t recognise this voice: \(detail)")
        case .unavailable(let detail):
            return String(localized: "Voxtral sidecar unreachable: \(detail)")
        case .timeout(let detail):
            return String(localized: "Server timeout: \(detail)")
        case .serverError(let status, let detail):
            return String(localized: "Server \(status): \(detail)")
        case .transport(let underlying):
            return String(localized: "Network error: \(underlying.localizedDescription)")
        case .decodeFailed(let reason):
            return String(localized: "Couldn’t read response: \(reason)")
        }
    }

    private func save() {
        KeychainStore.write(serverURL.trimmingCharacters(in: .whitespacesAndNewlines),
                            for: .serverURL)
        KeychainStore.write(bearerToken.trimmingCharacters(in: .whitespacesAndNewlines),
                            for: .bearerToken)
        lastError = nil
        Task { await refresh() }
    }

    private func refresh() async {
        await reachability.refresh()
        applyStatusSideEffects(reachability.status)
    }

    private func applyStatusSideEffects(_ status: Reachability.Status) {
        switch status {
        case .authInvalid:
            lastError = String(localized: "401 from server. Bearer in the app doesn’t match IOS_BEARER_TOKEN in server/.env. Paste the value again and tap Save.")
        case .down(let reason):
            lastError = reason
        case .ok, .degraded, .unknown:
            lastError = nil
        }
    }

    /// Human-readable summary of the bearer in Keychain so the user can
    /// sanity-check it against `server/.env` without ever seeing the
    /// full secret.
    private var bearerSummary: String {
        let stored = KeychainStore.read(.bearerToken) ?? ""
        if stored.isEmpty { return String(localized: "(empty)") }
        let suffix = String(stored.suffix(4))
        return "len=\(stored.count) · …\(suffix)"
    }

    // MARK: - Status mapping

    private var statusLabel: String {
        switch reachability.status {
        case .unknown:                       return "—"
        case .ok:                            return "OK"
        case .degraded:                      return String(localized: "degraded")
        case .authInvalid:                   return String(localized: "Bearer invalid")
        case .down:                          return String(localized: "down")
        }
    }

    private var statusColor: Color {
        switch reachability.status {
        case .ok:                            return Theme.color.status.success
        case .degraded:                      return Theme.color.status.warning
        case .authInvalid, .down:            return Theme.color.status.destructive
        case .unknown:                       return Theme.color.text.subdued
        }
    }
}

/// Compact status pill — same shape used elsewhere in the app for
/// state badges. Uses the DS palette so the pill colours follow the
/// same dark/light mode rules as the rest of the system.
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
