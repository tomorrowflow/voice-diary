import AVFoundation
import FluidAudio
import Foundation
import Speech

// Streaming on-device speech recognition for the wake-word path.
// Two implementations behind a single protocol so the coordinator only
// has to know the language — not which engine speaks it:
//
//   • English  → `FluidAudioStreaming` wraps FluidAudio's
//                `StreamingEouAsrManager` (the 120 M `parakeet-realtime-eou`
//                CoreML model on the ANE, ~160–320 ms partial latency).
//   • German   → `AppleStreamingRecognizer` wraps `SFSpeechRecognizer(locale: de_DE)`
//                with `requiresOnDeviceRecognition = true`. NVIDIA's streaming
//                model is English-only; Apple's streamer is the cleanest
//                native German path.
//
// Both backends consume the same `AVAudioPCMBuffer`s the existing
// `AudioEngine` tap is already producing (16 kHz mono Float32 from the
// downsample stage). They surface partial transcripts via the same
// callback signature so a single `WakeWordDetector` can sit on top of
// either one without caring which engine is alive.
//
// Lifecycle: `start(language:)` → `append(buffer:)` for each PCM chunk
// → `stop()` to tear down. Calling `start` while one is already running
// auto-cancels the previous session.

public protocol StreamingASR: Actor {
    /// Open a streaming session for the given language. The window
    /// stays open until `stop()` is called (typically the wake-word
    /// timeout) or the implementation hits an internal end-of-utterance.
    /// Calling `start` while a session is already live cancels the old one.
    func start(language: String, onPartial: @escaping @Sendable (String) -> Void) async throws

    /// Hand a PCM buffer to the recogniser. The `sending` qualifier
    /// transfers ownership of the (non-`Sendable`) `AVAudioPCMBuffer`
    /// across the actor boundary — Swift 6 strict concurrency rejects
    /// the call otherwise. Safe to invoke regardless of state; buffers
    /// received before `start` are discarded internally.
    func append(buffer: sending AVAudioPCMBuffer) async

    /// Tear the session down. Idempotent.
    func stop() async
}

// MARK: - English: FluidAudio streaming Parakeet (120 M EOU)

public actor FluidAudioStreaming: StreamingASR {
    private var manager: StreamingEouAsrManager?
    private var modelsLoaded = false

    public init() {}

    public func start(language _: String, onPartial: @escaping @Sendable (String) -> Void) async throws {
        await stop()
        // chunkSize: .ms320 trades the lowest possible latency for
        // ~half the WER of the 160 ms variant — wake-word matching on
        // a 1–2 word phrase doesn't need 160 ms reaction time, but we
        // do want stable hypotheses so the Levenshtein matcher in
        // `WakeWordDetector` doesn't bounce.
        let m = StreamingEouAsrManager(chunkSize: .ms320, eouDebounceMs: 800)
        if !modelsLoaded {
            try await m.loadModels()
            modelsLoaded = true
        }
        await m.setPartialCallback { partial in onPartial(partial) }
        // We don't act on EOU specifically — the wake-word window has
        // its own timeout and the matcher reacts to partials. The
        // callback is set to a no-op to keep the API symmetric.
        await m.setEouCallback { _ in }
        manager = m
    }

    public func append(buffer: sending AVAudioPCMBuffer) async {
        guard let manager else { return }
        do { try await manager.appendAudio(buffer) }
        catch { Log.audio.warning("FluidAudioStreaming append: \(String(describing: error), privacy: .public)") }
    }

    public func stop() async {
        guard let m = manager else { return }
        manager = nil
        await m.cleanup()
    }
}

// MARK: - German: SFSpeechRecognizer

/// Wraps Apple's on-device speech recogniser. Requires a one-time
/// system permission (`NSSpeechRecognitionUsageDescription` in the
/// Info.plist) and `SFSpeechRecognizer.requestAuthorization`. Audio
/// stays on-device because we set `requiresOnDeviceRecognition = true`
/// — if the locale doesn't support on-device recognition we fail loud
/// rather than silently routing the user's audio to Apple's servers.
public actor AppleStreamingRecognizer: StreamingASR {
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var partialHandler: (@Sendable (String) -> Void)?

    public enum SFRError: Error, CustomStringConvertible {
        case authorizationDenied(SFSpeechRecognizerAuthorizationStatus)
        case recogniserUnavailable(locale: String)
        case onDeviceUnsupported(locale: String)

        public var description: String {
            switch self {
            case .authorizationDenied(let s): return "sfr_auth_denied:\(s.rawValue)"
            case .recogniserUnavailable(let l): return "sfr_unavailable:\(l)"
            case .onDeviceUnsupported(let l): return "sfr_no_on_device:\(l)"
            }
        }
    }

    public init() {}

    /// Capability probe — returns true iff Apple's on-device dictation
    /// asset for the requested language is installed and available.
    ///
    /// The asset ships separately from iOS itself; users must enable
    /// dictation in Settings → General → Keyboard, add the language,
    /// and let iOS download it (Wi-Fi + sometimes power required). Until
    /// it's present, `SFSpeechRecognizer.supportsOnDeviceRecognition`
    /// returns false and `start(language:)` will throw `.onDeviceUnsupported`.
    ///
    /// Callable from any actor — `SFSpeechRecognizer` init is lightweight.
    public static func supportsOnDeviceRecognition(language: String) -> Bool {
        let locale: Locale
        switch language.prefix(2).lowercased() {
        case "de": locale = Locale(identifier: "de-DE")
        case "en": locale = Locale(identifier: "en-US")
        default:   locale = Locale(identifier: "de-DE")
        }
        guard let r = SFSpeechRecognizer(locale: locale), r.isAvailable else {
            return false
        }
        return r.supportsOnDeviceRecognition
    }

    /// One-shot permission gate. Safe to call repeatedly — the system
    /// caches the answer after the first prompt. Throws on denial so
    /// callers can fall back gracefully.
    public static func requestAuthorization() async throws {
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            SFSpeechRecognizer.requestAuthorization { status in
                switch status {
                case .authorized: cont.resume(returning: ())
                default:          cont.resume(throwing: SFRError.authorizationDenied(status))
                }
            }
        }
    }

    public func start(language: String, onPartial: @escaping @Sendable (String) -> Void) async throws {
        await stop()

        // Map our short language code to the BCP-47 locale Apple wants.
        // Both DE and EN are accepted here so the abstraction stays
        // polymorphic — but in practice the coordinator only routes
        // `de` to this backend (English goes through FluidAudio).
        let locale: Locale
        switch language.prefix(2).lowercased() {
        case "de": locale = Locale(identifier: "de-DE")
        case "en": locale = Locale(identifier: "en-US")
        default:   locale = Locale(identifier: "de-DE")
        }
        guard let r = SFSpeechRecognizer(locale: locale), r.isAvailable else {
            Diag.log("AppleSFR start: recogniser unavailable for \(locale.identifier)")
            throw SFRError.recogniserUnavailable(locale: locale.identifier)
        }
        guard r.supportsOnDeviceRecognition else {
            Diag.log("AppleSFR start: on-device unsupported for \(locale.identifier)")
            // Refuse to fall through to Apple's servers — that would
            // ship the user's diary audio off-device, which violates
            // the project's "no telemetry, ever" rule from CLAUDE.md.
            throw SFRError.onDeviceUnsupported(locale: locale.identifier)
        }

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.requiresOnDeviceRecognition = true
        // Bias the recogniser toward our wake-word vocabulary so short
        // utterances are more likely to land on the right token. Bigger
        // boost than a single contextual string would give.
        req.contextualStrings = ["weiter", "nächstes", "fertig", "next", "continue", "done"]

        recognizer = r
        request = req
        partialHandler = onPartial

        // The recognitionTask closure is a `sending` parameter under
        // Swift 6 strict concurrency. We therefore capture only
        // locally-bound Sendable values (`onPartial` is already
        // `@Sendable`) — no `[weak self]`, no actor-state reads. The
        // coordinator's explicit `stop()` call when the listen window
        // closes is the sole cleanup path; per-partial / end-of-stream
        // logging is intentionally absent (firehose-y, low signal).
        task = r.recognitionTask(with: req) { result, _ in
            if let result {
                onPartial(result.bestTranscription.formattedString)
            }
        }
    }

    public func append(buffer: sending AVAudioPCMBuffer) async {
        request?.append(buffer)
    }

    public func stop() async {
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil
        recognizer = nil
        partialHandler = nil
    }
}
