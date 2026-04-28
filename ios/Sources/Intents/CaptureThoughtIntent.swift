import AppIntents
import Foundation

// Action Button binding: "Voice Diary — Gedanke aufnehmen".
//
// Behavior: each invocation toggles drive-by capture. First press opens
// the app and starts a recording; second press (while recording)
// stops it. We *open the app on run* so AVAudioEngine has a foreground
// audio session — starting capture from a true background context is
// unreliable and we want the haptic + UI feedback anyway.

public struct CaptureThoughtIntent: AppIntent {
    public static let title: LocalizedStringResource = "Gedanke aufnehmen"
    public static let description = IntentDescription(
        "Startet (oder beendet) eine Drive-by-Aufnahme. Lege diesen Intent auf den Action Button.",
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

public struct VoiceDiaryAppShortcuts: AppShortcutsProvider {
    public static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: CaptureThoughtIntent(),
            phrases: [
                "Mit \(.applicationName) etwas aufnehmen",
                "Capture with \(.applicationName)",
                "Hey \(.applicationName), Notiz aufnehmen",
            ],
            shortTitle: "Gedanke aufnehmen",
            systemImageName: "mic.circle.fill"
        )
    }
}
