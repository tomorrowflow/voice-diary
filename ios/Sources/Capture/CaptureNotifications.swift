import Foundation
import UserNotifications

// Transient local notification fired when a drive-by capture completes.
// Per SPEC §5.1 this is informational + auto-dismissed by the user (no
// push, no APNs, no third-party services).

@MainActor
public final class CaptureNotifications {
    public static let shared = CaptureNotifications()

    private init() {}

    public func requestAuthorisationIfNeeded() async {
        let centre = UNUserNotificationCenter.current()
        let settings = await centre.notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined:
            _ = try? await centre.requestAuthorization(options: [.alert, .sound])
        default:
            return
        }
    }

    public func fireCaptureComplete(
        duration: TimeInterval,
        transcriptPreview: String?
    ) async {
        await requestAuthorisationIfNeeded()
        let centre = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent()
        content.title = "\(Int(duration))s erfasst"
        if let preview = transcriptPreview, !preview.isEmpty {
            content.body = String(preview.prefix(120))
        } else {
            content.body = "Aufnahme gespeichert. Transkription läuft auf dem Server."
        }
        content.sound = .none
        content.interruptionLevel = .passive

        let request = UNNotificationRequest(
            identifier: "capture-complete-\(Date().timeIntervalSince1970)",
            content: content,
            trigger: nil  // deliver immediately
        )
        do {
            try await centre.add(request)
        } catch {
            Log.audio.warning(
                "Notification add failed: \(String(describing: error), privacy: .public)"
            )
        }
    }
}
