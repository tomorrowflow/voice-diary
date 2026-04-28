import AVFoundation
import Foundation

// Detects pauses in the user's speech during the walkthrough. Used by
// the state machine to fire a follow-up question at the 6-second lull
// (SPEC §6.2), and to surface the "soll ich weitermachen?" prompt at 15s.
//
// Implementation: RMS-amplitude threshold on the streaming PCM buffers
// from `AudioEngine`. Cheap, no extra model. M9/M12 can swap in
// FluidAudio's `VadManager` (Silero) for a more robust detector if false
// positives become a problem in noisy environments.
//
// All callbacks fire on the audio thread — wrap in `Task { @MainActor }`
// at the call site if you want UI work.

public final class LullDetector: @unchecked Sendable {
    /// RMS amplitude below this is considered "silent". 0.015 ≈ -36 dBFS,
    /// well above the device's noise floor in a typical room.
    public var silenceThreshold: Float = 0.015

    /// Thresholds (in seconds) at which `onThresholdCrossed` fires once
    /// per silence run. SPEC §6.2 specifies 3 / 6 / 15.
    public var thresholds: [Int] = [3, 6, 15]

    private let queue = DispatchQueue(label: "com.tomorrowflow.voice-diary.lull")
    private var silentSamples: Int = 0
    private var lastFiredAtSecond: Int = -1
    private var firedThresholds: Set<Int> = []
    private var sampleRate: Double = 0
    private var onThresholdCrossed: (@Sendable (Int) -> Void)?

    public init() {}

    /// Begin observing. Resets internal state. The callback receives the
    /// threshold (in seconds) that was just crossed — fired once per
    /// continuous silence run. Speaking resets the threshold tracker.
    public func start(onThresholdCrossed: @escaping @Sendable (Int) -> Void) {
        queue.sync {
            self.silentSamples = 0
            self.lastFiredAtSecond = -1
            self.firedThresholds.removeAll()
            self.sampleRate = 0
            self.onThresholdCrossed = onThresholdCrossed
        }
    }

    public func stop() {
        queue.sync {
            self.onThresholdCrossed = nil
        }
    }

    public func feed(_ buffer: AVAudioPCMBuffer) {
        guard let channel = buffer.floatChannelData?[0] else { return }
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return }

        // Compute RMS over the buffer.
        var sumSq: Float = 0
        for i in 0..<frameCount {
            let s = channel[i]
            sumSq += s * s
        }
        let rms = (sumSq / Float(frameCount)).squareRoot()
        let isSilent = rms < silenceThreshold

        let rate = buffer.format.sampleRate
        queue.sync {
            if self.sampleRate == 0 { self.sampleRate = rate }
            if isSilent {
                self.silentSamples += frameCount
                let elapsedSeconds = Int(Double(self.silentSamples) / max(self.sampleRate, 1))
                for threshold in self.thresholds where elapsedSeconds >= threshold && !self.firedThresholds.contains(threshold) {
                    self.firedThresholds.insert(threshold)
                    self.onThresholdCrossed?(threshold)
                }
            } else {
                // Speech detected — reset the lull tracker.
                self.silentSamples = 0
                self.firedThresholds.removeAll()
            }
        }
    }
}
