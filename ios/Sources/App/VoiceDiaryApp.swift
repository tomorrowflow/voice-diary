import SwiftUI

@main
struct VoiceDiaryApp: App {
    @Environment(\.scenePhase) private var scenePhase
    // Subscribe to the language singleton at the App level so a toggle in
    // settings instantly re-renders every SwiftUI view rooted in
    // RootView() against the new Bundle.main lproj. Without `@State` here
    // the root would still be tied to the old bundle until next launch.
    @State private var appLanguage = AppLanguage.shared

    init() {
        Log.app.info("Voice Diary ready")
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .tint(Theme.color.text.link)
                .background(Theme.color.bg.surface.ignoresSafeArea())
                // Locale drives date / number formatting + AttributedString
                // language matching for `Text(date:)`. Bundle.main swap +
                // `.id(bundleVersion)` together force LocalizedStringKey
                // re-lookups for every Text in the tree on each toggle.
                .environment(\.locale, appLanguage.locale)
                .id(appLanguage.bundleVersion)
                .onOpenURL { url in
                    Log.app.info("deep link: \(url.absoluteString, privacy: .public)")
                    IntentRouter.handleDeepLink(url)
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 250_000_000)
                        await IntentRouter.processPending(reason: "post_url")
                    }
                }
                .task {
                    // Sweep orphan recording temp files left behind by a
                    // crashed / suspended previous run. The writer
                    // stages each segment to `{stem}.tmp.m4a` and
                    // renames on clean close; a process death between
                    // those two steps leaves the temp file on disk.
                    // Old `{stem}.m4a.tmp` orphans from before the
                    // container fix are also caught by the same sweep.
                    // Runs once per app launch, before any capture
                    // intent is processed, so an Action Button press
                    // that immediately starts a new recording can never
                    // race the cleanup against its own staging file.
                    if let root = try? LocalStore.appSupport() {
                        let removed = M4AWriter.cleanupOrphans(in: root)
                        if removed > 0 {
                            Log.app.info(
                                "swept \(removed, privacy: .public) orphan recording temp file(s)"
                            )
                        }
                    }

                    // Re-tag every existing file/dir under VoiceDiary
                    // with the current protection class. iOS keeps a
                    // node's protection class for its lifetime —
                    // upgrading the constant in `LocalStore` doesn't
                    // touch dirs/files that already exist from earlier
                    // testing. Without this sweep, legacy `.complete`
                    // nodes left over from prior builds keep tripping
                    // CoreAudio's -54 even after the constant is
                    // relaxed. Cheap (a few hundred items, microseconds
                    // each) and idempotent.
                    let retagged = LocalStore.migrateProtectionClass()
                    Diag.log("LocalStore.migrateProtectionClass touched=\(retagged)")

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

                    // Pre-warm Parakeet. The CoreML Encoder takes ~15 s
                    // to specialise for the Neural Engine on each
                    // launch (no download — the .mlmodelc is already
                    // on disk; this is the JIT/ANE-link cost). Doing
                    // it here as a detached background task means by
                    // the time the user reaches the Abend / Aufnahme
                    // CTAs, the model is typically `.ready` and they
                    // never see the "Sprachmodell wird vorbereitet…"
                    // placeholder. Idempotent: when the view's own
                    // `.task` later calls `warmUp()`, it latches onto
                    // the in-flight load instead of restarting it.
                    Task.detached(priority: .userInitiated) {
                        await ParakeetManager.shared.warmUp()
                    }
                }
                .onChange(of: scenePhase) { _, newPhase in
                    switch newPhase {
                    case .active:
                        Task { @MainActor in
                            await IntentRouter.processPending(reason: "scene_active")
                        }
                        // Re-enable Gemma so the next opener (after
                        // the user returns) can use the German-stronger
                        // model again. No eager re-load here — it
                        // happens lazily on first need.
                        Task { await GemmaDialogLLM.shared.resume() }
                    case .background:
                        // Two reasons to suspend Gemma when backgrounded:
                        // (1) iOS background memory caps are far tighter
                        //     than our foreground increased-memory-limit,
                        //     so 5 GB of resident weights gets the process
                        //     jetsam'd within minutes.
                        // (2) Reloading those weights inside a backgrounded
                        //     process is itself unsafe — both because of
                        //     the same memory cap and because Metal is
                        //     restricted for backgrounded apps.
                        // `suspend()` drops the weights AND blocks the
                        // next `ensureLoaded` from kicking off, so the
                        // `ChainDialogLLM` falls through to Apple FM for
                        // any opener / follow-up that fires while we're
                        // backgrounded (e.g. when the user says "weiter"
                        // mid-walkthrough with the phone in their pocket).
                        Task { await GemmaDialogLLM.shared.suspend() }
                    default:
                        break
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
                .tabItem { Label("Evening", systemImage: "book.closed") }
                .tag(AppTab.abend)

            CaptureView()
                .tabItem { Label("Recording", systemImage: "mic.fill") }
                .tag(AppTab.aufnahme)

            NavigationStack { VerlaufView() }
                .tabItem { Label("History", systemImage: "list.bullet") }
                .tag(AppTab.verlauf)

            NavigationStack { MehrView() }
                .tabItem { Label("More", systemImage: "ellipsis.circle") }
                .tag(AppTab.mehr)
        }
        .font(Theme.font.body)
        .tint(Theme.color.text.primary)
    }
}

/// "Mehr" hub. Holds the secondary destinations (Stimmen, Server,
/// permissions). Each row pushes a navigation destination that renders
/// its own FlowHeader so the title alignment matches the front-rail
/// screens.
private struct MehrView: View {
    var body: some View {
        ZStack(alignment: .top) {
            Theme.color.bg.surface.ignoresSafeArea()

            VStack(spacing: 0) {
                FlowHeader(title: "More")

                List {
                    Section {
                        NavigationLink {
                            WalkthroughSectionsView()
                        } label: {
                            MehrRow(label: "Sections", systemImage: "text.bubble")
                        }
                        NavigationLink {
                            WalkthroughOrderView()
                        } label: {
                            MehrRow(label: "Order", systemImage: "arrow.up.arrow.down")
                        }
                        NavigationLink {
                            WalkthroughSettingsView()
                        } label: {
                            MehrRow(label: "Event filter", systemImage: "calendar")
                        }
                        NavigationLink {
                            VoiceSettingsView()
                        } label: {
                            MehrRow(label: "Voices", systemImage: "waveform")
                        }
                        NavigationLink {
                            DialogModelSettingsView()
                        } label: {
                            MehrRow(label: "Dialog model", systemImage: "brain")
                        }
                        NavigationLink {
                            LanguageSettingsView()
                        } label: {
                            MehrRow(label: "Language", systemImage: "globe")
                        }
                        NavigationLink {
                            PermissionsView()
                        } label: {
                            MehrRow(label: "Permissions", systemImage: "lock.shield")
                        }
                        NavigationLink {
                            WakeWordSettingsView()
                        } label: {
                            MehrRow(label: "Wake word", systemImage: "waveform.and.mic")
                        }
                        NavigationLink {
                            DebugSettingsView()
                        } label: {
                            MehrRow(label: "Server", systemImage: "server.rack")
                        }
                        NavigationLink {
                            DangerZoneView()
                        } label: {
                            MehrRow(label: "Danger zone", systemImage: "exclamationmark.triangle")
                        }
                    }
                }
                .scrollContentBackground(.hidden)
            }
        }
        .navigationBarHidden(true)
    }
}

private struct MehrRow: View {
    // `LocalizedStringKey` so the caller-side string literal flows
    // through Bundle.main's `Localizable.xcstrings` lookup instead of
    // being treated as a verbatim `String`. Caller writes
    // `MehrRow(label: "Sections", ...)`; the key "Sections" is what
    // Xcode extracts into the catalog and what `AppLanguage` swaps.
    let label: LocalizedStringKey
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
