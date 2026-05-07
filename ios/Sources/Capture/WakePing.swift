import AVFoundation
import Foundation

/// Short audible cues for the wake-word path. Two tones:
///
///   • `playListenOpen()` — single 120 ms 1.2 kHz "ding" when the
///     listen window opens.
///   • `playMatch()`      — ascending two-note pip when a wake word
///     is recognised, so the user has hands-off audible confirmation
///     that "weiter" / "fertig" was heard.
///
/// Why not `AudioServicesPlaySystemSound`? That API plays through
/// the system "alert" route which is suppressed (or routed to the
/// receiver in a way the user can't hear) while our `.playAndRecord`
/// session is hot. Piper TTS proves `AVAudioPlayer` *does* survive
/// that same session — so we mirror Piper's playback path here.
///
/// Both tones are synthesised at init (raised-cosine envelopes to
/// avoid clicks) and cached as in-memory WAV blobs. No bundled assets.
@MainActor
public final class WakePing {
    public static let shared = WakePing()

    private let listenOpenData: Data
    private let matchData: Data
    /// Strong reference so the player survives until playback ends.
    /// AVAudioPlayer doesn't retain itself; without this, ARC would
    /// drop the player mid-tone.
    private var player: AVAudioPlayer?

    private init() {
        // Listen-open: single mid-pitch "ding".
        self.listenOpenData = Self.synthesisedWAV(segments: [
            .init(frequency: 1_200, durationS: 0.12)
        ])
        // Match: ascending two-note "tu-tee" pip — easy to tell apart
        // from the listen-open ding both timbrally (two notes vs one)
        // and pitch-wise (peaks ~1.6 kHz vs 1.2 kHz).
        self.matchData = Self.synthesisedWAV(segments: [
            .init(frequency: 900,   durationS: 0.07),
            .init(frequency: 1_600, durationS: 0.10),
        ])
    }

    /// Fire-and-forget. Caller doesn't `await`; playback completes on
    /// its own (~120 ms). Subsequent calls overwrite the previous
    /// player — the last beep wins.
    public func playListenOpen() {
        play(data: listenOpenData)
    }

    /// Fire-and-forget. Plays the ascending confirmation pip — call
    /// when a wake word has just been recognised, before the state
    /// transition kicks in. Audible confirmation for hands-off use.
    public func playMatch() {
        play(data: matchData)
    }

    private func play(data: Data) {
        do {
            let p = try AVAudioPlayer(data: data)
            // Quiet enough to not startle, loud enough to hear over a
            // typical room. Tunable if it ends up too soft on hardware.
            p.volume = 0.5
            p.prepareToPlay()
            p.play()
            self.player = p
        } catch {
            Log.app.error("WakePing: AVAudioPlayer init failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Synthesis

    private struct ToneSegment {
        let frequency: Double
        let durationS: Double
    }

    /// Concatenates the given sine-wave segments into a single
    /// 22.05 kHz / 16-bit mono WAV blob. Each segment gets its own
    /// raised-cosine envelope so the start and end of every note are
    /// silent — avoids the clicks abrupt steps would otherwise produce
    /// at the segment boundaries.
    private static func synthesisedWAV(segments: [ToneSegment], amplitude: Double = 0.4) -> Data {
        let sampleRate: Double = 22_050

        var pcm = Data()
        for seg in segments {
            let frameCount = Int(sampleRate * seg.durationS)
            for i in 0..<frameCount {
                let t = Double(i) / sampleRate
                let envelope = sin(.pi * t / seg.durationS)      // 0 → 1 → 0
                let raw = sin(2 * .pi * seg.frequency * t) * envelope * amplitude
                let sample = Int16(raw * Double(Int16.max))
                withUnsafeBytes(of: sample.littleEndian) { pcm.append(contentsOf: $0) }
            }
        }

        // Minimal RIFF/WAVE header (44 bytes) + PCM.
        let dataSize = UInt32(pcm.count)
        let bytesPerSample: UInt16 = 2
        let channels: UInt16 = 1
        let byteRate = UInt32(sampleRate) * UInt32(channels) * UInt32(bytesPerSample)

        var wav = Data(capacity: 44 + pcm.count)
        wav.append(contentsOf: Array("RIFF".utf8))
        wav.append(uint32LE(36 + dataSize))
        wav.append(contentsOf: Array("WAVE".utf8))
        wav.append(contentsOf: Array("fmt ".utf8))
        wav.append(uint32LE(16))                            // fmt chunk size
        wav.append(uint16LE(1))                             // PCM format
        wav.append(uint16LE(channels))
        wav.append(uint32LE(UInt32(sampleRate)))
        wav.append(uint32LE(byteRate))
        wav.append(uint16LE(channels * bytesPerSample))     // block align
        wav.append(uint16LE(bytesPerSample * 8))            // bits per sample
        wav.append(contentsOf: Array("data".utf8))
        wav.append(uint32LE(dataSize))
        wav.append(pcm)
        return wav
    }

    private static func uint32LE(_ x: UInt32) -> Data {
        Data([
            UInt8(x & 0xff),
            UInt8((x >> 8) & 0xff),
            UInt8((x >> 16) & 0xff),
            UInt8((x >> 24) & 0xff),
        ])
    }

    private static func uint16LE(_ x: UInt16) -> Data {
        Data([
            UInt8(x & 0xff),
            UInt8((x >> 8) & 0xff),
        ])
    }
}
