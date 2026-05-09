import AppIntents
import Foundation

// `CaptureThoughtIntent` itself moved to `Sources/Shared/CaptureThoughtIntent.swift`
// so the widget extension can reference it (the lock-screen widget's
// haptic-on-tap depends on going through an App Intent button rather
// than a URL link).
//
// `VoiceDiaryAppShortcuts` stays here — App Shortcuts must register
// in the main-app target only, not in the widget extension.

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
