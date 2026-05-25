import AVFoundation
import Foundation
import os

// Writes AAC audio to disk in an M4A container.
//
// ## Thread safety
//
// `M4AWriter` is touched from two threads:
//   * the actor that owns the audio engine (`open`, `close`, `shutdown`)
//   * the `AVAudioEngine` input-tap callback (`write`, on the real-time
//     audio thread)
//
// All access goes through a single `OSAllocatedUnfairLock<State>`. The
// audio thread holds the lock only for the duration of one
// `AVAudioFile.write(from:)`, which is a few milliseconds at worst
// (AAC encoding + a small filesystem write). The actor's `close` and
// `open` calls hold the lock only long enough to swap the state
// enum — sub-microsecond — and do the moov-writing deinit + the
// final-URL rename *outside* the lock, so they never block the audio
// thread for filesystem latency. A late `write` arriving after `close`
// returns simply sees `.closed` and throws `WriterError.notOpen`,
// which the tap closure already catches and logs.
//
// ## Container choice
//
// `AVAudioFile(forWriting:)` picks its output container from the URL's
// trailing extension. A name ending in `.tmp` silently falls back to
// CAF, which writes its packet table (`pakt` chunk) only on a clean
// deinit — any background suspension or crash mid-segment then leaves
// a payload-complete but `pakt`-less file that no decoder can index
// (duration reports as 0; playback hangs). We therefore keep `.m4a`
// as the trailing extension throughout: the temp sibling of
// `…/s01.m4a` is `…/s01.tmp.m4a`, **not** `…/s01.m4a.tmp`.
//
// ## What still goes wrong
//
// Even with the container fix, an M4A file's `moov` atom is written
// at file close. A crash mid-segment leaves the AAC payload on disk
// but no `moov`, so the file is unreadable. Recovery from that state
// needs external tooling (untrunc / `ffmpeg -err_detect ignore_err`).
// The writer prevents the CAF-specific footgun; it does not eliminate
// the close-race entirely. Orphan temp files left behind by such a
// crash are removed by `cleanupOrphans(in:)`, called once at app
// launch.

public final class M4AWriter: @unchecked Sendable {
    public static let bitrate: Int = 64_000
    public static let channels: AVAudioChannelCount = 1

    public enum WriterError: Error, CustomStringConvertible {
        case alreadyOpen
        case notOpen
        case renameFailed(underlying: any Error, tempURL: URL)

        public var description: String {
            switch self {
            case .alreadyOpen: return "M4AWriter is already open"
            case .notOpen:     return "M4AWriter is not open"
            case .renameFailed(let err, let url):
                return "M4AWriter rename failed (\(url.lastPathComponent)): \(err)"
            }
        }
    }

    /// Two-state machine. The AVAudioFile is held only by the `.open`
    /// associated value; transitioning to `.closed` drops the writer's
    /// strong ref to it. `close()` snapshots that ref into a local and
    /// drops the local outside the lock, so the deinit (which writes
    /// the moov atom) doesn't block the audio thread.
    private enum State {
        case closed
        case open(file: AVAudioFile, tempURL: URL, finalURL: URL, sampleRate: Double)
    }

    private let lock = OSAllocatedUnfairLock<State>(initialState: .closed)

    /// Sample rate of the most recently opened segment, surfaced for
    /// `AudioEngine.lastSampleRate`. Pointer-sized double — accessed
    /// outside the lock; only updated from `open()`, which is itself
    /// serialised by the owning actor.
    private var _lastSampleRate: Double = 0

    public init() {}

    /// Sample rate of the most recently written file (0 before any capture).
    public var sampleRate: Double { _lastSampleRate }

    /// Always mono. Kept as a property for source-compatibility with the
    /// previous interface.
    public var actualChannels: AVAudioChannelCount { M4AWriter.channels }

    /// Open a writer that records mono AAC at `inputSampleRate`. The
    /// caller is expected to be the audio engine's owning actor; only
    /// one open at a time is permitted. Throws `.alreadyOpen` if the
    /// writer is already mid-segment.
    public func open(at finalURL: URL, inputSampleRate: Double) throws {
        let temp = Self.tempURL(for: finalURL)
        // Belt-and-suspenders: drop any leftover temp from a previous
        // run with this exact final URL. `cleanupOrphans` also sweeps
        // the whole tree at launch, but a same-URL collision (e.g. a
        // re-run that hits the same s01.m4a path) is the most common
        // single-segment recurrence and worth handling locally.
        try? FileManager.default.removeItem(at: temp)

        let rate = inputSampleRate > 0 ? inputSampleRate : 44_100
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: M4AWriter.channels,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
            AVEncoderBitRateKey: M4AWriter.bitrate,
        ]
        // Build the AVAudioFile *outside* the lock — its initializer
        // touches the filesystem and can take real time. Holding the
        // lock that long would stall the audio thread.
        let avf = try AVAudioFile(
            forWriting: temp,
            settings: settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )

        try lock.withLockUnchecked { state -> Void in
            guard case .closed = state else {
                throw WriterError.alreadyOpen
            }
            state = .open(file: avf, tempURL: temp, finalURL: finalURL, sampleRate: rate)
        }
        // Only mutate the public sample-rate snapshot after the state
        // transition succeeded — otherwise an `alreadyOpen` throw would
        // leave a misleading value behind.
        _lastSampleRate = rate
    }

    /// Append one PCM buffer to the open segment. Called from the audio
    /// tap on every input buffer. A `.notOpen` throw here is expected
    /// during the brief window between `close()` and the next
    /// `removeTap` callback drain; the tap closure logs and discards.
    public func write(buffer: AVAudioPCMBuffer) throws {
        try lock.withLockUnchecked { state -> Void in
            guard case .open(let file, _, _, _) = state else {
                throw WriterError.notOpen
            }
            try file.write(from: buffer)
        }
    }

    /// Finalise the open segment and move the temp file to its final
    /// URL. Returns the final URL on success, `nil` if the writer was
    /// already closed (idempotent), and throws `.renameFailed` if the
    /// moov was written but the rename couldn't be completed — the
    /// temp file remains on disk in that case and can be recovered.
    @discardableResult
    public func close() throws -> URL? {
        // Under the lock: transition to `.closed` (so a subsequent
        // `write()` throws `.notOpen` instead of touching the file) and
        // hand the AVAudioFile out via a local var so it stays alive
        // past the lock release.
        //
        // Outside the lock: drop the local. ARC releases the only
        // remaining strong ref, so AVAudioFile's deinit runs
        // synchronously here — writing the moov atom — *before* the
        // rename. Doing the deinit outside the lock means the audio
        // thread is never blocked on filesystem latency while a write
        // is finalising; doing it before the rename means the temp
        // file is a complete M4A by the time it gets its final name.
        var fileRef: AVAudioFile?
        var tempURL: URL?
        var finalURL: URL?
        lock.withLockUnchecked { state in
            if case .open(let f, let t, let fnl, _) = state {
                fileRef = f
                tempURL = t
                finalURL = fnl
                state = .closed
            }
        }
        // `fileRef = nil` is the operative line. The trailing `_ =`
        // suppresses Swift's "written but never read" warning while
        // making it explicit that the assignment is exactly the point:
        // it triggers AVAudioFile's synchronous deinit (moov-atom write
        // to disk) right here, before the rename.
        fileRef = nil
        _ = fileRef

        guard let tempURL, let finalURL else { return nil }
        do {
            try FileManager.default.moveItem(at: tempURL, to: finalURL)
            return finalURL
        } catch {
            // moov was written above, but the rename failed (disk full,
            // permissions, …). The temp file is a complete, decodable
            // M4A — surface the error so the caller can decide whether
            // to retry / keep / discard.
            throw WriterError.renameFailed(underlying: error, tempURL: tempURL)
        }
    }

    // MARK: - Naming + cleanup ---------------------------------------

    /// Sibling temp URL for `finalURL` that keeps the recognized
    /// container extension as the trailing component. E.g.
    /// `…/s01.m4a` → `…/s01.tmp.m4a`. Public-static so other layers
    /// (`SessionHistoryStore`, future debug tools) can use the same
    /// naming rule without duplicating the string operation.
    public static func tempURL(for finalURL: URL) -> URL {
        let stem = finalURL.deletingPathExtension().lastPathComponent
        let ext = finalURL.pathExtension
        let leaf = ext.isEmpty ? "\(stem).tmp" : "\(stem).tmp.\(ext)"
        return finalURL.deletingLastPathComponent().appendingPathComponent(leaf)
    }

    /// True if `url` looks like one of the writer's staging files —
    /// either the current `*.tmp.m4a` pattern or the legacy
    /// `*.m4a.tmp` pattern from before the container fix. Single
    /// source of truth for the orphan-filter rule.
    public static func isOrphanTempURL(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        return name.hasSuffix(".tmp.m4a") || name.hasSuffix(".m4a.tmp")
    }

    /// Walk `root` recursively and delete every orphan temp file left
    /// behind by a crashed previous run. Safe to call at any time when
    /// no recording is in progress (e.g. once at app launch). Returns
    /// the number of files removed. Errors during enumeration or
    /// per-file removal are logged but never thrown — a stale orphan
    /// is annoying, not catastrophic.
    @discardableResult
    public static func cleanupOrphans(in root: URL) -> Int {
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path),
              let enumerator = fm.enumerator(
                at: root,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
              )
        else { return 0 }

        var removed = 0
        for case let url as URL in enumerator {
            guard isOrphanTempURL(url) else { continue }
            do {
                try fm.removeItem(at: url)
                removed += 1
                Log.audio.info(
                    "removed orphan temp file: \(url.lastPathComponent, privacy: .public)"
                )
            } catch {
                Log.audio.error(
                    "failed to remove orphan \(url.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public)"
                )
            }
        }
        return removed
    }
}
