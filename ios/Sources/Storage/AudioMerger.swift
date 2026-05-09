import AVFoundation
import Foundation

/// Concatenates a list of `.m4a` segments into a single `.m4a` file via
/// `AVMutableComposition` + `AVAssetExportSession`.
///
/// Used by Verlauf to give the user a single shareable audio file for a
/// walkthrough session (each event recorded a separate segment so they
/// can't be downloaded individually in a useful way). The drive-by side
/// already produces a single file — no merging needed.
public enum AudioMerger {

    /// Truncate `url` by removing the last `seconds` of audio. Used by
    /// the wake-word path: when the user says "weiter" mid-segment, we
    /// don't want that command word (plus any setup-time audio that
    /// triggered the wake window) to leak into the uploaded reflection.
    /// Replaces the file in-place via an `AVAssetExportSession` time-
    /// range slice so the final M4A stays valid for both client-side
    /// Parakeet and server-side Whisper.
    public static func trimTail(
        of url: URL,
        removingLastSeconds seconds: TimeInterval
    ) async throws {
        guard seconds > 0 else { return }
        let asset = AVURLAsset(url: url)
        let totalDuration = try await asset.load(.duration)
        let totalSeconds = CMTimeGetSeconds(totalDuration)
        // Whole file shorter than what we'd cut — drop it entirely so
        // Whisper doesn't trip on a zero-length M4A.
        if totalSeconds <= seconds + 0.05 {
            try? FileManager.default.removeItem(at: url)
            return
        }
        let keepSeconds = max(0.0, totalSeconds - seconds)
        let keepDuration = CMTime(seconds: keepSeconds, preferredTimescale: 600)
        let timeRange = CMTimeRange(start: .zero, duration: keepDuration)

        let scratch = url
            .deletingPathExtension()
            .appendingPathExtension("trimmed.m4a")
        if FileManager.default.fileExists(atPath: scratch.path) {
            try FileManager.default.removeItem(at: scratch)
        }

        guard let exporter = AVAssetExportSession(
            asset: asset,
            presetName: AVAssetExportPresetPassthrough
        ) else {
            throw MergeError.exportFailed("could not create exporter for tail trim")
        }
        exporter.outputURL = scratch
        exporter.outputFileType = .m4a
        exporter.timeRange = timeRange
        try await exporter.export(to: scratch, as: .m4a)

        try FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: scratch, to: url)
    }

    public enum MergeError: Error, LocalizedError {
        case emptyInput
        case missingTrack(URL)
        case exportFailed(String)

        public var errorDescription: String? {
            switch self {
            case .emptyInput:           return "Keine Audiodateien zum Zusammenfügen."
            case .missingTrack(let u):  return "Audiospur fehlt in \(u.lastPathComponent)."
            case .exportFailed(let m):  return "Export fehlgeschlagen: \(m)"
            }
        }
    }

    /// Merge `segments` (in the order given) into a single m4a written to
    /// `outputURL`. Optionally prepend a short TTS announcement before
    /// each segment so the listener can hear which event it relates to.
    ///
    /// `titles[i]` is spoken before `segments[i]`. A nil entry skips the
    /// announcement for that segment. `titleLanguage` controls the voice
    /// (BCP-47 — "de-DE" / "en-US"). Pass `titles: nil` to disable
    /// announcements entirely (= plain concatenation).
    ///
    /// Implementation: read each segment as PCM via `AVAudioFile` and
    /// write into one new `AVAudioFile` configured for AAC-LC m4a —
    /// same code path as `M4AWriter.swift` which produces the files
    /// the single-segment fast path ships happily. TTS PCM is captured
    /// via `AVSpeechSynthesizer.write` and streamed into the same
    /// writer; AVAudioFile auto-converts the synth's sample rate to
    /// match the output container.
    public static func merge(
        segments: [URL],
        titles: [String?]? = nil,
        titleLanguage: String = "de-DE",
        outputURL: URL
    ) async throws {
        guard !segments.isEmpty else { throw MergeError.emptyInput }

        // Single-segment fast path is only safe when there's no TTS
        // prelude to mix in (otherwise the byte copy would skip the
        // announcement).
        let needsAnnouncements = (titles?.contains { $0?.isEmpty == false }) ?? false
        if segments.count == 1 && !needsAnnouncements {
            try writeOut(data: try Data(contentsOf: segments[0]),
                         to: outputURL)
            return
        }

        // Take the sample rate from the first readable segment so the
        // output matches the source recordings (all walkthrough
        // segments share the same audio session config, so they're all
        // the same rate — usually 44.1 or 48 kHz on iPhone).
        let probe = try AVAudioFile(forReading: segments[0])
        let processingFormat = probe.processingFormat
        let sampleRate = probe.fileFormat.sampleRate > 0
            ? probe.fileFormat.sampleRate
            : processingFormat.sampleRate

        // CRITICAL: keep the `.m4a` extension on the scratch URL.
        // `AVAudioFile` picks the container format from the file
        // extension — anything other than `.m4a` (we previously used
        // `.m4a.scratch`) makes it fall back to CAF (`caff` magic),
        // which iOS LaunchServices then rejects when the share sheet
        // tries to bind a `.m4a`-typed handler. Compose the scratch
        // name as `voicediary-…-scratch.m4a` instead.
        let scratch = outputURL
            .deletingPathExtension()
            .appendingPathExtension("scratch.m4a")
        if FileManager.default.fileExists(atPath: scratch.path) {
            try? FileManager.default.removeItem(at: scratch)
        }

        // Inner scope so the AVAudioFile writer deinits BEFORE we read
        // the file back. AVAudioFile finalises the m4a container (mdat
        // + moov atoms) only on `deinit` — without an explicit scope,
        // a `let writer` lives until the function returns, so the
        // subsequent `Data(contentsOf: scratch)` reads a half-baked
        // file: a valid `ftyp` followed by ~60 KB of zeros and stray
        // AAC frames. No moov = no codec metadata = unplayable.
        var anyFramesWritten = false
        // Inner async closure so the AVAudioFile writer deinits BEFORE
        // we read the file back. AVAudioFile finalises the m4a
        // container (mdat + moov atoms) only on `deinit`.
        try await { () async throws -> Void in
            let writer = try AVAudioFile(
                forWriting: scratch,
                settings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: sampleRate,
                    AVNumberOfChannelsKey: 1,
                    AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
                    AVEncoderBitRateKey: 64_000,
                ],
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )

            let chunkFrames: AVAudioFrameCount = 8192
            for (index, segmentURL) in segments.enumerated() {
                // 1. Optional title announcement.
                if let title = titles?[safe: index] ?? nil,
                   !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    try await renderTTS(
                        text: title,
                        language: titleLanguage,
                        into: writer
                    )
                    anyFramesWritten = true
                }

                // 2. Segment audio.
                let reader = try AVAudioFile(forReading: segmentURL)
                guard let buffer = AVAudioPCMBuffer(
                    pcmFormat: reader.processingFormat,
                    frameCapacity: chunkFrames
                ) else {
                    throw MergeError.exportFailed(
                        "PCM buffer alloc failed for \(segmentURL.lastPathComponent)"
                    )
                }
                while reader.framePosition < reader.length {
                    buffer.frameLength = 0
                    try reader.read(into: buffer)
                    guard buffer.frameLength > 0 else { break }
                    try writer.write(from: buffer)
                    anyFramesWritten = true
                }
            }
            // `writer` deinits here → the m4a is now finalised on disk.
        }()

        guard anyFramesWritten else {
            try? FileManager.default.removeItem(at: scratch)
            throw MergeError.emptyInput
        }

        // Re-write through Data with .noFileProtection so the share
        // sheet extension (separate process) can read the file.
        let bytes = try Data(contentsOf: scratch)
        try writeOut(data: bytes, to: outputURL)
        try? FileManager.default.removeItem(at: scratch)
    }

    /// Write the bytes to `dest` with `.noFileProtection` so the file
    /// can be read by share-sheet receivers running outside our app
    /// container, then explicitly drop protection on the resulting file
    /// for belt-and-braces (some iOS versions ignore the write option).
    private static func writeOut(data: Data, to dest: URL) throws {
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        try data.write(to: dest, options: [.atomic, .noFileProtection])
        try? (dest as NSURL).setResourceValue(URLFileProtection.none,
                                              forKey: .fileProtectionKey)
    }

    /// Convenience: write the merged file into the system temp directory
    /// with a stable name derived from the session id. Returns the URL of
    /// the resulting file. Always re-merges — caching here had a habit of
    /// pinning a malformed prior export.
    public static func mergedTempFile(
        for sessionID: String,
        segments: [URL],
        titles: [String?]? = nil,
        titleLanguage: String = "de-DE"
    ) async throws -> URL {
        let safe = sessionID.replacingOccurrences(of: ":", with: "-")
                            .replacingOccurrences(of: "+", with: "_")
        let url = FileManager.default.temporaryDirectory
            .appending(path: "voicediary-\(safe).m4a")

        try await merge(
            segments: segments,
            titles: titles,
            titleLanguage: titleLanguage,
            outputURL: url
        )
        return url
    }

    /// Stream `AVSpeechSynthesizer` output into the given AVAudioFile
    /// writer. Used to splice short title announcements between the
    /// per-event audio segments. AVAudioFile auto-converts the synth's
    /// native sample rate (typically 22050 Hz) to the writer's rate.
    private static func renderTTS(
        text: String,
        language: String,
        into writer: AVAudioFile
    ) async throws {
        let synth = AVSpeechSynthesizer()
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: language)
                       ?? AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.95
        utterance.volume = 1.0

        // The write callback fires on a synth-internal thread for each
        // chunk and once with frameLength == 0 to signal completion.
        // Wrap in a continuation so the merger awaits completion before
        // moving on to the next segment.
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let didResume = WriteOnceFlag()
            synth.write(utterance) { buffer in
                guard let pcm = buffer as? AVAudioPCMBuffer else { return }
                if pcm.frameLength == 0 {
                    if didResume.set() { cont.resume() }
                    return
                }
                do {
                    try writer.write(from: pcm)
                } catch {
                    if didResume.set() { cont.resume(throwing: error) }
                }
            }
        }
    }
}

/// Single-shot flag protecting the `CheckedContinuation` from double
/// resume across the synth's chunk/completion callbacks.
private final class WriteOnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    /// Returns true exactly once; further calls return false.
    func set() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !done else { return false }
        done = true
        return true
    }
}

private extension Array {
    subscript(safe i: Int) -> Element? {
        indices.contains(i) ? self[i] : nil
    }
}
