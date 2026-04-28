import Foundation

// Bridge a Darwin (cross-process) notification to a Swift async callback.
// Used by the host app to wake up when the App Intent extension or the
// lock-screen widget writes a pending action — covers the case where the
// app is already foregrounded so SwiftUI's `scenePhase` doesn't change.

public final class DarwinIntentBridge: @unchecked Sendable {
    public static let shared = DarwinIntentBridge()

    private let queue = DispatchQueue(label: "com.tomorrowflow.voice-diary.darwin")
    private var handler: (@Sendable () -> Void)?
    private var registered: Bool = false

    private init() {}

    /// Idempotent: subsequent calls just replace the handler without
    /// stacking additional Darwin observers.
    public func start(onAction: @escaping @Sendable () -> Void) {
        queue.sync {
            self.handler = onAction
            guard !self.registered else { return }
            self.registered = true
        }
        let centre = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(
            centre,
            observer,
            { _, observer, _, _, _ in
                guard let observer else { return }
                let bridge = Unmanaged<DarwinIntentBridge>
                    .fromOpaque(observer)
                    .takeUnretainedValue()
                bridge.queue.async {
                    bridge.handler?()
                }
            },
            CaptureIntentInbox.darwinNotificationName as CFString,
            nil,
            .deliverImmediately
        )
    }

    deinit {
        let centre = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterRemoveEveryObserver(centre, Unmanaged.passUnretained(self).toOpaque())
    }
}
