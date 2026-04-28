import AVFoundation
import Foundation

// `AVSpeechSynthesizer`-backed TTS. Built into iOS, no model bundling
// required. German + English voices are present out of the box.
//
// This is the M5 baseline. M9 (multilingual + voice quality) swaps in
// Piper via sherpa-onnx behind the same `TTSEngine` protocol.

public final class AppleSpeechTTS: NSObject, TTSEngine, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    public static let shared = AppleSpeechTTS()

    private let synth = AVSpeechSynthesizer()
    private var currentContinuation: CheckedContinuation<Void, Never>?
    private let queue = DispatchQueue(label: "com.tomorrowflow.voice-diary.tts")

    public override init() {
        super.init()
        synth.delegate = self
    }

    public func speak(_ text: String, language: String = "de") async {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        await cancel()
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            queue.sync { self.currentContinuation = cont }
            let utterance = AVSpeechUtterance(string: text)
            utterance.voice = Self.voice(for: language)
            utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.95
            utterance.pitchMultiplier = 1.0
            utterance.preUtteranceDelay = 0.05
            utterance.postUtteranceDelay = 0.10
            synth.speak(utterance)
        }
    }

    public func cancel() async {
        if synth.isSpeaking {
            synth.stopSpeaking(at: .immediate)
        }
        finish()
    }

    private func finish() {
        let cont: CheckedContinuation<Void, Never>? = queue.sync {
            let c = self.currentContinuation
            self.currentContinuation = nil
            return c
        }
        cont?.resume()
    }

    // MARK: - AVSpeechSynthesizerDelegate

    nonisolated public func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didFinish utterance: AVSpeechUtterance
    ) {
        finish()
    }

    nonisolated public func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didCancel utterance: AVSpeechUtterance
    ) {
        finish()
    }

    // MARK: - Voice selection

    private static func voice(for language: String) -> AVSpeechSynthesisVoice? {
        // Try the language exactly first ("de", "de-DE"), then a region
        // fallback. iOS maps "de" → "de-DE" automatically in most cases
        // but being explicit avoids surprises.
        let primary = language.contains("-") ? language : (language == "de" ? "de-DE" : "en-US")
        if let v = AVSpeechSynthesisVoice(language: primary) {
            return v
        }
        // Last-ditch fallback: pick any voice whose language code starts
        // with the requested prefix.
        let prefix = String(language.prefix(2))
        return AVSpeechSynthesisVoice.speechVoices()
            .first { $0.language.hasPrefix(prefix) }
    }
}
