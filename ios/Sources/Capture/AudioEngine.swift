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

/// Format-keyed converter cache used by the tap callback. The previous
/// design captured `inputFormat` + the converters into the closure at
/// install time — which crashes with `Failed to create tap due to
/// format mismatch` whenever AVAudioEngine's input AU re-initialises
/// (category change, route flip) between `engine.start()` and our
/// `installTap` call: node format reports stale 44.1 kHz while the
/// underlying hw is already at 48 kHz.
///
/// New design pairs `installTap(format: nil)` (which sidesteps the
/// install-time mismatch entirely — AVAudioEngine uses the bus's
/// live format) with this cache, which rebuilds the converters
/// lazily whenever `buffer.format` changes. A mid-stream route flip
/// now just triggers a rebuild on the next buffer instead of an
/// uncatchable NSException.
private final class TapConverterCache: @unchecked Sendable {
    struct State: Sendable {
        let inputFormat: AVAudioFormat
        let writerFormat: AVAudioFormat?
        let writerUpsampler: AVAudioConverter?
        let parakeetFormat: AVAudioFormat
        let downsampler: AVAudioConverter?
    }

    private let lock = OSAllocatedUnfairLock<State?>(initialState: nil)
    private let writerRate: Double

    init(writerRate: Double) { self.writerRate = writerRate }

    func state(for inputFormat: AVAudioFormat) -> State {
        lock.withLock { current in
            if let s = current, Self.matches(s.inputFormat, inputFormat) {
                return s
            }
            let built = Self.build(inputFormat: inputFormat, writerRate: writerRate)
            current = built
            return built
        }
    }

    private static func matches(_ a: AVAudioFormat, _ b: AVAudioFormat) -> Bool {
        a.sampleRate == b.sampleRate
            && a.channelCount == b.channelCount
            && a.commonFormat == b.commonFormat
    }

    private static func build(inputFormat: AVAudioFormat, writerRate: Double) -> State {
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
        let parakeetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: AudioEngine.parakeetTargetSampleRate,
            channels: M4AWriter.channels,
            interleaved: false
        )!
        let downsampler = AVAudioConverter(from: inputFormat, to: parakeetFormat)
        return State(
            inputFormat: inputFormat,
            writerFormat: writerFormat,
            writerUpsampler: writerUpsampler,
            parakeetFormat: parakeetFormat,
            downsampler: downsampler
        )
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

    /// Pinned AVAudioSession interruption observer task. Mirrors the
    /// route-change pattern above. On `.began` we finalise the in-flight
    /// chunk so the moov atom lands on disk even though the app may be
    /// suspended immediately after; on `.ended` we try a clean restart if
    /// `.shouldResume` is set. `nonisolated(unsafe)` for the same reason
    /// as `routeObserverTask`.
    private nonisolated(unsafe) var interruptionObserverTask: Task<Void, Never>?

    /// Set to `true` by the `.began` handler when a capture is in
    /// progress at interruption time. Cleared by the `.ended` handler
    /// after re-opening the chunk (or on the next `start()` call).
    private var captureWasInterrupted = false

    /// Wall-clock timestamp of the most recent
    /// `AVAudioSession.routeChangeNotification` we received. `start()`
    /// reads this right before installing the tap: if a route change
    /// just fired (within the last ~300 ms), the kernel-mode input AU
    /// is in the middle of reinitialising and the format we just read
    /// is unreliable. We settle and re-read in that window.
    private var lastRouteChangeAt: Date = .distantPast

    public init() {
        // Spawn the route observer outside the actor's isolated init:
        // do the Sendable unpacking (reason raw value + rates) in the
        // notification's own context so we never hand a non-Sendable
        // `Notification` across the actor boundary, then re-enter the
        // actor with three plain UInt/Double values.
        let routeStream = NotificationCenter.default.notifications(
            named: AVAudioSession.routeChangeNotification
        )
        let routeTask = Task { [weak self] in
            for await note in routeStream {
                let reasonRaw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
                let sessionRate = AVAudioSession.sharedInstance().sampleRate
                guard let self else { return }
                await self.handleRouteChange(
                    reasonRaw: reasonRaw,
                    sessionRate: sessionRate
                )
            }
        }
        self.routeObserverTask = routeTask

        // Spawn the interruption observer in the same pattern. The
        // notification delivers `.began` / `.ended` type codes; we
        // unpack them here (Sendable-safe integers) and re-enter the
        // actor. On `.began` while capturing we finalise the current
        // writer chunk so the moov atom is durable before the system
        // suspends us. On `.ended` with `shouldResume` we try to re-
        // activate the session and open a fresh chunk.
        let interruptStream = NotificationCenter.default.notifications(
            named: AVAudioSession.interruptionNotification
        )
        let interruptTask = Task { [weak self] in
            for await note in interruptStream {
                let typeRaw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
                let optionsRaw = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt
                guard let self else { return }
                await self.handleInterruption(typeRaw: typeRaw, optionsRaw: optionsRaw)
            }
        }
        self.interruptionObserverTask = interruptTask
    }

    deinit {
        routeObserverTask?.cancel()
        interruptionObserverTask?.cancel()
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
        // Cross-check: if `engineRunning` thinks the engine is alive
        // but `engine.isRunning` disagrees, the engine died while
        // backgrounded (interruption, jetsam partial teardown). Reset
        // the flag so `ensureEngineRunning()` does a full cold-start
        // rather than returning early on a dead engine.
        if engineRunning && !engine.isRunning {
            Diag.log("AudioEngine.prepareSession: flag/reality mismatch — forcing restart")
            engineRunning = false
        }
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

        // A new capture clears the interrupted flag — whatever happened
        // before is now replaced by a fresh segment.
        captureWasInterrupted = false

        // Belt-and-suspenders: configureSession is idempotent and
        // ensureEngineRunning will boot the AU if prepareSession() was
        // somehow skipped. In foreground they're typically no-ops; the
        // only path that actually changes anything is the rare case
        // where the audio session drifted to a different category
        // (e.g. Verlauf playback left it in `.playback`) — that
        // category flip re-initialises the kernel-mode input AU and
        // the format the node reports lags behind the actual hw rate
        // by a few hundred ms. Installing a tap against the stale
        // format crashes uncatchably. Settling for 120 ms after a
        // real flip closes that race; common-case starts pay zero.
        let categoryWasChanged = try configureSession()
        try ensureEngineRunning()
        if categoryWasChanged {
            Diag.log("AudioEngine.start settling 120ms after category flip")
            try? await Task.sleep(nanoseconds: 120_000_000)
        }
        // Same problem with a different trigger: an
        // `AVAudioSession.routeChangeNotification` (BT device
        // connect/disconnect, override) that fired in the last ~300 ms
        // leaves the input AU mid-reinit too. The route observer's
        // tap-rebuild branch only acts when `engineRunning` is already
        // true; during start it isn't yet, so the observer no-ops and
        // we'd otherwise read stale formats unguarded. Settle for
        // 200 ms after a recent route flip — long enough for HFP/A2DP
        // negotiation to land — then re-resolve the format.
        if Date().timeIntervalSince(lastRouteChangeAt) < 0.3 {
            Diag.log("AudioEngine.start settling 200ms after recent route change")
            try? await Task.sleep(nanoseconds: 200_000_000)
        }

        let input = engine.inputNode
        var inputFormat = resolvedInputFormat(for: input)
        // Final stability check right before the tap install: if the
        // session rate disagrees with the format we just resolved,
        // the underlying AU is still moving. Settle once more and
        // re-resolve. This is cheap, catches the residue of a
        // mid-start route flip, and bounds total added latency to
        // ~300 ms in the worst case.
        let liveSessionRate = AVAudioSession.sharedInstance().sampleRate
        if liveSessionRate > 0,
           abs(liveSessionRate - inputFormat.sampleRate) > 1 {
            Diag.log(
                "AudioEngine.start formats disagree pre-install "
                + "inputFormat=\(Int(inputFormat.sampleRate)) "
                + "sessionRate=\(Int(liveSessionRate)) — retry"
            )
            try? await Task.sleep(nanoseconds: 100_000_000)
            inputFormat = resolvedInputFormat(for: input)
        }
        let session = AVAudioSession.sharedInstance()
        Diag.log(
            "AudioEngine.start inputFormat=\(Int(inputFormat.sampleRate))Hz "
            + "channels=\(inputFormat.channelCount) "
            + "sessionRate=\(Int(session.sampleRate))Hz "
            + "sessionCategory=\(session.category.rawValue) "
            + "sessionMode=\(session.mode.rawValue) "
            + "engineRunning=\(engine.isRunning)"
        )
        // Pick an encoder-safe rate for the writer. AAC-LC reliably
        // initialises at ≥ 44.1 kHz; below that the encoder errors
        // out. Anything ≥ 44.1 kHz passes through verbatim; lower-rate
        // HFP narrowband / wideband gets clamped to 48 kHz and
        // resampled by the cached upsampler inside the callback. The
        // writer rate stays stable for the whole recording; live
        // buffer-rate drift (mid-stream route flip) triggers a cache
        // rebuild rather than a tap-install crash.
        let writerRate: Double = inputFormat.sampleRate >= 44_100
            ? inputFormat.sampleRate
            : 48_000
        try writer.open(at: outputURL, inputSampleRate: writerRate)
        streamingSink = streaming

        // Lazy converter cache keyed on the *live* `buffer.format`.
        // Built up-front with the install-time format so the cache is
        // warm by the first callback (no rebuild on the first buffer),
        // but still adapts if a subsequent route flip changes the
        // buffer format.
        let converters = TapConverterCache(writerRate: writerRate)
        _ = converters.state(for: inputFormat)
        let wakeRef = wakeWordSink

        // Replace whatever tap was on the input node — there might be
        // a no-op tap left over from `ensureEngineRunning`, or a writer
        // tap from a previous segment that wasn't cleanly stopped.
        input.removeTap(onBus: 0)
        // Install with the explicit input format. `format: nil` was
        // tried as a defence against category-change AU re-init races
        // but turned out to silently break buffer delivery on
        // `AVAudioInputNode` — the tap installs, callbacks never fire,
        // lull / wake-word / file write all silently no-op. The
        // category-change race is addressed by `resolvedInputFormat`'s
        // session-rate override + the route observer's between-segment
        // tap rebuild instead.
        input.installTap(
            onBus: 0,
            bufferSize: 4096,
            format: inputFormat
        ) { [writer, streamingSink, wakeRef, converters] buffer, _ in
            // CoreAudio occasionally emits zero-frame buffers around tap
            // install / engine state transitions. Skipping them silences
            // the `mBuffers[0].mDataByteSize (0) should be non-zero`
            // warnings without losing real audio.
            guard buffer.frameLength > 0 else { return }
            let inputFormat = buffer.format
            let state = converters.state(for: inputFormat)

            // 1. File: write the buffer at the writer's rate. If the
            //    input came in below 44.1 kHz (or the writer rate
            //    otherwise differs from `inputFormat`), the cached
            //    upsampler converts each tap buffer to the writer's
            //    processing format first.
            do {
                let writeBuffer: AVAudioPCMBuffer
                if let upsampler = state.writerUpsampler, let wf = state.writerFormat {
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
            guard let downsampler = state.downsampler else { return }
            let parakeetFormat = state.parakeetFormat
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
        // Record the timestamp so `start()` can settle if a route flip
        // just landed. The flag is set regardless of `engineRunning` /
        // `capturing` — even when the observer's tap-rebuild branch
        // declines to act (because we're between segments OR mid-start)
        // the AU is still re-initialising under us and the next
        // installTap needs to wait for the format to settle.
        lastRouteChangeAt = Date()
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

    // MARK: - Interruption handling -------------------------------------
    //
    // AVAudioSession interruptions (phone calls, Siri, alarms) silently
    // stop CoreAudio's IO loop. Without an observer the tap stops
    // firing, the in-progress temp file never gets its moov atom, and
    // the engine appears "running" but is deaf. We mirror the route-
    // change observer pattern: unpack Sendable integers in the
    // notification context, re-enter the actor for state mutations.
    //
    // On `.began`: finalise the open writer via the same code path as
    // `stop()` — removes the tap, drops the AVAudioFile ref (writes
    // moov), reinstalls the no-op tap so the AU can be restarted later.
    // We record `captureWasInterrupted` so the `.ended` handler knows
    // whether to re-open a chunk.
    //
    // On `.ended`: if `shouldResume` is set we re-activate the session
    // and reinstall the no-op tap. We do NOT automatically re-open a
    // writer chunk: the coordinator/UI owns session state and must
    // decide whether to continue the recording or present an "interrupted"
    // notice. `captureWasInterrupted` is left `true` so callers can
    // inspect `wasInterrupted` to surface that notice.
    //
    // We intentionally do NOT call `engine.stop()` / `engine.start()`
    // here for the same reason as the route-change handler: iOS blocks
    // `engine.start()` from a backgrounded process and an interruption
    // can fire while we're backgrounded.

    private func handleInterruption(typeRaw: UInt?, optionsRaw: UInt?) async {
        guard let typeRaw,
              let interruptType = AVAudioSession.InterruptionType(rawValue: typeRaw)
        else { return }

        Diag.log(
            "AudioEngine interruption type=\(typeRaw) "
            + "engineRunning=\(engineRunning) capturing=\(capturing)"
        )

        switch interruptType {
        case .began:
            // Finalise the open writer so the chunk on disk is durable.
            // This mirrors the tap-removal + close logic in `stop()` but
            // does NOT await any engine.stop() — the AU is already
            // stopped by the system. We just drop the writer ref so the
            // moov atom lands synchronously here.
            if capturing {
                engine.inputNode.removeTap(onBus: 0)
                try? writer.close()
                streamingSink = nil
                capturing = false
                captureWasInterrupted = true
                // Keep the no-op tap install deferred until `.ended` /
                // next `prepareSession()` to avoid touching the AU
                // while iOS may still be tearing it down.
                Diag.log("AudioEngine interruption.began — writer closed, captureWasInterrupted=true")
            }

        case .ended:
            let options = optionsRaw.map {
                AVAudioSession.InterruptionOptions(rawValue: $0)
            } ?? []
            let shouldResume = options.contains(.shouldResume)
            Diag.log(
                "AudioEngine interruption.ended shouldResume=\(shouldResume) "
                + "captureWasInterrupted=\(captureWasInterrupted)"
            )
            guard shouldResume else { return }
            // Re-activate the session. This is the only call safe to
            // make here; `engine.start()` remains blocked from
            // background (the lock-screen comment in the file header
            // still applies). The no-op tap install below covers the
            // foreground case: once the user brings the app forward,
            // `prepareSession()` → `ensureEngineRunning()` will pick
            // up the already-running session without a cold start.
            do {
                try AVAudioSession.sharedInstance().setActive(true, options: [])
            } catch {
                Diag.log("AudioEngine interruption.ended setActive failed: \(error)")
                return
            }
            // If the engine is still running (it was kept alive by the
            // background-keep-alive design), reinstall the no-op tap so
            // the AU stays pumped until the coordinator opens a new
            // segment or tears down.
            if engineRunning {
                installNoOpTap()
            }

        @unknown default:
            break
        }
    }

    /// True when the previous capture was cut short by a system interruption
    /// (phone call, Siri, alarm). The coordinator / UI can read this to
    /// decide whether to surface a "recording was interrupted" notice.
    /// Cleared by `start()` when a new capture begins.
    public var wasInterrupted: Bool { captureWasInterrupted }

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
        // after the atomic `get()`. Converters are built lazily by the
        // cache keyed on `buffer.format`. Writer rate is irrelevant
        // here (no writer) so we hand the cache a dummy rate that
        // matches whatever input we see — the writer-upsampler branch
        // of the cache is never touched in this path.
        let converters = TapConverterCache(writerRate: 0)
        _ = converters.state(for: inputFormat)
        let wakeRef = wakeWordSink

        // Explicit format mirrors `start(outputURL:)` — `format: nil`
        // silently breaks buffer delivery on AVAudioInputNode.
        node.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [wakeRef, converters] buffer, _ in
            guard buffer.frameLength > 0 else { return }
            // No wake sink → keep the AU hot, drop frames on the floor.
            guard let sink = wakeRef.get() else { return }
            let liveFormat = buffer.format
            let state = converters.state(for: liveFormat)
            guard let downsampler = state.downsampler else { return }
            let parakeetFormat = state.parakeetFormat
            let frameCapacity = AVAudioFrameCount(
                Double(buffer.frameLength) * parakeetFormat.sampleRate / liveFormat.sampleRate
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

    /// Returns true when this call actually flipped the session
    /// category from a different mode into `.playAndRecord`. Callers
    /// (start) use that signal to add a brief settle delay before
    /// installing a tap — the kernel-mode input AU reinitialises
    /// after a category change, and a tap installed before that
    /// reinit completes crashes with `Failed to create tap due to
    /// format mismatch` (uncatchable NSException).
    @discardableResult
    private func configureSession() throws -> Bool {
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
        var didChangeCategory = false
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
                didChangeCategory = true
            }
            try session.setActive(true, options: [])
        } catch {
            throw EngineError.sessionConfigFailed("\(error)")
        }
        return didChangeCategory
    }
}
