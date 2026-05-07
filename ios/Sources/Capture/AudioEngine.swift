import AVFoundation
import Foundation
import os

/// Thread-safe holder for the wake-word audio sink. The actor writes
/// (rare); the audio tap callback reads (every buffer). `Mutex` is
/// noncopyable and can't be captured by-value into the tap closure,
/// so we wrap an `OSAllocatedUnfairLock` in a class — that gives the
/// callback a stable reference without an `await`.
private final class WakeSinkBox: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock<(@Sendable (AVAudioPCMBuffer) -> Void)?>(initialState: nil)
    func set(_ sink: (@Sendable (AVAudioPCMBuffer) -> Void)?) {
        lock.withLock { $0 = sink }
    }
    func get() -> (@Sendable (AVAudioPCMBuffer) -> Void)? {
        lock.withLock { $0 }
    }
}

// AVAudioEngine wrapper with up to three sinks, all driven by the same
// input tap callback so we open the microphone exactly once:
//   1. M4A file writer       (AAC at the input's native sample rate, mono)
//   2. Parakeet streaming    (PCM Float32 buffers downsampled to 16 kHz mono — optional)
//   3. Wake-word streaming   (same 16 kHz mono path; toggled on/off per
//                             listen window via `setWakeWordSink`)
//
// We deliberately do not downsample on-device for the file write. iOS's
// AAC-LC encoder reliably initialises at 44.1 / 48 kHz but reportedly
// fails (`AudioCodecInitialize`) at 16 kHz. The server's ffmpeg pulls
// audio down to 16 kHz mono before Whisper, so the wire format from the
// pipeline's perspective is unchanged.
//
// One engine instance is shared. Don't open two engines.
//
// IMPORTANT — background recording lifecycle. iOS won't let an
// AVAudioEngine **start** the input AudioUnit while the screen is
// locked, even with `UIBackgroundModes: audio` and the session in
// `.playAndRecord`. The failing call is
// `PerformCommand(*ioNode, kAUStartIO, NULL, 0)` returning
// `kAudioUnitErr_CannotDoInCurrentContext` (0x77686174 / 'what').
// To survive screen-lock mid-walkthrough we therefore start the engine
// once in foreground via `prepareSession()` and keep it running
// across all segments — only the per-segment **tap + writer** rotates.
// `start(outputURL:)` installs the writer tap on an already-running
// engine; `stop()` removes the tap and finalises the file but leaves
// the engine alive. `shutdown()` is the explicit teardown call (used
// at end-of-walkthrough or end-of-drive-by).
//
// IMPORTANT — wake-word sink concurrency. The audio tap callback runs
// on CoreAudio's high-priority thread; it can't `await` actor state
// without serialising every buffer behind the actor's executor.
// `wakeWordSink` is therefore stored in a `Mutex` (atomic
// pointer-sized read on the audio thread, write from the actor when
// the coordinator opens / closes a listen window).

public actor AudioEngine {
    public enum EngineError: Error {
        case alreadyRunning
        case notRunning
        case sessionConfigFailed(String)
    }

    public static let parakeetTargetSampleRate: Double = 16_000

    private let engine = AVAudioEngine()
    private let writer = M4AWriter()
    private var engineRunning = false
    private var capturing = false
    private var streamingSink: (@Sendable (AVAudioPCMBuffer) -> Void)?

    /// Wake-word sink, lockable from both the actor (writes) and the
    /// audio tap callback (reads). The closure type is `@Sendable` so
    /// it's safe to invoke from any thread.
    private let wakeWordSink = WakeSinkBox()

    public init() {}

    /// Sample rate of the most recently written file (0 before any capture).
    public var lastSampleRate: Double { writer.sampleRate }

    /// Install / replace the wake-word PCM sink. Pass nil to remove.
    /// Buffers are forwarded from the next tap callback onward.
    public func setWakeWordSink(_ sink: (@Sendable (AVAudioPCMBuffer) -> Void)?) {
        wakeWordSink.set(sink)
    }

    /// Foreground preflight: configure the session, activate it, and
    /// boot the input AudioUnit. Once the AU is running its IO loop,
    /// subsequent `start(outputURL:)` calls only need to install a tap
    /// — the AU itself doesn't have to be cold-started, which is the
    /// thing iOS rejects from background.
    ///
    /// Idempotent: a second call is a cheap no-op once the engine is
    /// already running and the session is in `.playAndRecord`.
    public func prepareSession() async throws {
        try configureSession()
        try ensureEngineRunning()
    }

    /// Begin a new segment. Opens a fresh M4A writer at `outputURL` and
    /// (re)installs the input tap. Assumes `prepareSession()` has been
    /// called at least once already so the engine is live.
    ///
    /// `streaming` is invoked on the audio thread for each 16 kHz mono buffer
    /// when supplied — wire up Parakeet here once the SDK is bundled.
    public func start(
        outputURL: URL,
        streaming: (@Sendable (AVAudioPCMBuffer) -> Void)? = nil
    ) async throws {
        guard !capturing else { throw EngineError.alreadyRunning }

        // Belt-and-suspenders: configureSession is idempotent and
        // ensureEngineRunning will boot the AU if prepareSession() was
        // somehow skipped. In foreground these are no-ops; in
        // background they do the right thing on an already-prepared
        // session and fail loudly otherwise.
        try configureSession()
        try ensureEngineRunning()

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        try writer.open(at: outputURL, inputSampleRate: inputFormat.sampleRate)
        streamingSink = streaming

        // 16 kHz downsampler shared by Parakeet streaming + wake-word
        // sinks. We always create it (cheap) so the wake-word path can
        // be toggled on later via `setWakeWordSink` without
        // re-installing the tap.
        let parakeetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: AudioEngine.parakeetTargetSampleRate,
            channels: M4AWriter.channels,
            interleaved: false
        )
        let downsampler: AVAudioConverter? = parakeetFormat.flatMap {
            AVAudioConverter(from: inputFormat, to: $0)
        }
        let wakeRef = wakeWordSink

        // Replace whatever tap was on the input node — there might be
        // a no-op tap left over from `ensureEngineRunning`, or a writer
        // tap from a previous segment that wasn't cleanly stopped.
        input.removeTap(onBus: 0)
        input.installTap(
            onBus: 0,
            bufferSize: 4096,
            format: inputFormat
        ) { [writer, streamingSink, wakeRef] buffer, _ in
            // CoreAudio occasionally emits zero-frame buffers around tap
            // install / engine state transitions. Skipping them silences
            // the `mBuffers[0].mDataByteSize (0) should be non-zero`
            // warnings without losing real audio.
            guard buffer.frameLength > 0 else { return }

            // 1. File: write the buffer at native rate.
            do {
                try writer.write(buffer: buffer)
            } catch {
                Log.audio.error("writer error: \(String(describing: error), privacy: .public)")
            }

            // Read the wake-word sink atomically from the audio thread.
            let liveWakeSink = wakeRef.get()

            // 2 + 3. Streaming + wake-word both consume 16 kHz mono.
            // Skip the conversion entirely if neither needs it.
            guard streamingSink != nil || liveWakeSink != nil else { return }
            guard let downsampler, let parakeetFormat else { return }
            let frameCapacity = AVAudioFrameCount(
                Double(buffer.frameLength) * parakeetFormat.sampleRate / inputFormat.sampleRate
            ) + 1024
            guard let outBuf = AVAudioPCMBuffer(
                pcmFormat: parakeetFormat,
                frameCapacity: frameCapacity
            ) else { return }
            var error: NSError?
            let status = downsampler.convert(to: outBuf, error: &error) { _, outStatus in
                outStatus.pointee = .haveData
                return buffer
            }
            guard status == .haveData || status == .inputRanDry else { return }
            guard outBuf.frameLength > 0 else { return }
            if let sink = streamingSink { sink(outBuf) }
            if let sink = liveWakeSink { sink(outBuf) }
        }

        capturing = true
    }

    /// End the current segment. Removes the writer tap, finalises the
    /// M4A file, and reinstalls a no-op tap so the AudioUnit keeps
    /// pumping IO (which is what we need to survive a future
    /// background → foreground → record transition without restarting
    /// the AU). Engine itself stays running.
    public func stop() async throws -> URL? {
        guard capturing else { throw EngineError.notRunning }
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        let final = try writer.close()
        streamingSink = nil
        capturing = false
        // Re-install the no-op tap so the input AU keeps running. If
        // the engine is no longer alive (e.g. someone called shutdown
        // concurrently) skip silently.
        if engineRunning {
            installNoOpTap()
        }
        return final
    }

    /// Tear the engine down completely. Use at the very end of a
    /// walkthrough or one-shot drive-by capture, when no further
    /// segments are coming. Idempotent.
    public func shutdown() async {
        if capturing {
            engine.inputNode.removeTap(onBus: 0)
            try? writer.close()
            streamingSink = nil
            capturing = false
        }
        if engineRunning {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            engineRunning = false
        }
        wakeWordSink.set(nil)
    }

    // MARK: - Private

    private func ensureEngineRunning() throws {
        guard !engineRunning else { return }
        let input = engine.inputNode
        // Force the input AudioUnit to come up by installing a no-op
        // tap before `engine.start()`. Without a tap on the input bus
        // AVAudioEngine may decline to actually start the input AU,
        // which defeats the whole point of pre-arming.
        installNoOpTap(onInput: input)
        engine.prepare()
        try engine.start()
        engineRunning = true
    }

    private func installNoOpTap(onInput input: AVAudioInputNode? = nil) {
        let node = input ?? engine.inputNode
        node.removeTap(onBus: 0)
        let format = node.outputFormat(forBus: 0)
        node.installTap(onBus: 0, bufferSize: 4096, format: format) { _, _ in
            // Drop frames on the floor. The point is to keep the AU
            // hot; we don't write anything between segments.
        }
    }

    private func configureSession() throws {
        // playAndRecord (not record) so TTS playback shares the session.
        //
        // Mode `.default`:
        //   * No AGC — the user-set system volume is honoured verbatim
        //     between segments. (We previously used `.voiceChat`, which
        //     engages AGC + voice-processing and re-levels the TTS
        //     loudness after each recorded segment. The user noticed the
        //     drift: turn volume down on event 1 → events 2+ feel very
        //     calm because AGC compressed them based on segment-1 speech.)
        //   * No `.measurement` — that mode dampens output for ASR
        //     purity, which caused the original "I have to raise volume
        //     every time" bug.
        //   * No hardware AEC — acceptable because in our flow TTS always
        //     finishes BEFORE the mic opens (the `speak()` call awaits
        //     completion), so the AI's voice can't bleed into the
        //     recording.
        //
        // Note: we do NOT call setPreferredSampleRate here. Forcing 16 kHz
        // breaks the AAC encoder; instead we accept the device's native
        // rate (typically 44.1 / 48 kHz) and let the server downsample.
        let session = AVAudioSession.sharedInstance()
        do {
            // Skip the setCategory call when we're already in the right
            // mode — that's the only call that reliably fails from
            // background, and reconfiguring an already-correct session
            // would just throw away a working state.
            if session.category != .playAndRecord {
                try session.setCategory(
                    .playAndRecord,
                    mode: .default,
                    options: [.defaultToSpeaker, .allowBluetoothHFP]
                )
                try session.setPreferredIOBufferDuration(0.02)
            }
            try session.setActive(true, options: [])
        } catch {
            throw EngineError.sessionConfigFailed("\(error)")
        }
    }
}
