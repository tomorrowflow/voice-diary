import SwiftUI

@main
struct VoiceDiaryApp: App {
    init() {
        Log.app.info("Voice Diary ready")
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .tint(Theme.color.text.link)
                .background(Theme.color.bg.surface.ignoresSafeArea())
                .onOpenURL { url in
                    handleDeepLink(url)
                }
                .task {
                    await CaptureNotifications.shared.requestAuthorisationIfNeeded()
                }
        }
    }

    @MainActor
    private func handleDeepLink(_ url: URL) {
        guard url.scheme == "voicediary" else { return }
        let action = url.host
        Log.app.info("deep link: \(action ?? "<nil>", privacy: .public)")
        Task { @MainActor in
            switch action {
            case "capture":
                // /start, /stop, /toggle. Treat all as toggle for v1.
                await CaptureCoordinator.shared.toggle()
            default:
                break
            }
        }
    }
}

struct RootView: View {
    var body: some View {
        TabView {
            CaptureView()
                .tabItem { Label("Aufnahme", systemImage: "mic.circle") }

            DebugUploadView()
                .tabItem { Label("Test-Upload", systemImage: "arrow.up.circle") }

            DebugSettingsView()
                .tabItem { Label("Server", systemImage: "gear") }
        }
        .font(Theme.font.body)
    }
}

#Preview {
    RootView()
}
