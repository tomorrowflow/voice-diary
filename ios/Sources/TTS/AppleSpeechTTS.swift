import AVFoundation
import Foundation
import Synchronization

// `AVSpeechSynthesizer`-backed TTS. Built into iOS, no model bundling
// required. German + English voices are present out of the box.
//
// Continuation tracking is keyed by `ObjectIdentifier(utterance)` so that
// a *delayed* `didFinish` / `didCancel` callback for a previous utterance
// can NOT wake up the next one's continuation. Without this keying, rapid
// back-to-back `speak()` calls dropped every utterance after the first
// (M6 dogfood: opener spoke, follow-up cancelled it, the cancel's delegate
// then fired while the next opener was queued, and the next opener
// "completed" before AVSpeech ever played it). M5 baseline; M9 swaps in
// Piper via sherpa-onnx behind the same `TTSEngine` protocol.

public final class AppleSpeechTTS: NSObject, TTSEngine, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    public static let shared = AppleSpeechTTS()

    private let synth = AVSpeechSynthesizer()
    private let pending = Mutex<[ObjectIdentifier: CheckedContinuation<Void, Never>]>([:])

    public override init() {
        super.init()
        synth.delegate = self
    }

    public func speak(_ text: String, language: String = "de") async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let utterance = AVSpeechUtterance(string: trimmed)
        utterance.voice = Self.voice(for: language)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.95
        utterance.pitchMultiplier = 1.0
        utterance.preUtteranceDelay = 0.05
        utterance.postUtteranceDelay = 0.10

        let key = ObjectIdentifier(utterance)
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            pending.withLock { $0[key] = cont }
            synth.speak(utterance)
        }
    }

    public func cancel() async {
        // Snapshot any in-flight continuations and resolve them before
        // stopping the synth. The delegate's `didCancel` will still fire
        // for the live utterance, but its key is already gone from the
        // map so it's a no-op (no race with a queued next utterance).
        let toResume = pending.withLock { state -> [CheckedContinuation<Void, Never>] in
            let vals = Array(state.values)
            state.removeAll()
            return vals
        }

        if synth.isSpeaking {
            synth.stopSpeaking(at: .immediate)
        }
        for cont in toResume { cont.resume() }
    }

    private func resume(_ utterance: AVSpeechUtterance) {
        let key = ObjectIdentifier(utterance)
        let cont = pending.withLock { $0.removeValue(forKey: key) }
        cont?.resume()
    }

    // MARK: - AVSpeechSynthesizerDelegate

    nonisolated public func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didFinish utterance: AVSpeechUtterance
    ) {
        resume(utterance)
    }

    nonisolated public func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didCancel utterance: AVSpeechUtterance
    ) {
        resume(utterance)
    }

    // MARK: - Voice selection

    /// Prefer Premium > Enhanced > default. iOS's
    /// `AVSpeechSynthesisVoice(language:)` returns *some* voice for the
    /// locale but doesn't guarantee the highest-quality tier the user
    /// has installed — we have to enumerate `speechVoices()` and pick
    /// the best one ourselves. The user has to download Premium voices
    /// once via Settings → Accessibility → Spoken Content → Voices;
    /// this code makes them actually get used.
    private static func voice(for language: String) -> AVSpeechSynthesisVoice? {
        let target = language.contains("-")
            ? language
            : (language == "de" ? "de-DE" : "en-US")
        let prefix = String(language.prefix(2))

        let all = AVSpeechSynthesisVoice.speechVoices()
        let exact = all.filter { $0.language == target }
        let prefixed = all.filter { $0.language.hasPrefix(prefix) }

        // Quality buckets: 3 = premium, 2 = enhanced, 1 = default.
        // Newer iOS adds `.premium` directly; on older OSes we treat
        // the highest enum value as best.
        func score(_ v: AVSpeechSynthesisVoice) -> Int {
            switch v.quality {
            case .premium:  return 3
            case .enhanced: return 2
            default:        return 1
            }
        }

        // Best match: exact-locale Premium first; then any prefix Premium;
        // then exact Enhanced; then prefix Enhanced; then anything.
        let candidates = exact + prefixed.filter { !exact.contains($0) }
        if let best = candidates.max(by: { score($0) < score($1) }) {
            Log.app.debug(
                "TTS voice selected: \(best.identifier, privacy: .public) lang=\(best.language, privacy: .public) quality=\(best.quality.rawValue, privacy: .public)"
            )
            return best
        }
        return AVSpeechSynthesisVoice(language: target)
    }
}
