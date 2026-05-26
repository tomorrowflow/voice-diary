import AppIntents
import Foundation

// Note capture toggle exposed both as the Action Button binding
// ("Voice Diary — Notiz aufnehmen") and as the tap target of the
// lock-screen accessory widget. Living in `Sources/Shared` lets the
// widget extension reference the intent directly — that's what gives
// the lock-screen tap its haptic feedback (a `Link(URL)` doesn't
// trigger one; an App Intent button does).
//
// Behavior: each invocation toggles note capture. First press opens
// the app and starts a recording; second press (while recording)
// stops it. We *open the app on run* so AVAudioEngine has a foreground
// audio session — starting capture from a true background context is
// unreliable and we want the haptic + UI feedback anyway.
//
// The `AppShortcutsProvider` registration lives in
// `Sources/Intents/VoiceDiaryAppShortcuts.swift` — it's main-app-only
// so the widget extension doesn't accidentally re-register the
// shortcut.

public struct CaptureThoughtIntent: AppIntent {
    public static let title: LocalizedStringResource = "Notiz aufnehmen"
    public static let description = IntentDescription(
        "Startet (oder beendet) eine Notiz-Aufnahme. Lege diesen Intent auf den Action Button.",
        categoryName: "Capture"
    )

    /// Force the app to foreground when run from Action Button / lock-screen
    /// widget. AVAudioEngine reliably starts only from foreground contexts.
    public static let openAppWhenRun: Bool = true

    public init() {}

    public func perform() async throws -> some IntentResult {
        // IMPORTANT: this `perform` may run inside the App Intents
        // extension process, not the host app. We therefore CANNOT touch
        // `CaptureCoordinator.shared` directly — that's a different
        // singleton instance with its own (always-empty) `isRecording`
        // state, which is exactly the bug that caused "second press
        // starts another recording". Instead, drop a flag into the App
        // Group inbox; the host app consumes it on scenePhase active.
        CaptureIntentInbox.write(.toggle)
        return .result()
    }
}
