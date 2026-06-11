import Foundation
import os

// Merges pause/resume chunk segments (e.g. `s01e02`, `s01e02c2`, `s01e02c3`)
// into a single m4a per logical meeting/section. Called from
// `WalkthroughCoordinator.finishUpload()` before the manifest is built.
//
// Pure segment/file plumbing — no coordinator state, no AVFoundation
// recording path. Intentionally not an actor so it can be unit-tested
// without spinning up an audio engine.
//
// Unit test note: the merge path calls `AudioMerger.merge` (AVFoundation
// asset export) and `FileManager` file moves, which both require real files
// on disk. Meaningful unit tests for the happy path would need actual m4a
// fixtures — skipped here. The pure parsing helpers (`parseSegmentID`,
// `chunkBaseID`, etc.) are testable but are exercised through the
// coordinator's own integration tests.

enum ChunkMerger {

    // MARK: - Result type

    /// The three coordinator collections after merge consolidation.
    struct Result: Sendable {
        var segments: [Segment]
        var segmentURLs: [String: URL]
        var segmentByID: [String: Int]
    }

    // MARK: - Entry point

    /// Fold contiguous same-base chunks into one merged m4a. Best-effort:
    /// a failure for any group leaves that group's chunks in place so the
    /// session still uploads. Behaviour is byte-for-byte identical to the
    /// original inline implementation in `WalkthroughCoordinator`.
    static func merge(
        segments: [Segment],
        segmentURLs: [String: URL],
        segmentByID: [String: Int],
        sessionDir: URL
    ) async -> Result {
        var newSegments: [Segment] = []
        var newSegmentURLs: [String: URL] = [:]
        var newSegmentByID: [String: Int] = [:]

        // First pass: collect any non-chunkable URLs (drive-by voice
        // notes, empty blocks). Their paths survive the merge unchanged.
        for seg in segments {
            switch seg {
            case .voiceNote(let v):
                newSegmentURLs[v.audio_file] = segmentURLs[v.audio_file]
            case .emptyBlock(let v):
                newSegmentURLs[v.audio_file] = segmentURLs[v.audio_file]
            default:
                break
            }
        }

        var i = 0
        while i < segments.count {
            let head = segments[i]
            guard let baseID = chunkBaseID(of: head) else {
                // Non-chunkable: pass through.
                newSegments.append(head)
                if let actualID = chunkActualID(of: head) {
                    newSegmentByID[actualID] = newSegments.count - 1
                }
                i += 1
                continue
            }
            // Sweep forward over contiguous same-base chunks.
            var j = i + 1
            while j < segments.count,
                  chunkBaseID(of: segments[j]) == baseID {
                j += 1
            }
            let group = Array(segments[i..<j])
            if group.count == 1 {
                // Single chunk — pass through unchanged.
                newSegments.append(head)
                if let actualID = chunkActualID(of: head),
                   let path = chunkAudioFile(of: head) {
                    newSegmentByID[actualID] = newSegments.count - 1
                    newSegmentURLs[path] = segmentURLs[path]
                }
            } else {
                // Multi-chunk — try to merge into one.
                let mergedSegment = await mergeGroup(
                    group: group,
                    baseID: baseID,
                    sessionDir: sessionDir,
                    segmentURLs: segmentURLs
                )
                if let mergedSegment {
                    newSegments.append(mergedSegment.segment)
                    newSegmentByID[baseID] = newSegments.count - 1
                    newSegmentURLs[mergedSegment.audioFile] = mergedSegment.audioURL
                    // Chunk files were deleted inside `mergeGroup` after
                    // the tmp file was safely written; no work here.
                } else {
                    // Merge failed — keep chunks separate so the session
                    // still uploads. History will show "Part 1 / Part 2"
                    // as before.
                    for chunk in group {
                        newSegments.append(chunk)
                        if let actualID = chunkActualID(of: chunk),
                           let path = chunkAudioFile(of: chunk) {
                            newSegmentByID[actualID] = newSegments.count - 1
                            newSegmentURLs[path] = segmentURLs[path]
                        }
                    }
                }
            }
            i = j
        }

        return Result(
            segments: newSegments,
            segmentURLs: newSegmentURLs,
            segmentByID: newSegmentByID
        )
    }

    // MARK: - Group merge

    /// Build a single merged `Segment` from a group of contiguous
    /// chunks sharing `baseID`. Returns nil on merge failure.
    ///
    /// Output path is `segments/<baseID>.m4a` — which is the SAME
    /// path the first chunk already occupies. To avoid clobbering
    /// input mid-merge, we write to a tmp file under the session
    /// segments directory (same volume → rename is atomic), then delete
    /// every chunk, then move the tmp file into place.
    /// Caller doesn't need to delete chunks; that's done here.
    private static func mergeGroup(
        group: [Segment],
        baseID: String,
        sessionDir: URL,
        segmentURLs: [String: URL]
    ) async -> (segment: Segment, audioFile: String, audioURL: URL)? {
        let chunkURLs: [URL] = group.compactMap { chunk in
            guard let path = chunkAudioFile(of: chunk) else { return nil }
            return segmentURLs[path]
        }
        guard chunkURLs.count == group.count else {
            Log.audio.warning(
                "merge: missing URL for one or more chunks of \(baseID, privacy: .public) — skipping"
            )
            return nil
        }
        let outputPath = mediaPath(for: baseID)
        let outputURL = sessionDir.appending(path: outputPath)
        // Stage the merged file inside session_dir/segments/ under
        // the `.tmp.m4a` pattern. Two wins over NSTemporaryDirectory:
        //   (1) same volume, so `moveItem` is a metadata-only rename
        //       — no cross-volume copy that can fail mid-flight.
        //   (2) `M4AWriter.isOrphanTempURL` matches `*.tmp.m4a`, so
        //       a crash before the rename leaves an orphan that
        //       `cleanupOrphans` reaps on next launch — and the
        //       pickup loader skips it via the same filter.
        let tempPath = "segments/\(baseID).tmp.m4a"
        let tempURL = sessionDir.appending(path: tempPath)
        if FileManager.default.fileExists(atPath: tempURL.path) {
            try? FileManager.default.removeItem(at: tempURL)
        }
        do {
            try await AudioMerger.merge(
                segments: chunkURLs,
                titles: nil,
                outputURL: tempURL
            )
        } catch {
            Log.audio.warning(
                "merge: \(baseID, privacy: .public) failed: \(String(describing: error), privacy: .public)"
            )
            try? FileManager.default.removeItem(at: tempURL)
            return nil
        }
        // Merge succeeded — now move the tmp file into place. We
        // explicitly clear outputURL first (the first chunk lives
        // there), then delete the other chunks. Order matters:
        // until the move into outputURL completes, the merged data
        // exists only in the tmp file, so we don't delete more chunks
        // than necessary before the swap.
        let fm = FileManager.default
        if fm.fileExists(atPath: outputURL.path) {
            do {
                try fm.removeItem(at: outputURL)
            } catch {
                Log.audio.warning(
                    "merge: \(baseID, privacy: .public) couldn't clear first chunk at outputURL — \(String(describing: error), privacy: .public)"
                )
                try? fm.removeItem(at: tempURL)
                return nil
            }
        }
        do {
            try fm.moveItem(at: tempURL, to: outputURL)
        } catch {
            Log.audio.warning(
                "merge: \(baseID, privacy: .public) move-into-place failed: \(String(describing: error), privacy: .public)"
            )
            try? fm.removeItem(at: tempURL)
            return nil
        }
        // Move succeeded — delete the remaining chunk files (c2, c3, …).
        // The first chunk is already gone (the move overwrote it).
        for chunk in group.dropFirst() {
            guard let path = chunkAudioFile(of: chunk),
                  let url = segmentURLs[path] else { continue }
            try? fm.removeItem(at: url)
        }
        // Concatenate transcripts. Skips empty pieces so we don't get
        // double spaces or leading/trailing whitespace.
        let mergedTranscript = group
            .compactMap { extractTranscript(from: $0) }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        // First non-empty language wins (chunks of the same meeting
        // are virtually always the same language).
        let mergedLanguage = group
            .compactMap { extractLanguage(from: $0) }
            .first(where: { !$0.isEmpty }) ?? "de-DE"
        // Aggregate todos across chunks for calendar events. Other
        // segment types don't carry todos at this layer.
        let aggregatedTodos: [Todo] = group.flatMap { chunk -> [Todo] in
            if case .calendarEvent(let v) = chunk { return v.todos_detected }
            return []
        }
        // Aggregate linked_seed_ids across chunks (calendar events only).
        let aggregatedLinkedSeeds: [String] = group.flatMap { chunk -> [String] in
            if case .calendarEvent(let v) = chunk { return v.linked_seed_ids }
            return []
        }

        // Rebuild the segment record off the first chunk's shape,
        // overriding id / audio_file / transcript / language /
        // aggregated todos.
        guard let first = group.first else { return nil }
        let merged: Segment
        switch first {
        case .calendarEvent(var v):
            v.segment_id = baseID
            v.audio_file = outputPath
            v.transcript = mergedTranscript
            v.language = mergedLanguage
            v.todos_detected = aggregatedTodos
            v.linked_seed_ids = aggregatedLinkedSeeds
            merged = .calendarEvent(v)
        case .generalSection(var v):
            v.segment_id = baseID
            v.audio_file = outputPath
            v.transcript = mergedTranscript
            v.language = mergedLanguage
            merged = .generalSection(v)
        case .freeReflection(var v):
            v.segment_id = baseID
            v.audio_file = outputPath
            v.transcript = mergedTranscript
            v.language = mergedLanguage
            merged = .freeReflection(v)
        default:
            // Should never hit — only chunkable shapes get here.
            return nil
        }
        Log.audio.info(
            "merge: \(baseID, privacy: .public) consolidated \(group.count, privacy: .public) chunks"
        )
        return (merged, outputPath, outputURL)
    }

    // MARK: - Segment accessors

    /// Base id (no `c<N>` suffix) for a chunkable segment, nil for
    /// drive-by voice notes / empty blocks.
    static func chunkBaseID(of seg: Segment) -> String? {
        guard let actualID = chunkActualID(of: seg) else { return nil }
        return parseSegmentID(actualID).baseID
    }

    static func chunkActualID(of seg: Segment) -> String? {
        switch seg {
        case .calendarEvent(let v):  return v.segment_id
        case .freeReflection(let v): return v.segment_id
        case .generalSection(let v): return v.segment_id
        case .voiceNote(let v):      return v.segment_id
        case .emptyBlock(let v):     return v.segment_id
        }
    }

    static func chunkAudioFile(of seg: Segment) -> String? {
        switch seg {
        case .calendarEvent(let v):  return v.audio_file
        case .freeReflection(let v): return v.audio_file
        case .generalSection(let v): return v.audio_file
        case .voiceNote(let v):      return v.audio_file
        case .emptyBlock(let v):     return v.audio_file
        }
    }

    static func extractTranscript(from seg: Segment) -> String? {
        switch seg {
        case .calendarEvent(let v):  return v.transcript
        case .freeReflection(let v): return v.transcript
        case .generalSection(let v): return v.transcript
        default: return nil
        }
    }

    static func extractLanguage(from seg: Segment) -> String? {
        switch seg {
        case .calendarEvent(let v):  return v.language
        case .freeReflection(let v): return v.language
        case .generalSection(let v): return v.language
        default: return nil
        }
    }

    // MARK: - Segment ID parsing

    /// Canonical media path for a segment id (e.g. "s01e02" →
    /// "segments/s01e02.m4a"). Mirrors the coordinator's own `mediaPath`.
    static func mediaPath(for segmentID: String) -> String {
        "segments/\(segmentID).m4a"
    }

    private static let segmentIDPattern: NSRegularExpression? = {
        try? NSRegularExpression(pattern: #"^(s\d+(?:e\d+)?)(?:c(\d+))?$"#)
    }()

    /// Parse a segment filename stem (`s01`, `s01e02`, `s01e02c3`) into
    /// its base id + resume/chunk index. Mirrors the coordinator's own
    /// `parseSegmentID`.
    static func parseSegmentID(_ stem: String) -> (baseID: String, resumeIdx: Int) {
        guard let regex = segmentIDPattern,
              let match = regex.firstMatch(
                  in: stem,
                  options: [],
                  range: NSRange(stem.startIndex..., in: stem)
              )
        else { return (stem, 1) }
        let ns = stem as NSString
        let base = ns.substring(with: match.range(at: 1))
        let chunkRange = match.range(at: 2)
        let chunk: Int = {
            guard chunkRange.location != NSNotFound else { return 1 }
            return Int(ns.substring(with: chunkRange)) ?? 1
        }()
        return (base, chunk)
    }
}
