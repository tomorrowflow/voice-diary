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
                Section("Tailscale") {
                    TextField("http://my-server.tailnet.ts.net:8000", text: $serverURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("IOS_BEARER_TOKEN", text: $bearerToken)
                    Button("Speichern") { save() }
                }

                Section("Verbindung") {
                    HStack {
                        Text("Status")
                        Spacer()
                        Text(statusText)
                            .foregroundStyle(statusColor)
                    }
                    Button("Server prüfen") {
                        Task { await refresh() }
                    }
                }

                if let lastError {
                    Section("Fehler") {
                        Text(lastError)
                            .font(.caption.monospaced())
                            .foregroundStyle(.red)
                    }
                }
            }
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

    private var statusColor: Color {
        switch reachability.status {
        case .ok: return .green
        case .degraded: return .orange
        case .down, .unknown: return .red
        }
    }

    private func describe(_ status: Reachability.Status) -> String {
        switch status {
        case .unknown: return "—"
        case .ok(let upstream): return "ok (\(upstream.count) upstream)"
        case .degraded(let upstream):
            let down = upstream.filter { $0.value != "ok" && $0.value != "skipped" }
                                .map { "\($0.key)=\($0.value)" }
                                .joined(separator: ", ")
            return "degraded: \(down)"
        case .down(let reason):
            lastError = reason
            return "down"
        }
    }
}
