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
//   1. M4A file writer       (AAC at ≥ 44.1 kHz mono — see writer-clamp note)
//   2. Parakeet streaming    (PCM Float32 buffers downsampled to 16 kHz mono — optional)
//   3. Wake-word streaming   (same 16 kHz mono path; toggled on/off per
//                             listen window via `setWakeWordSink`)
//
// iOS's AAC-LC encoder reliably initialises at 44.1 / 48 kHz but fails
// (`AudioCodecInitialize` returns -50; AVAudioFile surfaces it as
// `kAudioCodecUnsupportedFormatError` / 0x21646174 / '!dat') at 16 kHz
// — exactly what Bluetooth HFP devices like Plantronics / Aftershokz
// advertise as their input rate. AirPods happen to negotiate 24 kHz
// wideband HFP which slips through; non-Apple headsets typically don't.
// To survive *any* input route we therefore clamp the writer's encoder
// rate to ≥ 44.1 kHz and resample low-rate input buffers through a
// dedicated `writerUpsampler` before `write(from:)`. The server's
// ffmpeg still pulls audio down to 16 kHz mono before Whisper, so the
// wire format from the pipeline's perspective is unchanged.
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
// at end-of-walkthrough or end-of-note).
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

    /// Pinned route-change observer task. Lives for the whole engine
    /// lifetime; cancelled in `deinit`. The notification fires on a
    /// background queue, so we re-enter the actor via `await self?.…`.
    /// `nonisolated(unsafe)` because actor init can't touch isolated
    /// stored properties without async hops, and the task assignment
    /// happens exactly once during init before any other access.
    private nonisolated(unsafe) var routeObserverTask: Task<Void, Never>?

    public init() {
        // Spawn the route observer outside the actor's isolated init:
        // do the Sendable unpacking (reason raw value + rates) in the
        // notification's own context so we never hand a non-Sendable
        // `Notification` across the actor boundary, then re-enter the
        // actor with three plain UInt/Double values.
        let stream = NotificationCenter.default.notifications(
            named: AVAudioSession.routeChangeNotification
        )
        let task = Task { [weak self] in
            for await note in stream {
                let reasonRaw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
                let sessionRate = AVAudioSession.sharedInstance().sampleRate
                guard let self else { return }
                await self.handleRouteChange(
                    reasonRaw: reasonRaw,
                    sessionRate: sessionRate
                )
            }
        }
        self.routeObserverTask = task
    }

    deinit {
        routeObserverTask?.cancel()
    }

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
        let inputFormat = resolvedInputFormat(for: input)
        // One-line context so an M4AWriter -54 / -40 has a paired
        // "what did the engine think the mic looked like" entry. Useful
        // when input format is 0 Hz / 0 channels (engine not actually
        // up) or the AVAudioSession route flipped between prepare and
        // start.
        let session = AVAudioSession.sharedInstance()
        Diag.log(
            "AudioEngine.start inputFormat=\(Int(inputFormat.sampleRate))Hz "
            + "channels=\(inputFormat.channelCount) "
            + "sessionCategory=\(session.category.rawValue) "
            + "sessionMode=\(session.mode.rawValue) "
            + "engineRunning=\(engine.isRunning)"
        )
        // Pick an encoder-safe rate for the writer. Anything ≥ 44.1 kHz
        // passes through verbatim; anything below (HFP narrowband /
        // wideband from non-Apple BT mics) gets clamped to 48 kHz and
        // resampled in the tap callback below before write. Decoupling
        // the writer's rate from the input's rate is what makes the
        // M4A path immune to whichever HFP profile the headset
        // negotiated.
        let writerRate: Double = inputFormat.sampleRate >= 44_100
            ? inputFormat.sampleRate
            : 48_000
        let writerFormat: AVAudioFormat? = writerRate == inputFormat.sampleRate
            ? nil
            : AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: writerRate,
                channels: M4AWriter.channels,
                interleaved: false
            )
        let writerUpsampler: AVAudioConverter? = writerFormat.flatMap {
            AVAudioConverter(from: inputFormat, to: $0)
        }
        if writerFormat != nil {
            Diag.log(
                "AudioEngine.start writer clamp inputRate=\(Int(inputFormat.sampleRate)) "
                + "writerRate=\(Int(writerRate)) "
                + "(low-rate HFP input — upsampling to encoder-safe AAC)"
            )
        }
        try writer.open(at: outputURL, inputSampleRate: writerRate)
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

            // 1. File: write the buffer at the writer's rate. If the
            //    input came in below 44.1 kHz the upsampler converts
            //    each tap buffer to the writer's processing format
            //    first; otherwise we feed the raw buffer through.
            do {
                let writeBuffer: AVAudioPCMBuffer
                if let upsampler = writerUpsampler, let wf = writerFormat {
                    let cap = AVAudioFrameCount(
                        Double(buffer.frameLength) * wf.sampleRate / inputFormat.sampleRate
                    ) + 1024
                    guard let out = AVAudioPCMBuffer(
                        pcmFormat: wf,
                        frameCapacity: cap
                    ) else {
                        return
                    }
                    var convErr: NSError?
                    let status = upsampler.convert(to: out, error: &convErr) { _, outStatus in
                        outStatus.pointee = .haveData
                        return buffer
                    }
                    guard status == .haveData || status == .inputRanDry,
                          out.frameLength > 0
                    else { return }
                    writeBuffer = out
                } else {
                    writeBuffer = buffer
                }
                try writer.write(buffer: writeBuffer)
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
    /// walkthrough or one-shot note capture, when no further
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
        // Re-install the tap now that the engine is running. The input
        // node's hardware format is only reliable *post*-start, and the
        // no-op tap builds its wake-word downsampler from that format.
        // Without this, a wake-word window opened before any segment
        // recording — note review as the very first step (note
        // notes, zero calendar events) — would carry a downsampler made
        // from a possibly-stale pre-start format and silently drop every
        // buffer. Swapping taps on a live engine is safe (it's exactly
        // what `start(outputURL:)` does).
        installNoOpTap(onInput: input)
    }

    // MARK: - Route-change handling -------------------------------------
    //
    // `resolvedInputFormat(for:)` defends each individual `installTap`
    // by cross-checking the engine's node format against
    // `AVAudioSession.sampleRate`. That handles the case where the node
    // format went stale between segments. The observer below is the
    // proactive half: it catches the route flip the instant iOS reports
    // it (BT headset connect/disconnect, category change, override),
    // so that *next* `installNoOpTap` / `start()` reads a fresh
    // format — and so the user-visible log carries the explanation
    // when a session gets cut short by an HFP unplug.

    private func handleRouteChange(reasonRaw: UInt?, sessionRate: Double) async {
        let reason = reasonRaw.flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))
        let nodeRate = engine.inputNode.outputFormat(forBus: 0).sampleRate
        Diag.log(
            "AudioEngine routeChange reason=\(reason.map { "\($0.rawValue)" } ?? "nil") "
            + "sessionRate=\(Int(sessionRate)) nodeRate=\(Int(nodeRate)) "
            + "engineRunning=\(engineRunning) capturing=\(capturing)"
        )
        // While a segment is active the tap is bound to the old input
        // format; tearing it down here would discard the recording the
        // user just made. Let the current segment finish — `writerUpsampler`
        // keeps the AAC encoder happy even on rate drift — and only act
        // when we're between segments.
        guard !capturing else { return }
        guard let reason else { return }
        switch reason {
        case .newDeviceAvailable, .oldDeviceUnavailable,
             .routeConfigurationChange, .categoryChange, .override:
            // Drop the no-op tap so the next `installNoOpTap` /
            // `start()` builds a fresh one against the new format.
            // `resolvedInputFormat(for:)` will then read the updated
            // session rate; if it still finds the node format stale
            // it overrides verbatim. We deliberately do NOT call
            // `engine.stop()` — iOS rejects `engine.start()` from a
            // backgrounded process (see the file header), and a
            // route change can fire while the app is locked.
            if engineRunning {
                engine.inputNode.removeTap(onBus: 0)
                installNoOpTap()
            }
        default:
            break
        }
    }

    /// Return an input format that matches the **actual** hardware.
    ///
    /// `AVAudioInputNode.outputFormat(forBus: 0)` is documented to mirror
    /// the active hardware format, but in practice — particularly across
    /// `engine.stop()` → restart cycles, e.g. starting a second
    /// walkthrough — it can drift to a default 16 kHz mono even while the
    /// `AVAudioSession` is active at 44.1/48 kHz. `installTap` then
    /// validates against the real hardware (48 kHz) and throws
    /// `Failed to create tap due to format mismatch` (AVAEUtility.mm).
    /// Cross-check against `AVAudioSession.sharedInstance().sampleRate`
    /// (the OS-authoritative hw rate) and rebuild the format if they
    /// disagree.
    private func resolvedInputFormat(for node: AVAudioInputNode) -> AVAudioFormat {
        let nodeFormat = node.outputFormat(forBus: 0)
        let sessionRate = AVAudioSession.sharedInstance().sampleRate
        guard sessionRate > 0,
              nodeFormat.sampleRate > 0,
              abs(nodeFormat.sampleRate - sessionRate) > 1
        else {
            return nodeFormat
        }
        Diag.log(
            "AudioEngine.resolvedInputFormat overriding stale node format "
            + "nodeRate=\(Int(nodeFormat.sampleRate)) "
            + "sessionRate=\(Int(sessionRate))"
        )
        let channels: AVAudioChannelCount = nodeFormat.channelCount > 0 ? nodeFormat.channelCount : 1
        return AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sessionRate,
            channels: channels,
            interleaved: false
        ) ?? nodeFormat
    }

    private func installNoOpTap(onInput input: AVAudioInputNode? = nil) {
        let node = input ?? engine.inputNode
        node.removeTap(onBus: 0)
        let inputFormat = resolvedInputFormat(for: node)

        // Between segments we don't write a file, but we still feed the
        // wake-word sink *if one is set* — that's what makes the
        // note-review listen window work (no active recording there, so
        // `start(outputURL:)`'s tap isn't installed). When no sink is
        // set this stays a true no-op: the closure returns immediately
        // after the atomic `get()`. The downsampler mirrors the one in
        // `start(outputURL:)` so the wake-word ASR sees the same 16 kHz
        // mono buffers in both paths.
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

        node.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [wakeRef, downsampler, parakeetFormat] buffer, _ in
            guard buffer.frameLength > 0 else { return }
            // No wake sink → keep the AU hot, drop frames on the floor.
            guard let sink = wakeRef.get() else { return }
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
            sink(outBuf)
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
