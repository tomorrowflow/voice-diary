import SwiftUI

/// Server connection settings. Lets the user paste their Tailscale
/// server URL + bearer token into Keychain and sanity-check
/// reachability against `/health`. Shown under Mehr → Server and, with
/// `onFinish`, as the first-run server setup.
@MainActor
public struct ServerSettingsView: View {
    @State private var serverURL: String = KeychainStore.read(.serverURL) ?? "http://"
    @State private var bearerToken: String = KeychainStore.read(.bearerToken) ?? ""
    @State private var lastError: String?
    @State private var hasSavedURL = false   // set by `refresh()` on appear
    @State private var pendingUploads: PendingUploadSummary?
    @StateObject private var reachability = Reachability()

    /// Set when presented as first-run setup; called when the user
    /// continues or skips. `nil` in Mehr → Server.
    private let onFinish: (() -> Void)?

    public init(onFinish: (() -> Void)? = nil) {
        self.onFinish = onFinish
    }

    public var body: some View {
        ZStack(alignment: .top) {
            Theme.color.bg.surface.ignoresSafeArea()

            VStack(spacing: 0) {
                FlowHeader(title: "Server")

                ScrollView {
                    VStack(spacing: Theme.spacing.md) {
                        if onFinish != nil {
                            Text("Connect Voice Diary to your server over Tailscale. You can change this later under More → Server.")
                                .font(Theme.font.body)
                                .foregroundStyle(Theme.color.text.subdued)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        tailscaleCard
                        // Right under the URL field: below the cards it
                        // scrolls out of sight behind the bottom actions.
                        if let lastError {
                            errorCard(lastError)
                        }
                        connectionCard
                        if !impactLines.isEmpty {
                            impactCard
                        }
                        if let pendingUploads {
                            pendingUploadsCard(pendingUploads)
                        }
                    }
                    .padding(.horizontal, Theme.spacing.md)
                    .padding(.vertical, Theme.spacing.md)
                }

                if let onFinish {
                    BottomActionStack {
                        Button(action: onFinish) {
                            // Two literals, not a ternary: a ternary resolves to
                            // `String` and would skip localization.
                            if isConnected { Text("Continue") } else { Text("Set up later") }
                        }
                        .buttonStyle(DSButtonStyle(variant: isConnected ? .primary : .secondary,
                                                   size: .lg, fullWidth: true))
                    }
                }
            }
        }
        .navigationBarHidden(true)
        .onAppear {
            Task { await refresh() }
        }
        .task {
            // The queue has no change notification and drains on its own
            // after a retry or a saved token, so re-read it while visible.
            while !Task.isCancelled {
                await refreshPendingUploads()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    /// One line per unhealthy upstream. Nothing is probed until a valid URL
    /// has been saved, so an old answer never outlives that.
    private var impactLines: [UpstreamImpactLine] {
        hasSavedURL ? UpstreamImpact.lines(health: reachability.upstream) : []
    }

    private var presentation: ServerConnectionPresentation {
        ServerConnectionPresentation(hasSavedURL: hasSavedURL, probeStatus: reachability.status)
    }

    private var isConnected: Bool { presentation.isConnected }

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
                Task { await refresh(explicit: true) }
            } label: {
                Label("Check server", systemImage: "arrow.clockwise")
            }
            .buttonStyle(DSButtonStyle(variant: .secondary, size: .md, fullWidth: true))
        }
        .padding(Theme.spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dsCard()
    }

    private var impactCard: some View {
        VStack(alignment: .leading, spacing: Theme.spacing.sm) {
            HStack(spacing: Theme.spacing.sm) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.title3)
                    .foregroundStyle(Theme.color.status.warning)
                    .frame(width: 28)
                Text("Services")
                    .font(Theme.font.headline)
                    .foregroundStyle(Theme.color.text.primary)
                Spacer()
            }

            ForEach(impactLines) { line in
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: line.name)
                        .font(Theme.font.body.weight(.medium))
                        .foregroundStyle(Theme.color.text.primary)
                    Text(line.impact)
                        .font(Theme.font.caption)
                        .foregroundStyle(Theme.color.text.subdued)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
            }
        }
        .padding(Theme.spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dsCard()
    }

    private func pendingUploadsCard(_ summary: PendingUploadSummary) -> some View {
        let explanation = summary.explanation()
        return VStack(alignment: .leading, spacing: Theme.spacing.sm) {
            HStack(spacing: Theme.spacing.sm) {
                Image(systemName: "arrow.up.circle")
                    .font(.title3)
                    .foregroundStyle(Theme.color.text.primary)
                    .frame(width: 28)
                Text("Upload queue")
                    .font(Theme.font.headline)
                    .foregroundStyle(Theme.color.text.primary)
                Spacer()
            }

            Text("\(summary.count) sessions waiting to upload")
                .font(Theme.font.body)
                .foregroundStyle(Theme.color.text.primary)

            if summary.partialCount > 0 {
                Text("\(summary.partialCount) sessions will upload without some recordings")
                    .font(Theme.font.caption)
                    .foregroundStyle(Theme.color.text.subdued)
            }

            if let explanation {
                VStack(alignment: .leading, spacing: 2) {
                    Text(explanation.title)
                        .font(Theme.font.caption.weight(.medium))
                        .foregroundStyle(Theme.color.text.primary)
                    Text(explanation.impact)
                        .font(Theme.font.caption)
                        .foregroundStyle(Theme.color.text.subdued)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
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
        switch ServerURLValidator.validate(serverURL) {
        case .failure(let issue):
            lastError = issue.message
            return
        case .success(let url):
            KeychainStore.write(url, for: .serverURL)
        }
        KeychainStore.write(bearerToken.trimmingCharacters(in: .whitespacesAndNewlines),
                            for: .bearerToken)
        lastError = nil
        // New URL or token: let uploads the server refused retry now.
        SessionUploader.shared.kick()
        Task { await refresh() }
    }

    private func refreshPendingUploads() async {
        pendingUploads = PendingUploadSummary.make(from: await SessionUploader.shared.pending())
    }

    /// `explicit` is the "Check server" button, which should say why
    /// nothing happened when there is no saved URL to probe.
    private func refresh(explicit: Bool = false) async {
        await refreshPendingUploads()
        // Probe only a stored URL that passes the format check; anything
        // else would surface as an opaque "down".
        guard let stored = KeychainStore.read(.serverURL),
              !stored.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            hasSavedURL = false
            lastError = explicit ? String(localized: "Save the server URL first, then check the server.") : nil
            return
        }
        if case .failure(let issue) = ServerURLValidator.validate(stored) {
            hasSavedURL = false
            lastError = issue.message
            return
        }
        hasSavedURL = true
        await reachability.refresh()
        applyStatusSideEffects(reachability.status)
    }

    private func applyStatusSideEffects(_ status: Reachability.Status) {
        switch ServerStatusError(status: status) {
        case .authentication:
            lastError = String(localized: "The server rejected the token (401). It doesn’t match the token configured on the server — paste it again and tap Save.")
        case .down(let reason):
            lastError = reason
        case nil:
            lastError = nil
        }
    }

    /// Human-readable summary of the bearer in Keychain so the user can
    /// sanity-check it against `server/.env` without ever seeing the
    /// full secret.
    private var bearerSummary: String {
        switch BearerSummaryProjection(KeychainStore.read(.bearerToken) ?? "") {
        case .empty:
            return String(localized: "(empty)")
        case .present(let count, let suffix):
            return "len=\(count) · …\(suffix)"
        }
    }

    // MARK: - Status mapping

    private var statusLabel: String {
        switch presentation.state {
        case .unknown:                       return "—"
        case .ok:                            return "OK"
        case .degraded:                      return String(localized: "degraded")
        case .authInvalid:                   return String(localized: "Bearer invalid")
        case .down:                          return String(localized: "down")
        }
    }

    private var statusColor: Color {
        switch presentation.state {
        case .ok:                            return Theme.color.status.success
        case .degraded:                      return Theme.color.status.warning
        case .authInvalid, .down:            return Theme.color.status.destructive
        case .unknown:                       return Theme.color.text.subdued
        }
    }
}
