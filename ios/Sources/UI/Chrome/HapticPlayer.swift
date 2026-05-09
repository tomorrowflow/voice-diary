import CoreHaptics
import Foundation
import os

/// Core-Haptics-backed tap feedback that survives `.playAndRecord`
/// audio capture.
///
/// `UIImpactFeedbackGenerator` (and the SwiftUI `.sensoryFeedback`
/// modifier on top of it) silently no-ops on iOS while the app is
/// actively recording — the system mutes the generator-driven Taptic
/// Engine so the haptic motor's vibration doesn't bleed into the
/// microphone. Drive-by start works because the haptic fires *before*
/// `engine.start()`; the walkthrough's Weiter button fires *while*
/// AVAudioEngine is mid-segment, which is exactly when the mute kicks
/// in.
///
/// `CHHapticEngine` with `playsHapticsOnly = true` declares "this
/// engine isn't using audio at all" — that's the documented escape
/// hatch from the recording-time mute. It's the same mechanism
/// FaceTime uses to vibrate during a live call.
///
/// Usage from SwiftUI:
/// ```swift
/// @State private var haptics = HapticPlayer()
///
/// Button { haptics.tap() } label: { … }
///     .task { haptics.start() }
/// ```
@MainActor
public final class HapticPlayer: ObservableObject {
    private var engine: CHHapticEngine?
    private var didFailToStart: Bool = false

    public init() {}

    /// Lazily start the haptic engine. Idempotent. Call on
    /// `.task` / `.onAppear` so the first `tap()` is hot.
    ///
    /// NOTE: even with the engine running, taps are silently muted by
    /// iOS while the app is recording in `.playAndRecord`. This isn't
    /// a bug in our setup — iOS suppresses haptics during active
    /// audio capture so the motor doesn't bleed into the mic. The
    /// engine still serves Begin (fires before recording starts) and
    /// any future non-recording context.
    public func start() {
        guard engine == nil, !didFailToStart else { return }
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else {
            // Older iPad / Mac Catalyst — no Taptic Engine at all.
            // Mark as failed so we don't keep retrying every appear.
            didFailToStart = true
            return
        }
        do {
            let e = try CHHapticEngine()
            e.playsHapticsOnly = true
            e.isAutoShutdownEnabled = false
            e.resetHandler = { [weak self] in
                Task { @MainActor in
                    try? await self?.engine?.start()
                }
            }
            try e.start()
            engine = e
        } catch {
            Log.audio.warning(
                "HapticPlayer engine start failed: \(String(describing: error), privacy: .public)"
            )
            didFailToStart = true
        }
    }

    /// Brief tap that mirrors `UIImpactFeedbackGenerator(style: .light)`.
    /// Fires reliably for non-recording contexts (Begin, end-of-walkthrough).
    /// Muted by iOS during active `.playAndRecord` recording — no
    /// software-side workaround is available for that case on iPhone.
    public func tap() {
        playTransient(intensity: 0.55, sharpness: 0.7)
    }

    /// Heavier confirmation tap. Use for "thing happened" rather than
    /// "I'm advancing". Currently unused but symmetric with
    /// `UIImpactFeedbackGenerator(style: .medium)`.
    public func confirm() {
        playTransient(intensity: 0.8, sharpness: 0.5)
    }

    private func playTransient(intensity: Float, sharpness: Float) {
        guard let engine else { return }
        // Defensive restart: an audio-session route change or
        // interruption may have stopped the engine without us noticing.
        // Calling start() on an already-running engine is a cheap no-op.
        try? engine.start()
        let event = CHHapticEvent(
            eventType: .hapticTransient,
            parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness),
            ],
            relativeTime: 0
        )
        do {
            let pattern = try CHHapticPattern(events: [event], parameters: [])
            let player = try engine.makePlayer(with: pattern)
            try player.start(atTime: 0)
        } catch {
            Log.audio.warning(
                "HapticPlayer tap failed: \(String(describing: error), privacy: .public)"
            )
        }
    }
}
