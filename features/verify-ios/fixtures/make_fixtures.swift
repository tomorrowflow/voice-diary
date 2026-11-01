// Regenerates the retained-audio fixtures (KA-12): synthetic tones, no speech, no recording.
//
//   swift features/verify-ios/fixtures/make_fixtures.swift features/verify-ios/fixtures/retained-audio
//
// Same container and codec as the app's M4AWriter: AAC-LC, mono, `.m4a`, written through
// AVAudioFile. 16 kHz (the `AudioCodec` default) at 32 kbps (the app writes 64 kbps) keeps each
// file to about 30 KB; at 44.1 kHz the encoder ignores the low bitrate and writes 80 KB.

import AVFoundation
import Foundation

struct Tone {
    let path: String
    let seconds: Double
    let hertz: Double
}

let tones = [
    Tone(path: "sessions/2026-10-30T18-15-00Z/segments/s01.m4a", seconds: 9, hertz: 440),
    Tone(path: "sessions/2026-10-30T18-15-00Z/segments/s02.m4a", seconds: 10, hertz: 330),
    Tone(path: "driveby_seeds/2026-10-30T16-40-00Z/audio.m4a", seconds: 8, hertz: 523.25),
]

let sampleRate = 16_000.0
let bitrate = 32_000
let chunkFrames: AVAudioFrameCount = 4_096

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: make_fixtures.swift <output dir>\n".utf8))
    exit(2)
}
let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)

func write(_ tone: Tone) throws {
    let url = root.appending(path: tone.path)
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true
    )
    try? FileManager.default.removeItem(at: url)
    let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: sampleRate,
        AVNumberOfChannelsKey: 1,
        AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
        AVEncoderBitRateKey: bitrate,
    ]
    let file = try AVAudioFile(
        forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false
    )
    let total = Int(tone.seconds * sampleRate)
    let fade = Int(0.05 * sampleRate)
    var frame = 0
    while frame < total {
        let count = min(Int(chunkFrames), total - frame)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunkFrames)!
        buffer.frameLength = AVAudioFrameCount(count)
        let samples = buffer.floatChannelData![0]
        for i in 0..<count {
            let n = frame + i
            let t = Double(n) / sampleRate
            // Slow 0.5 Hz swell so the tone is audibly alive, 50 ms fades at both ends.
            let swell = 0.65 + 0.35 * sin(2 * Double.pi * 0.5 * t)
            let edge = min(1.0, Double(min(n, total - 1 - n)) / Double(fade))
            samples[i] = Float(0.25 * swell * edge * sin(2 * Double.pi * tone.hertz * t))
        }
        try file.write(from: buffer)
        frame += count
    }
}

for tone in tones {
    do { try write(tone) } catch {
        FileHandle.standardError.write(Data("\(tone.path): \(error)\n".utf8))
        exit(1)
    }
    // The file is closed once `write` returns; read it back as the app would.
    let url = root.appending(path: tone.path)
    let probe = try AVAudioFile(forReading: url)
    let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    let seconds = Double(probe.length) / probe.processingFormat.sampleRate
    print("\(tone.path) \(bytes) bytes \(String(format: "%.2f", seconds)) s")
}
