import AVFoundation
import Foundation
import Speech
import UserNotifications

/// The capture permissions the first-run priming screen asks for.
///
/// The walkthrough relies on three privacy-gated capabilities:
///
///   1. Microphone — needed to record any segment.
///   2. Speech Recognition (SFSpeechRecognizer with on-device de-DE) —
///      needed for the German wake-word path so the user can say
///      "weiter" / "nächstes" / "fertig" to advance.
///   3. Notifications — the transient capture-complete toast.
///
/// Nothing asks at app launch. The first-run onboarding explains all
/// three, and `requestUndecided()` fires the system dialogs only when
/// the user taps Continue there. Denying Speech Recognition silently
/// disables wake-word listening, which is why the reason is spelled out
/// first; `PermissionsView` stays the recovery path afterwards.
@MainActor
public enum Permissions {

    /// Which permissions the system has already answered (granted or
    /// denied). The system never shows its dialog again for those.
    public struct Snapshot: Equatable, Sendable {
        public var microphoneDecided: Bool
        public var speechDecided: Bool
        public var notificationsDecided: Bool

        public var allDecided: Bool { microphoneDecided && speechDecided && notificationsDecided }
    }

    public static func snapshot() async -> Snapshot {
        let notifications = await UNUserNotificationCenter.current().notificationSettings()
        return Snapshot(
            microphoneDecided: AVAudioApplication.shared.recordPermission != .undetermined,
            speechDecided: SFSpeechRecognizer.authorizationStatus() != .notDetermined,
            notificationsDecided: notifications.authorizationStatus != .notDetermined
        )
    }

    /// Show the system dialog for every permission still open, one after
    /// the other. Answered permissions are skipped, so a returning user
    /// is never asked twice.
    public static func requestUndecided() async {
        let before = await snapshot()

        if !before.microphoneDecided {
            let granted: Bool = await withCheckedContinuation { cont in
                AVAudioApplication.requestRecordPermission { granted in
                    cont.resume(returning: granted)
                }
            }
            Log.app.info(
                "permissions: microphone \(granted ? "granted" : "denied", privacy: .public)"
            )
        }

        if !before.speechDecided {
            do {
                try await AppleStreamingRecognizer.requestAuthorization()
                Log.app.info("permissions: speech recognition granted")
            } catch {
                Log.app.warning(
                    "permissions: speech recognition denied/unavailable — wake-word path will no-op until granted in Settings → Voice Diary → Speech Recognition (\(String(describing: error), privacy: .public))"
                )
            }
        }

        if !before.notificationsDecided {
            await CaptureNotifications.shared.requestAuthorisationIfNeeded()
        }
    }
}
