import AVFoundation
import Foundation

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
    private var pending: [ObjectIdentifier: CheckedContinuation<Void, Never>] = [:]
    private let lock = NSLock()

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
            lock.lock()
            pending[key] = cont
            lock.unlock()
            synth.speak(utterance)
        }
    }

    public func cancel() async {
        // Snapshot any in-flight continuations and resolve them before
        // stopping the synth. The delegate's `didCancel` will still fire
        // for the live utterance, but its key is already gone from the
        // map so it's a no-op (no race with a queued next utterance).
        lock.lock()
        let toResume = Array(pending.values)
        pending.removeAll()
        lock.unlock()

        if synth.isSpeaking {
            synth.stopSpeaking(at: .immediate)
        }
        for cont in toResume { cont.resume() }
    }

    private func resume(_ utterance: AVSpeechUtterance) {
        let key = ObjectIdentifier(utterance)
        lock.lock()
        let cont = pending.removeValue(forKey: key)
        lock.unlock()
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

    private static func voice(for language: String) -> AVSpeechSynthesisVoice? {
        let primary = language.contains("-") ? language : (language == "de" ? "de-DE" : "en-US")
        if let v = AVSpeechSynthesisVoice(language: primary) {
            return v
        }
        let prefix = String(language.prefix(2))
        return AVSpeechSynthesisVoice.speechVoices()
            .first { $0.language.hasPrefix(prefix) }
    }
}
