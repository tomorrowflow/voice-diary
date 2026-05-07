import AVFoundation
import Foundation
import os

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
    /// Fired once per silence-→-speech transition, *only* if at least
    /// one threshold had previously been crossed in the now-ending
    /// silence run. The coordinator listens for this to (a) clear the
    /// `silenceLevel` UI hint and (b) cancel any follow-up TTS that's
    /// still being generated/synthesised — so the AI doesn't speak
    /// over the user just because they paused for a moment.
    private var onSpeechResumed: (@Sendable () -> Void)?
    /// Silence thresholds only fire AFTER the user has spoken at least
    /// once since `start()`. Without this gate the first 3 s of
    /// "thinking before talking" right after the AI's opener finishes
    /// would immediately trip the 3 s threshold and open a wake-word
    /// window before the user has had a chance to start their
    /// reflection.
    ///
    /// We require **sustained** non-silence (≥ 200 ms) before flipping
    /// the flag — a single noise spike (HVAC, the AI's last-ms speaker
    /// bleed-through, a chair creak) is not "the user spoke". Once
    /// flipped, the flag stays true for the lifetime of the listen run.
    private var hasHeardSpeech: Bool = false
    private var sustainedSpeechSamples: Int = 0
    /// 200 ms of consecutive non-silent buffers count as real speech.
    /// Resolves to a sample count once `sampleRate` is known.
    public var minSpeechMillis: Int = 200

    public init() {}

    /// Begin observing. Resets internal state. `onThresholdCrossed`
    /// fires once per continuous silence run when 3 / 6 / 15 s is
    /// reached. `onSpeechResumed` fires when the user starts speaking
    /// again after at least one threshold had fired. Speaking resets
    /// the internal threshold tracker either way.
    public func start(
        onThresholdCrossed: @escaping @Sendable (Int) -> Void,
        onSpeechResumed: @escaping @Sendable () -> Void = { }
    ) {
        Diag.log("LullDetector.start (thresholds=\(thresholds))")
        queue.sync {
            self.silentSamples = 0
            self.lastFiredAtSecond = -1
            self.firedThresholds.removeAll()
            self.sampleRate = 0
            self.hasHeardSpeech = false
            self.sustainedSpeechSamples = 0
            self.onThresholdCrossed = onThresholdCrossed
            self.onSpeechResumed = onSpeechResumed
        }
    }

    public func stop() {
        Diag.log("LullDetector.stop")
        queue.sync {
            self.onThresholdCrossed = nil
            self.onSpeechResumed = nil
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
                // Silence breaks the sustained-speech accumulator. A
                // 50 ms cough → 100 ms silence → 50 ms cough sequence
                // is *not* "the user speaking" — we want a contiguous
                // ≥ 200 ms run.
                self.sustainedSpeechSamples = 0
                // Silence before the user has actually started
                // speaking doesn't count — the user is "thinking
                // before talking", not pausing mid-reflection.
                // Without this gate, every event would trip the 3 s
                // wake-word threshold the instant the listen phase
                // began.
                guard self.hasHeardSpeech else { return }
                self.silentSamples += frameCount
                let elapsedSeconds = Int(Double(self.silentSamples) / max(self.sampleRate, 1))
                for threshold in self.thresholds where elapsedSeconds >= threshold && !self.firedThresholds.contains(threshold) {
                    self.firedThresholds.insert(threshold)
                    Diag.log("LullDetector threshold crossed=\(threshold)s")
                    self.onThresholdCrossed?(threshold)
                }
            } else {
                // Non-silent buffer. Two kinds of work:
                //   1. Promote `hasHeardSpeech` once we've seen a
                //      sustained run (≥ minSpeechMillis). A single
                //      noise spike doesn't qualify.
                //   2. Reset the silence tracker + fire onSpeechResumed
                //      if we'd previously crossed a threshold.
                self.sustainedSpeechSamples += frameCount
                if !self.hasHeardSpeech {
                    let neededSamples = Int(self.sampleRate * Double(self.minSpeechMillis) / 1000.0)
                    if self.sustainedSpeechSamples >= max(neededSamples, 1) {
                        self.hasHeardSpeech = true
                        Diag.log("LullDetector hasHeardSpeech=true (sustained=\(self.sustainedSpeechSamples) samples)")
                    }
                }
                let hadFired = !self.firedThresholds.isEmpty
                self.silentSamples = 0
                self.firedThresholds.removeAll()
                if hadFired {
                    Diag.log("LullDetector speech resumed → reset thresholds")
                    self.onSpeechResumed?()
                }
            }
        }
    }
}
