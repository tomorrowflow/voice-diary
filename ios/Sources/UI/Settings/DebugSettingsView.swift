import SwiftUI

// Stand-in until M11's full onboarding lands. Lets the user paste their
// Tailscale server URL + bearer token into Keychain and sanity-check
// reachability against /health.

@MainActor
public struct DebugSettingsView: View {
    @State private var serverURL: String = KeychainStore.read(.serverURL) ?? "http://"
    @State private var bearerToken: String = KeychainStore.read(.bearerToken) ?? ""
    @State private var statusText: String = "—"
    @State private var lastError: String?
    @StateObject private var reachability = Reachability()

    public init() {}

    public var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("http://my-server.tailnet.ts.net:8000", text: $serverURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(Theme.font.monoBody)
                    SecureField("IOS_BEARER_TOKEN", text: $bearerToken)
                        .font(Theme.font.monoBody)
                    Button {
                        save()
                    } label: {
                        Text("Speichern")
                    }
                    .buttonStyle(.dsPrimary(fullWidth: true))
                } header: {
                    Text("Tailscale")
                        .font(Theme.font.subheadline)
                        .foregroundStyle(Theme.color.text.secondary)
                }

                Section {
                    HStack {
                        Text("Status")
                            .font(Theme.font.body)
                            .foregroundStyle(Theme.color.text.primary)
                        Spacer()
                        StatusBadge(status: reachability.status)
                    }
                    Button {
                        Task { await refresh() }
                    } label: {
                        Text("Server prüfen")
                    }
                    .buttonStyle(.dsSecondary(fullWidth: true))
                } header: {
                    Text("Verbindung")
                        .font(Theme.font.subheadline)
                        .foregroundStyle(Theme.color.text.secondary)
                }

                if let lastError {
                    Section {
                        Text(lastError)
                            .font(Theme.font.monoCaption)
                            .foregroundStyle(Theme.color.status.destructive)
                    } header: {
                        Text("Fehler")
                            .font(Theme.font.subheadline)
                            .foregroundStyle(Theme.color.text.secondary)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.color.bg.surface.ignoresSafeArea())
            .navigationTitle("Server")
            .onChange(of: reachability.status) { _, newValue in
                statusText = describe(newValue)
            }
            .onAppear { Task { await refresh() } }
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
        statusText = describe(reachability.status)
    }

    private func describe(_ status: Reachability.Status) -> String {
        switch status {
        case .unknown: return "—"
        case .ok(let upstream): return "ok (\(upstream.count) upstream)"
        case .degraded(let upstream):
            let down = upstream.filter { $0.value != "ok" && $0.value != "skipped" && $0.value != "fixture" }
                                .map { "\($0.key)=\($0.value)" }
                                .joined(separator: ", ")
            return "degraded: \(down)"
        case .down(let reason):
            lastError = reason
            return "down"
        }
    }
}

private struct StatusBadge: View {
    let status: Reachability.Status

    var body: some View {
        HStack(spacing: Theme.spacing.xxs) {
            Circle()
                .fill(dotColor)
                .frame(width: 8, height: 8)
            Text(label)
                .font(Theme.font.callout)
                .foregroundStyle(textColor)
        }
        .padding(.horizontal, Theme.spacing.sm)
        .padding(.vertical, Theme.spacing.xxs)
        .background(
            Capsule().fill(bgColor)
        )
    }

    private var label: String {
        switch status {
        case .unknown:           return "—"
        case .ok:                return "OK"
        case .degraded:          return "degraded"
        case .down:              return "down"
        }
    }

    private var dotColor: Color {
        switch status {
        case .ok:                return Theme.color.status.success
        case .degraded:          return Theme.color.status.warning
        case .down, .unknown:    return Theme.color.status.destructive
        }
    }

    private var textColor: Color {
        switch status {
        case .ok:                return Theme.color.status.success
        case .degraded:          return Theme.color.status.warning
        case .down, .unknown:    return Theme.color.status.destructive
        }
    }

    private var bgColor: Color {
        switch status {
        case .ok:                return Theme.color.status.success.opacity(0.10)
        case .degraded:          return Theme.color.status.warning.opacity(0.10)
        case .down, .unknown:    return Theme.color.status.destructive.opacity(0.10)
        }
    }
}
