import AVFoundation
import Foundation
import Synchronization

// Server-mediated Voxtral TTS engine. Slice 01 scope: speak only — no
// prefetch, no fallback policy, no VoiceRegistry routing. The debug
// button in `DebugSettingsView` calls `speak(_:voice:language:)` with
// an explicit voice id; the protocol-conforming `speak(_:language:)`
// reads `VoicePreferences.selectedVoiceID(for:)` and strips the
// `voxtral:` prefix. When no preference is set, a small default voice
// id is used so the debug button works on a fresh install.
//
// Concurrent callers are serialized via a `Mutex<Task<Void, Never>?>`
// pattern mirrored from `PiperTTS`, so two taps on the debug button
// can't spin up overlapping `AVAudioPlayer` instances.

public final class VoxtralTTS: NSObject, TTSEngine, @unchecked Sendable {
    public static let shared = VoxtralTTS()

    /// Voice id used when nothing else is available. Real voice selection
    /// arrives in slice 02 via the server's `/api/tts/voices` catalog.
    public static let fallbackVoice = "casual_male"

    public static let voiceIDPrefix = "voxtral:"

    /// Server timeout from the iOS side. Server-side retries already
    /// happen inside `voxtral_client`, so this just bounds the iOS wait.
    public static let defaultTimeout: TimeInterval = 30

    private let client: VoxtralTTSClient
    private let serialQueue = Mutex<Task<Void, Never>?>(nil)
    private let players = Mutex<[ObjectIdentifier: PendingPlayback]>([:])

    public override init() {
        self.client = VoxtralTTSClient(timeout: Self.defaultTimeout)
        super.init()
    }

    public init(client: VoxtralTTSClient) {
        self.client = client
        super.init()
    }

    // MARK: - TTSEngine

    public func speak(_ text: String, language: String) async {
        let voice = Self.selectedVoice(for: language)
        await speak(text, voice: voice, language: language)
    }

    public func cancel() async {
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
    }

    // MARK: - Public extension

    /// Speak with an explicit voice id (no `voxtral:` prefix). Used by
    /// the debug button so a tap demonstrates a specific voice even
    /// before any settings UI exists.
    public func speak(_ text: String, voice: String, language: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let myTask: Task<Void, Never> = serialQueue.withLock { state in
            let previous = state
            let new = Task { [weak self] in
                _ = await previous?.value
                if Task.isCancelled { return }
                guard let self else { return }
                await self.performSpeak(text: trimmed, voice: voice, language: language)
            }
            state = new
            return new
        }
        await withTaskCancellationHandler {
            await myTask.value
        } onCancel: {
            myTask.cancel()
        }
    }

    /// Synthesize and play; re-throws any `VoxtralError` from the
    /// client so the debug surface can show it to the user. Production
    /// code uses the non-throwing `speak(...)` variants, which log and
    /// swallow because a walkthrough must never stall on a single TTS
    /// failure.
    public func speakOrThrow(text: String, voice: String, language: String) async throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let url = try await client.synthesize(
            VoxtralTTSClient.Request(text: trimmed, language: language, voice: voice)
        )
        // Reuse the same serialized playback path so the debug button
        // can't overlap with a concurrent `speak(...)` call.
        let myTask: Task<Void, Never> = serialQueue.withLock { state in
            let previous = state
            let new = Task { [weak self] in
                _ = await previous?.value
                guard let self else { return }
                await self.play(url: url)
            }
            state = new
            return new
        }
        await myTask.value
    }

    // MARK: - Internals

    private func performSpeak(text: String, voice: String, language: String) async {
        let start = Date()
        let url: URL
        do {
            url = try await client.synthesize(
                VoxtralTTSClient.Request(text: text, language: language, voice: voice)
            )
        } catch {
            Log.app.error(
                "VoxtralTTS synth failed voice=\(voice, privacy: .public) lang=\(language, privacy: .public) error=\(String(describing: error), privacy: .public)"
            )
            return
        }
        let synthMs = Int(Date().timeIntervalSince(start) * 1000)
        Log.app.notice(
            "VoxtralTTS synth ok voice=\(voice, privacy: .public) lang=\(language, privacy: .public) chars=\(text.count, privacy: .public) synth+net=\(synthMs, privacy: .public)ms"
        )

        await play(url: url)
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
                Log.app.error("VoxtralTTS: AVAudioPlayer init failed: \(error.localizedDescription, privacy: .public)")
                cont.resume()
            }
        }
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Voice selection

    /// Strip the `voxtral:` prefix from the user's selected voice id, or
    /// fall back to the default if no Voxtral voice is selected for this
    /// language. Used by the protocol-conforming `speak(_:language:)`.
    private static func selectedVoice(for language: String) -> String {
        if let id = VoicePreferences.selectedVoiceID(for: language),
           id.hasPrefix(voiceIDPrefix) {
            return String(id.dropFirst(voiceIDPrefix.count))
        }
        return fallbackVoice
    }

    // MARK: - Playback plumbing (mirrors PiperTTS, kept private so the
    // two engines don't share internal state)

    private struct PendingPlayback {
        let player: AVAudioPlayer
        let cont: CheckedContinuation<Void, Never>
    }

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
            Log.app.error("VoxtralTTS: decode error \(error?.localizedDescription ?? "?", privacy: .public)")
            let key = ObjectIdentifier(player)
            let box = handlers.withLock { $0.removeValue(forKey: key) }
            box?.run()
        }
    }
}
