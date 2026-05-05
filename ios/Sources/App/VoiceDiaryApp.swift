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
        // Four primary tabs in the bottom rail; secondary destinations
        // (Stimmen, Debug helpers) live behind the "Mehr" tab so the front
        // row stays focused on the capture/reflection flow.
        TabView {
            WalkthroughView()
                .tabItem { Label("Abend", systemImage: "book.closed") }

            CaptureView()
                .tabItem { Label("Aufnahme", systemImage: "mic.fill") }

            NavigationStack { VerlaufView() }
                .tabItem { Label("Verlauf", systemImage: "list.bullet") }

            NavigationStack { MehrView() }
                .tabItem { Label("Mehr", systemImage: "ellipsis.circle") }
        }
        .font(Theme.font.body)
        .tint(Theme.color.text.primary)
    }
}

/// "Mehr" hub. Holds the secondary destinations (Stimmen, debug pages
/// in DEBUG builds). Each row pushes a navigation destination that
/// renders its own FlowHeader so the title alignment matches the
/// front-rail screens.
private struct MehrView: View {
    var body: some View {
        ZStack(alignment: .top) {
            Theme.color.bg.surface.ignoresSafeArea()

            VStack(spacing: 0) {
                FlowHeader(title: "Mehr")

                List {
                    Section {
                        NavigationLink {
                            WalkthroughSectionsView()
                        } label: {
                            MehrRow(label: "Abschnitte", systemImage: "text.bubble")
                        }
                        NavigationLink {
                            WalkthroughOrderView()
                        } label: {
                            MehrRow(label: "Reihenfolge", systemImage: "arrow.up.arrow.down")
                        }
                        NavigationLink {
                            WalkthroughSettingsView()
                        } label: {
                            MehrRow(label: "Termin-Filter", systemImage: "calendar")
                        }
                        NavigationLink {
                            VoiceSettingsView()
                        } label: {
                            MehrRow(label: "Stimmen", systemImage: "waveform")
                        }
                    }

                    #if DEBUG
                    Section("Debug") {
                        NavigationLink {
                            DebugUploadView()
                        } label: {
                            MehrRow(label: "Test-Upload", systemImage: "arrow.up.circle")
                        }
                        NavigationLink {
                            DebugSettingsView()
                        } label: {
                            MehrRow(label: "Server", systemImage: "gear")
                        }
                    }
                    #endif
                }
                .scrollContentBackground(.hidden)
            }
        }
        .navigationBarHidden(true)
    }
}

private struct MehrRow: View {
    let label: String
    let systemImage: String
    var body: some View {
        Label(label, systemImage: systemImage)
            .font(Theme.font.body)
            .foregroundStyle(Theme.color.text.primary)
    }
}

// VerlaufPlaceholderView removed — replaced by the real
// `VerlaufView` in `Sources/UI/Verlauf/`.

#Preview {
    RootView()
}
