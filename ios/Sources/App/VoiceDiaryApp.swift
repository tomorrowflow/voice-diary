import SwiftUI

@main
struct VoiceDiaryApp: App {
    @Environment(\.scenePhase) private var scenePhase

    init() {
        Log.app.info("Voice Diary ready")
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .tint(Theme.color.text.link)
                .background(Theme.color.bg.surface.ignoresSafeArea())
                .onOpenURL { url in
                    Log.app.info("deep link: \(url.absoluteString, privacy: .public)")
                    IntentRouter.handleDeepLink(url)
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 250_000_000)
                        await IntentRouter.processPending(reason: "post_url")
                    }
                }
                .task {
                    await CaptureNotifications.shared.requestAuthorisationIfNeeded()
                    await IntentRouter.processPending(reason: "task")
                    DarwinIntentBridge.shared.start { @Sendable in
                        Task { @MainActor in
                            await IntentRouter.processPending(reason: "darwin")
                        }
                    }
                }
                .onChange(of: scenePhase) { _, newPhase in
                    if newPhase == .active {
                        Task { @MainActor in
                            await IntentRouter.processPending(reason: "scene_active")
                        }
                    }
                }
        }
    }
}

@MainActor
enum IntentRouter {
    /// Translate a `voicediary://capture/...` URL into an inbox action.
    static func handleDeepLink(_ url: URL) {
        guard url.scheme == "voicediary" else { return }
        let action: CaptureIntentInbox.Action
        switch url.path {
        case "/start": action = .start
        case "/stop":  action = .stop
        default:       action = .toggle
        }
        CaptureIntentInbox.write(action)
    }

    /// Drain whatever the App Intent / widget dropped into the App Group
    /// inbox and dispatch to the coordinator.
    static func processPending(reason: String) async {
        guard let action = CaptureIntentInbox.consume() else { return }
        Log.app.info(
            "processing intent \(action.rawValue, privacy: .public) (reason=\(reason, privacy: .public))"
        )
        let coordinator = CaptureCoordinator.shared
        switch action {
        case .toggle: await coordinator.toggle()
        case .start:  await coordinator.start()
        case .stop:   await coordinator.stop()
        }
    }
}

struct RootView: View {
    var body: some View {
        TabView {
            CaptureView()
                .tabItem { Label("Aufnahme", systemImage: "mic.circle") }

            WalkthroughView()
                .tabItem { Label("Abend", systemImage: "moon.stars") }

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
