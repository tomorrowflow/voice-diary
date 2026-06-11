import SwiftUI

/// Server connection settings. Lets the user paste their Tailscale
/// server URL + bearer token into Keychain and sanity-check
/// reachability against `/health`.
@MainActor
public struct DebugSettingsView: View {
    @State private var serverURL: String = KeychainStore.read(.serverURL) ?? "http://"
    @State private var bearerToken: String = KeychainStore.read(.bearerToken) ?? ""
    @State private var lastError: String?
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
                SecureField("Paste your token", text: $bearerToken)
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
        .dsCard()
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
                DSStatusPill(text: statusLabel, color: statusColor)
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
        .dsCard()
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
            lastError = String(localized: "The server rejected the token (401). It doesn’t match the token configured on the server — paste it again and tap Save.")
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
