import Foundation

// Handle for an utterance whose synth has been queued ahead of time.
// Returned by `TTSEngine.prefetch(_:language:)`; played by
// `TTSEngine.play(_:)`. The walkthrough uses this to synthesise the
// next opener while the user is still talking through the current
// event, so the perceived gap between "Weiter" and the next opener is
// just AVAudioPlayer startup, not Piper's ~400–800 ms VITS pass.
//
// `engineKind` lets `play(_:)` detect a stale handle (user switched
// voice between prefetch and play) and fall back to a fresh `speak()`
// instead of playing audio synthesised for a different voice.
//
// `audioURL` is engine-specific:
//   • Apple → nil. AVSpeechSynthesizer doesn't expose pre-synth, so
//     prefetch is a thin record-keeping wrapper and play is just a
//     fresh speak() call. Apple's synth cost is dominated by playback
//     time anyway, so the loss vs Piper is small.
//   • Piper → URL of the WAV file produced by SherpaOnnx. The file is
//     deleted by `play(_:)` after playback (or by `discard(_:)` if the
//     handle is dropped without playing).

public struct PrefetchedUtterance: Sendable {
    public let text: String
    public let language: String
    public let engineKind: EngineKind
    public let audioURL: URL?

    public enum EngineKind: Sendable, Equatable {
        case apple
        case piper(stem: String)
    }

    public init(
        text: String,
        language: String,
        engineKind: EngineKind,
        audioURL: URL?
    ) {
        self.text = text
        self.language = language
        self.engineKind = engineKind
        self.audioURL = audioURL
    }

    /// True when there is real synth work cached on disk. Lets the
    /// coordinator skip the "use prefetched" fast path for handles
    /// that ended up with no synth (e.g. Apple, or a Piper synth that
    /// failed silently).
    public var hasCachedAudio: Bool { audioURL != nil }
}

// Multi-span script — used for openers where a German frame wraps an
// English meeting title. Each span keeps its own engine handle so the
// frame can play through Thorsten and the title through Lessac/Cori.
public struct PrefetchedScript: Sendable {
    public let segmentID: String
    public let utterances: [PrefetchedUtterance]

    public init(segmentID: String, utterances: [PrefetchedUtterance]) {
        self.segmentID = segmentID
        self.utterances = utterances
    }

    public var isEmpty: Bool { utterances.isEmpty }
}
