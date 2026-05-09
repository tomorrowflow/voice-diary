import AVFoundation
import Foundation
import Synchronization

// Piper-via-sherpa-onnx TTS engine for the M9 voice options. Conforms to
// the same `TTSEngine` protocol as `AppleSpeechTTS`, so swapping engines
// is a `VoiceRegistry.engine(for:)` change.
//
// Currently bundled (one VITS .onnx per voice, ~110 MB each):
//   • de  → de_DE-thorsten-high   (Resources/Models/Voices/de_DE-thorsten-high/)
//   • en  → en_US-lessac-high     (American English)
//   • en  → en_GB-cori-high       (British English)
//
// All voices share `Resources/Models/Voices/espeak-ng-data/` for the
// phonemizer (kept once, ~30 MB, instead of duplicated per voice).
//
// The full implementation is gated by the `PIPER_TTS` compilation flag.
// That flag is set only by the sidecar `project-piper.yml` that
// `scripts/fetch_piper_voices.sh` writes — so a fresh checkout still
// builds, with `PiperTTS.assets()` returning nil and `speak()` becoming a
// no-op. The settings UI surfaces "Modelle nicht installiert" in that
// state.

public final class PiperTTS: NSObject, TTSEngine, @unchecked Sendable {
    public static let shared = PiperTTS()

    public override init() {
        super.init()
    }

    public struct VoiceAssets: Sendable {
        public let stem: String           // e.g. "de_DE-thorsten-high"
        public let model: URL             // .onnx
        public let tokens: URL            // tokens.txt
        public let espeakData: URL        // shared espeak-ng-data dir
    }

    /// One bundled VITS voice. `language` is the broad routing bucket
    /// (de / en) — the walkthrough requests an engine by language and
    /// `selectedStem(for:)` resolves which actual voice to use. `label`
    /// + `accent` drive the picker UI.
    public struct PiperVoice: Sendable, Hashable {
        public let stem: String
        public let language: String       // "de" or "en"
        public let label: String          // display name, e.g. "Thorsten"
        public let accent: String         // localised tag, e.g. "Deutsch", "American", "British"
        public let sample: String         // preview line in the voice's language
        public let voiceIDPrefix = "piper:"
        public var voiceID: String { voiceIDPrefix + stem }
    }

    /// Registered Piper voices in display order. Adding a new voice
    /// requires a matching entry in `scripts/fetch_piper_voices.sh`
    /// (download) and a matching subdir under `Resources/Models/Voices/`.
    public static let voices: [PiperVoice] = [
        PiperVoice(
            stem: "de_DE-thorsten-high",
            language: "de",
            label: "Thorsten",
            accent: "Deutsch · neuronal, lokal",
            sample: "Hallo, ich bin Thorsten, deine deutsche Piper-Stimme."
        ),
        PiperVoice(
            stem: "en_US-lessac-high",
            language: "en",
            label: "Lessac",
            accent: "American · neuronal, lokal",
            sample: "Hello, I'm Lessac, your American English Piper voice."
        ),
        PiperVoice(
            stem: "en_GB-cori-high",
            language: "en",
            label: "Cori",
            accent: "British · neuronal, lokal",
            sample: "Hello, I'm Cori, your British English Piper voice."
        ),
    ]

    public static func voices(for language: String) -> [PiperVoice] {
        let lang = String(language.prefix(2))
        return voices.filter { $0.language == lang }
    }

    public static func voice(stem: String) -> PiperVoice? {
        voices.first { $0.stem == stem }
    }

    public static func defaultStem(for language: String) -> String? {
        voices(for: language).first?.stem
    }

    fileprivate static func milliseconds(since start: Date) -> Int {
        Int(Date().timeIntervalSince(start) * 1000)
    }

    /// Look up bundled assets by stem. Returns nil when the bootstrap
    /// script hasn't run, the stem is unknown, or the `PIPER_TTS` flag
    /// is off.
    ///
    /// `Resources/Models` is added to project.yml as `type: folder`, so
    /// the whole subtree lands inside the .app at `Models/Voices/...`
    /// (the `Models` folder name is preserved by the folder reference).
    /// `Bundle.main.url(forResource:withExtension:subdirectory:)` looks
    /// inside `<App.app>/<subdirectory>/`, so the `Models/` prefix is
    /// required — without it the lookup silently returns nil.
    public static func assets(forStem stem: String) -> VoiceAssets? {
        #if PIPER_TTS
        let bundle = Bundle.main
        let voiceDir = "Models/Voices/\(stem)"
        guard
            let model = bundle.url(forResource: stem, withExtension: "onnx", subdirectory: voiceDir),
            let tokens = bundle.url(forResource: "tokens", withExtension: "txt", subdirectory: voiceDir),
            let espeak = bundle.url(forResource: "espeak-ng-data", withExtension: nil, subdirectory: "Models/Voices")
        else { return nil }
        return VoiceAssets(stem: stem, model: model, tokens: tokens, espeakData: espeak)
        #else
        _ = stem
        return nil
        #endif
    }

    /// Convenience: assets for whichever voice is currently selected for
    /// the given language. Falls back to the first registered voice for
    /// that language when the user has not picked one yet (or has picked
    /// an Apple voice).
    public static func assets(for language: String) -> VoiceAssets? {
        let stem = VoicePreferences.selectedPiperStem(for: language)
            ?? defaultStem(for: language)
        guard let stem else { return nil }
        return assets(forStem: stem)
    }

    public func cancel() async {
        #if PIPER_TTS
        // Drop any queued speak() chain so callers waiting in line don't
        // start their (cancelled) work after we've stopped the in-flight
        // player. Each chained Task checks `Task.isCancelled` at entry
        // and bails before synthesizing or playing.
        let queued = serialQueue.withLock { state -> Task<Void, Never>? in
            let t = state
            state = nil
            return t
        }
        queued?.cancel()

        let toResume = players.withLock { state -> [PendingPlayback] in
            let vals = Array(state.values)
            state.removeAll()
            return vals
        }
        for pending in toResume {
            pending.player.stop()
            pending.cont.resume()
        }
        #endif
    }

    public func speak(_ text: String, language: String = "de") async {
        await speak(text, stem: nil, language: language)
    }

    /// Speak with an explicit voice stem. The settings preview path uses
    /// this so a Vorhören tap demonstrates the *picker* row's voice
    /// regardless of what the user has currently saved.
    ///
    /// Concurrent callers are **serialized**: each new call chains onto
    /// the previous Task's completion. `AVSpeechSynthesizer` does this
    /// for free (it has a built-in queue), but each PiperTTS call would
    /// otherwise spin up its own `AVAudioPlayer` and produce overlapping
    /// audio — the exact bug the user saw during todo confirmation when
    /// the voice-driven `runTodoAnswerCapture` and a manual UI tap both
    /// dispatched `confirmCurrentTodo()` at the same time.
    public func speak(_ text: String, stem explicitStem: String?, language: String = "de") async {
        #if PIPER_TTS
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let stem = explicitStem
            ?? VoicePreferences.selectedPiperStem(for: language)
            ?? Self.defaultStem(for: language)
        guard let stem else {
            Log.app.error("PiperTTS: no voice registered for language=\(language, privacy: .public)")
            return
        }

        // Hand the actual work to the serial queue: each call chains
        // onto the previous Task so two callers can't run their players
        // concurrently. cancel() can drop the whole queue at once.
        let myTask: Task<Void, Never> = serialQueue.withLock { state in
            let previous = state
            let new = Task { [weak self] in
                _ = await previous?.value
                if Task.isCancelled { return }
                guard let self else { return }
                await self.performSpeak(text: trimmed, stem: stem)
            }
            state = new
            return new
        }
        // Forward the *caller's* cancellation into our unstructured
        // inner Task. Without this, a parent like the walkthrough's
        // `followUpTask` could be cancelled (because the user resumed
        // speaking before the AI finished preparing) and we'd still
        // play audio anyway — `Task { … }` doesn't inherit cancellation
        // from its creator. `withTaskCancellationHandler.onCancel`
        // fires the moment the calling Task is cancelled and forwards
        // it to `myTask`, whose `Task.isCancelled` check between synth
        // and play then bails before the AVAudioPlayer starts. Audio
        // that's already playing audibly is left intact (play() awaits
        // the player's continuation, which doesn't react to `isCancelled`).
        await withTaskCancellationHandler {
            await myTask.value
        } onCancel: {
            myTask.cancel()
        }
        #else
        _ = text
        _ = explicitStem
        _ = language
        Log.app.notice("PiperTTS: PIPER_TTS flag not set; run ios/scripts/fetch_piper_voices.sh and regenerate the project")
        #endif
    }

    #if PIPER_TTS
    /// One slot deep "previous Task" reference used to chain speak()
    /// calls into a serial queue. `Mutex` is fine here because the only
    /// thing inside the lock is a cheap pointer swap; the await happens
    /// outside.
    private let serialQueue = Mutex<Task<Void, Never>?>(nil)

    /// The actual synthesize+play body, called only via `serialQueue`
    /// chaining so two of these can never overlap.
    private func performSpeak(text: String, stem: String) async {
        let synthStart = Date()
        guard let url = await synthesize(text: text, stem: stem) else {
            Log.app.error("PiperTTS: synthesis failed for stem=\(stem, privacy: .public)")
            return
        }
        let synthMs = Self.milliseconds(since: synthStart)

        if Task.isCancelled {
            try? FileManager.default.removeItem(at: url)
            return
        }

        let playStart = Date()
        await play(url: url)
        let playMs = Self.milliseconds(since: playStart)

        // Synth ms is the on-device VITS inference cost — that's the
        // fair comparison against AppleSpeechTTS's "speak() returns when
        // playback ends" wall time. Play ms is just AVAudioPlayer wall
        // time (≈ utterance duration).
        Log.app.notice(
            "PiperTTS speak stem=\(stem, privacy: .public) chars=\(text.count, privacy: .public) synth=\(synthMs, privacy: .public)ms play=\(playMs, privacy: .public)ms total=\(synthMs + playMs, privacy: .public)ms"
        )
    }
    #endif

    // MARK: - PIPER_TTS-only members

    #if PIPER_TTS
    private struct PendingPlayback: @unchecked Sendable {
        let player: AVAudioPlayer
        let cont: CheckedContinuation<Void, Never>
    }

    /// `SherpaOnnxOfflineTtsWrapper` is a vanilla Swift class — synthesizing a
    /// Sendable conformance via an unchecked extension is the lightest path
    /// for stuffing it into a `Mutex<[String: …]>` under strict concurrency.
    /// Access is always serialized through the Mutex, so the unchecked
    /// promise holds.
    private struct EngineBox: @unchecked Sendable {
        let wrapper: SherpaOnnxOfflineTtsWrapper
    }

    private let players = Mutex<[ObjectIdentifier: PendingPlayback]>([:])
    /// Engines are cached per *stem*, not per language — so picking a
    /// different voice for the same language doesn't reuse the wrong
    /// VITS model. Each cached wrapper retains its 110 MB .onnx in
    /// memory; switching voices on a memory-tight device may want to
    /// drop the previous entry, but for an iPhone 17 Pro that's far
    /// from the limiting factor.
    private let engines = Mutex<[String: EngineBox]>([:])

    private func synthesize(text: String, stem: String) async -> URL? {
        return await Task.detached(priority: .userInitiated) { [weak self] () -> URL? in
            guard let self else { return nil }
            return self.synthesizeSync(text: text, stem: stem)
        }.value
    }

    private func synthesizeSync(text: String, stem: String) -> URL? {
        guard let assets = Self.assets(forStem: stem) else {
            Log.app.error("PiperTTS: no bundled voice for stem=\(stem, privacy: .public)")
            return nil
        }

        // The first synthesis per stem pays the model-load cost (~hundreds
        // of ms for a 110 MB VITS file). Log it separately so the per-call
        // timings in `speak()` aren't skewed on cold start.
        let wrapper: SherpaOnnxOfflineTtsWrapper
        if let cached = engines.withLock({ $0[stem] }) {
            wrapper = cached.wrapper
        } else {
            let loadStart = Date()
            let vits = sherpaOnnxOfflineTtsVitsModelConfig(
                model: assets.model.path,
                lexicon: "",
                tokens: assets.tokens.path,
                dataDir: assets.espeakData.path
            )
            let modelConfig = sherpaOnnxOfflineTtsModelConfig(vits: vits)
            var ttsConfig = sherpaOnnxOfflineTtsConfig(model: modelConfig)
            wrapper = SherpaOnnxOfflineTtsWrapper(config: &ttsConfig)
            let box = EngineBox(wrapper: wrapper)
            engines.withLock { $0[stem] = box }
            Log.app.notice(
                "PiperTTS load stem=\(stem, privacy: .public) load=\(Self.milliseconds(since: loadStart), privacy: .public)ms (cold start)"
            )
        }

        var genConfig = SherpaOnnxGenerationConfigSwift()
        genConfig.sid = 0
        genConfig.speed = 1.0

        let audio = wrapper.generateWithConfig(text: text, config: genConfig, callback: nil, arg: nil)

        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("piper-\(stem)-\(UUID().uuidString.prefix(8)).wav")
        let ok = audio.save(filename: outURL.path)
        guard ok == 1 else {
            Log.app.error("PiperTTS: WAV write failed at \(outURL.path, privacy: .public)")
            return nil
        }
        return outURL
    }

    private func play(url: URL) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            do {
                let player = try AVAudioPlayer(contentsOf: url)
                player.delegate = PlaybackDelegate.shared
                player.volume = 1.0
                let key = ObjectIdentifier(player)
                players.withLock { $0[key] = PendingPlayback(player: player, cont: cont) }
                PlaybackDelegate.shared.register(player: player) { [weak self] in
                    guard let self else { return }
                    let pending = self.players.withLock { $0.removeValue(forKey: key) }
                    pending?.cont.resume()
                }
                player.prepareToPlay()
                guard player.play() else {
                    let pending = players.withLock { $0.removeValue(forKey: key) }
                    pending?.cont.resume()
                    return
                }
            } catch {
                Log.app.error("PiperTTS: AVAudioPlayer init failed: \(error.localizedDescription, privacy: .public)")
                cont.resume()
            }
        }
        try? FileManager.default.removeItem(at: url)
    }

    /// Pre-synthesise a future utterance. Runs the SherpaOnnx VITS
    /// pass now and stashes the resulting WAV URL in the returned
    /// handle, so a later `play(_:)` only pays AVAudioPlayer startup
    /// cost (~tens of ms) instead of a fresh synth (~400–800 ms for a
    /// typical opener line). The walkthrough kicks this off after
    /// each event's listening phase begins so the next opener is
    /// ready by the time the user taps "Weiter".
    public func prefetch(_ text: String, language: String) async -> PrefetchedUtterance {
        #if PIPER_TTS
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return PrefetchedUtterance(text: text, language: language, engineKind: .apple, audioURL: nil)
        }
        let stem = VoicePreferences.selectedPiperStem(for: language)
            ?? Self.defaultStem(for: language)
        guard let stem else {
            // No Piper voice for this language — fall back to the
            // protocol default so play(_:) routes through Apple.
            return PrefetchedUtterance(text: text, language: language, engineKind: .apple, audioURL: nil)
        }
        let synthStart = Date()
        let url = await synthesize(text: trimmed, stem: stem)
        let synthMs = Self.milliseconds(since: synthStart)
        guard let url else {
            Log.app.warning("PiperTTS prefetch synth failed for stem=\(stem, privacy: .public)")
            return PrefetchedUtterance(text: text, language: language, engineKind: .apple, audioURL: nil)
        }
        Log.app.notice(
            "PiperTTS prefetch stem=\(stem, privacy: .public) chars=\(trimmed.count, privacy: .public) synth=\(synthMs, privacy: .public)ms"
        )
        return PrefetchedUtterance(
            text: trimmed,
            language: language,
            engineKind: .piper(stem: stem),
            audioURL: url
        )
        #else
        return PrefetchedUtterance(text: text, language: language, engineKind: .apple, audioURL: nil)
        #endif
    }

    /// Play a previously prefetched utterance. Reuses the same serial
    /// queue as `speak(_:language:)` so a prefetched-play can't
    /// overlap with a concurrent fresh speak. If the handle's stem no
    /// longer matches the user's current Piper voice (they switched
    /// voices between prefetch and play), the cached WAV is stale —
    /// we discard it and fall back to a fresh synth.
    public func play(_ prefetched: PrefetchedUtterance) async {
        #if PIPER_TTS
        guard case .piper(let stem) = prefetched.engineKind,
              let url = prefetched.audioURL else {
            await speak(prefetched.text, language: prefetched.language)
            return
        }
        let currentStem = VoicePreferences.selectedPiperStem(for: prefetched.language)
            ?? Self.defaultStem(for: prefetched.language)
        guard currentStem == stem else {
            try? FileManager.default.removeItem(at: url)
            await speak(prefetched.text, language: prefetched.language)
            return
        }
        let myTask: Task<Void, Never> = serialQueue.withLock { state in
            let previous = state
            let new = Task { [weak self] in
                _ = await previous?.value
                if Task.isCancelled { return }
                guard let self else { return }
                let playStart = Date()
                await self.play(url: url)
                let playMs = Self.milliseconds(since: playStart)
                Log.app.notice(
                    "PiperTTS play (prefetched) stem=\(stem, privacy: .public) chars=\(prefetched.text.count, privacy: .public) play=\(playMs, privacy: .public)ms"
                )
            }
            state = new
            return new
        }
        await withTaskCancellationHandler {
            await myTask.value
        } onCancel: {
            myTask.cancel()
        }
        #else
        await speak(prefetched.text, language: prefetched.language)
        #endif
    }

    /// `AVAudioPlayer` keeps its delegate weakly, so the `PiperTTS` actor
    /// can't be the delegate without race risk. A small singleton holds
    /// per-player completion handlers and forwards them on the audio
    /// callbacks. Each handler fires exactly once.
    private final class PlaybackDelegate: NSObject, AVAudioPlayerDelegate, @unchecked Sendable {
        static let shared = PlaybackDelegate()
        private struct HandlerBox: @unchecked Sendable {
            let run: () -> Void
        }
        private let handlers = Mutex<[ObjectIdentifier: HandlerBox]>([:])

        func register(player: AVAudioPlayer, completion: @escaping () -> Void) {
            let box = HandlerBox(run: completion)
            handlers.withLock { $0[ObjectIdentifier(player)] = box }
        }

        func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully _: Bool) {
            let key = ObjectIdentifier(player)
            let box = handlers.withLock { $0.removeValue(forKey: key) }
            box?.run()
        }

        func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
            Log.app.error("PiperTTS: decode error \(error?.localizedDescription ?? "?", privacy: .public)")
            let key = ObjectIdentifier(player)
            let box = handlers.withLock { $0.removeValue(forKey: key) }
            box?.run()
        }
    }
    #endif
}
