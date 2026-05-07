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
                    // Notifications first (transient capture-complete
                    // toasts). Then mic + speech-recognition prompts
                    // up-front — see `Permissions.swift` for why we
                    // request these at launch instead of lazy. Then
                    // drain any pending capture intent (Action Button
                    // press while the app was suspended).
                    await CaptureNotifications.shared.requestAuthorisationIfNeeded()
                    await Permissions.requestStartupPermissions()
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

/// Tabs in `RootView`'s top-level TabView. Tagged so `AppRouter` can
/// programmatically switch tabs in response to lock-screen / Action
/// Button intents.
enum AppTab: Int, Hashable, Sendable {
    case abend = 0
    case aufnahme = 1
    case verlauf = 2
    case mehr = 3
}

/// Holds the currently-selected root tab so non-View code (the App
/// Intent inbox consumer below) can navigate the user to the right
/// place when they trigger a capture from the lock-screen widget or
/// the Action Button.
@MainActor
@Observable
final class AppRouter {
    static let shared = AppRouter()
    var selectedTab: AppTab = .abend
    private init() {}
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
    ///
    /// Side effect: any capture-related intent jumps the root TabView to
    /// the Aufnahme tab. The lock-screen widget's `CaptureThoughtIntent`
    /// only reaches us via this path (its `openAppWhenRun = true`
    /// surfaces the app, then scenePhase active triggers
    /// `processPending`); without the tab swap the user would land on
    /// whichever tab they happened to leave open.
    static func processPending(reason: String) async {
        guard let action = CaptureIntentInbox.consume() else { return }
        Log.app.info(
            "processing intent \(action.rawValue, privacy: .public) (reason=\(reason, privacy: .public))"
        )
        AppRouter.shared.selectedTab = .aufnahme
        let coordinator = CaptureCoordinator.shared
        switch action {
        case .toggle: await coordinator.toggle()
        case .start:  await coordinator.start()
        case .stop:   await coordinator.stop()
        }
    }
}

struct RootView: View {
    @State private var router = AppRouter.shared

    var body: some View {
        // Four primary tabs in the bottom rail; secondary destinations
        // (Stimmen, Debug helpers) live behind the "Mehr" tab so the front
        // row stays focused on the capture/reflection flow.
        //
        // The selection binding routes lock-screen / Action Button
        // intents to the Aufnahme tab — `IntentRouter.processPending`
        // sets `AppRouter.shared.selectedTab = .aufnahme` before
        // dispatching to the capture coordinator, so the user lands on
        // the recording UI no matter which tab they had open.
        TabView(selection: Binding(
            get: { router.selectedTab },
            set: { router.selectedTab = $0 }
        )) {
            WalkthroughView()
                .tabItem { Label("Abend", systemImage: "book.closed") }
                .tag(AppTab.abend)

            CaptureView()
                .tabItem { Label("Aufnahme", systemImage: "mic.fill") }
                .tag(AppTab.aufnahme)

            NavigationStack { VerlaufView() }
                .tabItem { Label("Verlauf", systemImage: "list.bullet") }
                .tag(AppTab.verlauf)

            NavigationStack { MehrView() }
                .tabItem { Label("Mehr", systemImage: "ellipsis.circle") }
                .tag(AppTab.mehr)
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
                        NavigationLink {
                            PermissionsView()
                        } label: {
                            MehrRow(label: "Berechtigungen", systemImage: "lock.shield")
                        }
                        NavigationLink {
                            WakeWordSettingsView()
                        } label: {
                            MehrRow(label: "Wake-Word", systemImage: "waveform.and.mic")
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
