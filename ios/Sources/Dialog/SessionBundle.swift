import Foundation
import os

// One evening walkthrough as it exists on the phone: its segments, their
// audio and everything the manifest will say about them (CONTEXT.md:
// "session bundle"). The coordinator decides the dialogue; the bundle owns
// the disk layout, the segment and chunk ids and the manifest, so those
// details live in one place.

/// What `SessionBundle.finalize` hands to the uploader: the manifest and
/// the audio files it references, keyed by the manifest `audio_file` path.
struct UploadBundle: Sendable {
    let manifest: Manifest
    let files: [String: URL]
}

/// The audio facilities a bundle needs but must not own: merging chunk
/// files and asking the capture engine what rate it actually recorded at.
/// Injected so the bundle is testable without an audio engine.
protocol SessionBundleAudio: Sendable {
    /// Concatenate `chunks`, in order, into a new file at `output`.
    func merge(chunks: [URL], into output: URL) async throws
    /// Sample rate of the most recently started capture (0 when unknown).
    func sampleRate() async -> Double
}

/// The production adapter: `AudioMerger` for merging, the walkthrough's
/// `AudioEngine` for the sample rate.
struct EngineSessionBundleAudio: SessionBundleAudio {
    let engine: AudioEngine

    func merge(chunks: [URL], into output: URL) async throws {
        try await AudioMerger.merge(segments: chunks, titles: nil, outputURL: output)
    }

    func sampleRate() async -> Double {
        await engine.lastSampleRate
    }
}

@MainActor
final class SessionBundle {

    /// The typed segment `record` opens. `baseID` is the plan step's id
    /// (`s01`, `s01e02`); the bundle adds the `c<N>` suffix on a resume.
    enum Kind {
        case event(baseID: String, calendarRef: CalendarRef)
        case general(baseID: String, section: GeneralSection)
        case reflection(baseID: String)

        var baseID: String {
            switch self {
            case .event(let baseID, _), .general(let baseID, _), .reflection(let baseID):
                return baseID
            }
        }
    }

    /// Starts the capture into `url`. Throws when it cannot start.
    typealias Capture = (URL) async throws -> Void

    /// Applies the app-wide protection class to a created file or directory.
    typealias Protector = @MainActor (URL) -> Void

    /// Sample rate reported when nothing was recorded in this run, e.g. a
    /// session assembled purely from files left by an earlier run.
    static let defaultSampleRate = 44_100

    let directory: URL
    let sessionID: String

    /// Segments in recording order. Read-only outside the bundle.
    private(set) var segments: [Segment] = []
    /// Actual id of the segment being recorded now, nil between segments.
    private(set) var currentSegmentID: String?
    /// Seed ids of the voice notes attached to this session.
    private(set) var surfacedNoteIDs: [String] = []
    var confirmedTodoCount: Int { confirmedTodos.count }

    private let audio: any SessionBundleAudio
    private let protect: Protector
    private var chunkCounters: [String: Int] = [:]
    private var sampleRates: [Double] = []
    private var aiPrompts: [AiPrompt] = []
    private var confirmedTodos: [Todo] = []
    private var rejectedTodos: [TodoRejected] = []

    init(
        directory: URL,
        sessionID: String,
        audio: any SessionBundleAudio,
        protect: @escaping Protector = { LocalStore.applyProtection(to: $0) }
    ) {
        self.directory = directory
        self.sessionID = sessionID
        self.audio = audio
        self.protect = protect
    }

    /// Create the on-disk layout for a new session under `stagingRoot`.
    /// iOS file protection is per node, not inherited, so every directory
    /// created here is tagged: without it recording dies the moment the
    /// device locks (writes return -40, the next open -54).
    static func create(
        in stagingRoot: URL,
        sessionID: String,
        audio: any SessionBundleAudio,
        protect: @escaping Protector = { LocalStore.applyProtection(to: $0) }
    ) throws -> SessionBundle {
        let dir = stagingRoot.appending(path: sanitize(sessionID), directoryHint: .isDirectory)
        let segmentsDir = dir.appending(path: "segments", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: segmentsDir, withIntermediateDirectories: true)
        protect(dir)
        protect(segmentsDir)
        return SessionBundle(directory: dir, sessionID: sessionID, audio: audio, protect: protect)
    }

    // MARK: - Ids and paths

    /// Canonical media path for a segment id (`s01e02` → `segments/s01e02.m4a`).
    static func mediaPath(for segmentID: String) -> String {
        "segments/\(segmentID).m4a"
    }

    /// Make a seed or session id safe to use in a file name.
    static func sanitize(_ s: String) -> String {
        s.replacingOccurrences(of: ":", with: "-")
         .replacingOccurrences(of: "+", with: "_")
    }

    private static let segmentIDPattern: NSRegularExpression? = {
        try? NSRegularExpression(pattern: #"^(s\d+(?:e\d+)?)(?:c(\d+))?$"#)
    }()

    /// Parse a segment id (`s01`, `s01e02`, `s01e02c3`) into its base id and
    /// chunk index (1 for the first recording).
    static func parseSegmentID(_ stem: String) -> (baseID: String, chunkIndex: Int) {
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
        guard chunkRange.location != NSNotFound else { return (base, 1) }
        return (base, Int(ns.substring(with: chunkRange)) ?? 1)
    }

    /// The on-disk file of a recorded segment, nil for an unknown id.
    func audioURL(forSegmentID id: String) -> URL? {
        segments.first { $0.segmentID == id }
            .map { directory.appending(path: $0.audioFile) }
    }

    // MARK: - Recording

    /// Allocate the next segment id and path for `kind`, run `capture` into
    /// it and record the segment, but only when the capture started. The
    /// first recording of a base id uses it verbatim; after a pause the
    /// next is `<base>c2`, then `c3`, ... so a resume never overwrites the
    /// earlier chunk. A throwing capture leaves no segment, no id and no
    /// current segment behind.
    func record(_ kind: Kind, capture: Capture) async throws {
        let baseID = kind.baseID
        let chunk = chunkCounters[baseID, default: 0] + 1
        let actualID = chunk == 1 ? baseID : "\(baseID)c\(chunk)"
        let path = Self.mediaPath(for: actualID)
        let url = directory.appending(path: path)
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        protect(parent)

        try await capture(url)

        protect(url)
        let rate = await audio.sampleRate()
        if rate > 0 { sampleRates.append(rate) }
        chunkCounters[baseID] = chunk
        segments.append(Self.makeSegment(kind, actualID: actualID, audioFile: path))
        currentSegmentID = actualID
    }

    private static func makeSegment(_ kind: Kind, actualID: String, audioFile: String) -> Segment {
        switch kind {
        case .event(_, let calendarRef):
            return .calendarEvent(CalendarEventSegment(
                segment_id: actualID,
                calendar_ref: calendarRef,
                audio_file: audioFile
            ))
        case .general(_, let section):
            return .generalSection(GeneralSectionSegment(
                segment_id: actualID,
                section_id: section.id,
                title: section.title,
                prompt_text: section.introText,
                audio_file: audioFile
            ))
        case .reflection:
            return .freeReflection(FreeReflectionSegment(
                segment_id: actualID,
                audio_file: audioFile,
                captured_at: ISO8601DateFormatter().string(from: Date())
            ))
        }
    }

    /// The current recording has stopped: forget it as current and return
    /// what to transcribe. Nil when nothing was recording.
    func finishCurrent() -> (id: String, url: URL)? {
        guard let id = currentSegmentID else { return nil }
        currentSegmentID = nil
        return audioURL(forSegmentID: id).map { (id, $0) }
    }

    /// Delete the segment being recorded: its file and its manifest entry.
    /// After a pause the current id carries a `c<N>` suffix, so dropping by
    /// the base id would orphan that file. `fallbackSegmentID` is used
    /// when nothing was recording (a skip before the engine started).
    func dropCurrent(fallbackSegmentID: String? = nil) {
        guard let id = currentSegmentID ?? fallbackSegmentID else { return }
        if let url = audioURL(forSegmentID: id) {
            try? FileManager.default.removeItem(at: url)
        }
        segments.removeAll { segment in
            switch segment {
            case .calendarEvent, .freeReflection, .generalSection: return segment.segmentID == id
            case .voiceNote, .emptyBlock: return false
            }
        }
        currentSegmentID = nil
    }

    /// Re-register a segment whose audio an earlier run left on disk
    /// (pickup), so it uploads with the session and the next recording of
    /// its base id continues at the following chunk number.
    func adopt(_ segment: Segment) {
        let (baseID, chunk) = Self.parseSegmentID(segment.segmentID)
        chunkCounters[baseID] = max(chunkCounters[baseID, default: 0], chunk)
        segments.append(segment)
    }

    // MARK: - Recording results

    /// The transcript of a recorded segment, nil when unknown or empty.
    func transcript(forSegmentID id: String) -> String? {
        guard let segment = segments.first(where: { $0.segmentID == id }) else { return nil }
        let text: String
        switch segment {
        case .calendarEvent(let s):  text = s.transcript
        case .voiceNote(let s):      text = s.transcript
        case .freeReflection(let s): text = s.transcript
        case .emptyBlock(let s):     text = s.transcript
        case .generalSection(let s): text = s.transcript
        }
        return text.isEmpty ? nil : text
    }

    /// Write a finished transcription onto its segment. Only calendar
    /// events carry todos; voice-note and empty-block segments keep what
    /// they have. A segment dropped or merged away meanwhile is ignored.
    func recordTranscript(segmentID: String, text: String, language: String, todos: [Todo]) {
        guard let idx = segments.firstIndex(where: { $0.segmentID == segmentID }) else { return }
        switch segments[idx] {
        case .calendarEvent(var segment):
            segment.transcript = text
            segment.todos_detected = todos
            segment.language = language
            segments[idx] = .calendarEvent(segment)
        case .freeReflection(var segment):
            segment.transcript = text
            segment.language = language
            segments[idx] = .freeReflection(segment)
        case .generalSection(var segment):
            segment.transcript = text
            segment.language = language
            segments[idx] = .generalSection(segment)
        case .voiceNote, .emptyBlock:
            break
        }
    }

    func recordPrompt(role: String, segmentID: String?, text: String) {
        aiPrompts.append(AiPrompt(
            at: ISO8601DateFormatter().string(from: Date()),
            role: role,
            segment_id: segmentID,
            text: text
        ))
    }

    func recordTodoConfirmed(_ todo: Todo) {
        confirmedTodos.append(todo)
    }

    func recordTodoRejected(text: String, sourceSegmentID: String?) {
        rejectedTodos.append(TodoRejected(text: text, source_segment_id: sourceSegmentID))
    }

    // MARK: - Voice notes

    /// Attach each surfaced note as its own `drive_by` segment, copying its
    /// audio into the bundle so the upload is self-contained. Notes whose
    /// seed id is in `excluded` (deferred or discarded in review) are
    /// skipped, and so are notes whose copy fails. Replaces
    /// `surfacedNoteIDs` with the notes attached by this call.
    func attachVoiceNotes(_ notes: [VoiceNote], excluding excluded: Set<String>) {
        var surfaced: [String] = []
        for note in notes where !excluded.contains(note.seed_id) {
            let copyPath = "segments/seed_\(Self.sanitize(note.seed_id)).m4a"
            let copyURL = directory.appending(path: copyPath)
            do {
                try FileManager.default.copyItem(at: note.audio_file_url, to: copyURL)
            } catch {
                Log.app.warning(
                    "note copy failed (\(note.seed_id, privacy: .public)): \(String(describing: error), privacy: .public)"
                )
                continue
            }
            protect(copyURL)
            segments.append(.voiceNote(VoiceNoteSegment(
                segment_id: "db_\(Self.sanitize(note.seed_id))",
                captured_at: ISO8601DateFormatter().string(from: note.captured_at),
                audio_file: copyPath,
                transcript: note.transcript,
                language: note.language,
                seed_id: note.seed_id
            )))
            surfaced.append(note.seed_id)
        }
        surfacedNoteIDs = surfaced
    }

    /// The closing reflection was skipped: its notes must stay unsurfaced.
    func clearSurfacedNotes() {
        surfacedNoteIDs = []
    }

    // MARK: - Finalizing

    /// Merge each base id's chunks into one file, write the manifest
    /// snapshot into the bundle directory and return what to upload. The
    /// files are derived from the segments, so the manifest `audio_file`
    /// keys and the upload keys are the same set by construction. Chunks
    /// stay on disk during recording for crash safety; this is the
    /// consolidation step.
    func finalize(date: String, responseLanguage: String) async -> UploadBundle {
        await mergeChunks()
        let manifest = Manifest(
            session_id: sessionID,
            date: date,
            audio_codec: AudioCodec(
                codec: "aac-lc",
                sample_rate: reportedSampleRate(),
                channels: 1,
                bitrate: 64_000
            ),
            segments: segments,
            todos_implicit_confirmed: confirmedTodos,
            todos_implicit_rejected: rejectedTodos,
            drive_by_seeds_surfaced: surfacedNoteIDs,
            ai_prompts: aiPrompts,
            response_language_setting: responseLanguage
        )
        do { try LocalStore.writeManifest(manifest, to: directory) }
        catch { Log.app.warning("manifest snapshot failed: \(String(describing: error), privacy: .public)") }
        let files = Dictionary(
            segments.map { ($0.audioFile, directory.appending(path: $0.audioFile)) },
            uniquingKeysWith: { first, _ in first }
        )
        return UploadBundle(manifest: manifest, files: files)
    }

    /// The first recorded rate. Chunks of one session share the audio
    /// session configuration, so a difference is unexpected and is logged.
    private func reportedSampleRate() -> Int {
        guard let first = sampleRates.first else { return Self.defaultSampleRate }
        if sampleRates.contains(where: { $0 != first }) {
            Log.audio.warning(
                "session \(self.sessionID, privacy: .public) recorded at differing sample rates \(self.sampleRates, privacy: .public) — reporting \(first, privacy: .public)"
            )
        }
        return Int(first.rounded())
    }

    // MARK: - Chunk merge

    private static func isChunkable(_ segment: Segment) -> Bool {
        switch segment {
        case .calendarEvent, .freeReflection, .generalSection: return true
        case .voiceNote, .emptyBlock: return false
        }
    }

    /// Fold contiguous same-base chunks (`s01e02`, `s01e02c2`, ...) into one
    /// segment each. Best-effort: when a group fails to merge its chunks
    /// stay as they are so the session still uploads.
    private func mergeChunks() async {
        var merged: [Segment] = []
        var i = 0
        while i < segments.count {
            let head = segments[i]
            guard Self.isChunkable(head) else {
                merged.append(head)
                i += 1
                continue
            }
            let baseID = Self.parseSegmentID(head.segmentID).baseID
            var j = i + 1
            while j < segments.count,
                  Self.isChunkable(segments[j]),
                  Self.parseSegmentID(segments[j].segmentID).baseID == baseID {
                j += 1
            }
            let group = Array(segments[i..<j])
            if group.count > 1, let single = await mergeGroup(group, baseID: baseID) {
                merged.append(single)
            } else {
                merged.append(contentsOf: group)
            }
            i = j
        }
        segments = merged
    }

    /// One merged segment for a group of chunks sharing `baseID`, nil when
    /// the merge failed (nothing is changed on disk then).
    ///
    /// The output path is `segments/<baseID>.m4a`, which the first chunk
    /// already occupies, so the merge is staged under `<baseID>.tmp.m4a` in
    /// the same directory: the move into place is an atomic rename, and a
    /// crash before it leaves an orphan temp that `M4AWriter.cleanupOrphans`
    /// reaps and the pickup loader skips.
    private func mergeGroup(_ group: [Segment], baseID: String) async -> Segment? {
        let chunkURLs = group.map { directory.appending(path: $0.audioFile) }
        let outputPath = Self.mediaPath(for: baseID)
        let outputURL = directory.appending(path: outputPath)
        let tempURL = directory.appending(path: "segments/\(baseID).tmp.m4a")
        let fm = FileManager.default
        try? fm.removeItem(at: tempURL)
        do {
            try await audio.merge(chunks: chunkURLs, into: tempURL)
        } catch {
            Log.audio.warning(
                "merge: \(baseID, privacy: .public) failed: \(String(describing: error), privacy: .public)"
            )
            try? fm.removeItem(at: tempURL)
            return nil
        }
        // The merged data now exists only in the temp file, so clear the
        // first chunk's path and move it into place before deleting more.
        do {
            if fm.fileExists(atPath: outputURL.path) { try fm.removeItem(at: outputURL) }
            try fm.moveItem(at: tempURL, to: outputURL)
        } catch {
            Log.audio.warning(
                "merge: \(baseID, privacy: .public) move-into-place failed: \(String(describing: error), privacy: .public)"
            )
            try? fm.removeItem(at: tempURL)
            return nil
        }
        protect(outputURL)
        // The first chunk's file was replaced by the move; delete the rest.
        for url in chunkURLs.dropFirst() { try? fm.removeItem(at: url) }

        guard let merged = Self.mergedSegment(group, baseID: baseID, audioFile: outputPath) else {
            return nil
        }
        Log.audio.info(
            "merge: \(baseID, privacy: .public) consolidated \(group.count, privacy: .public) chunks"
        )
        return merged
    }

    /// The segment record of a merged group: the first chunk's shape with
    /// the base id, the merged file, the chunks' transcripts joined (empty
    /// pieces skipped), the first non-empty language, and, for calendar
    /// events, every chunk's todos and linked seeds.
    private static func mergedSegment(_ group: [Segment], baseID: String, audioFile: String) -> Segment? {
        func transcript(_ segment: Segment) -> String? {
            switch segment {
            case .calendarEvent(let v):  return v.transcript
            case .freeReflection(let v): return v.transcript
            case .generalSection(let v): return v.transcript
            default: return nil
            }
        }
        func language(_ segment: Segment) -> String? {
            switch segment {
            case .calendarEvent(let v):  return v.language
            case .freeReflection(let v): return v.language
            case .generalSection(let v): return v.language
            default: return nil
            }
        }
        let mergedTranscript = group
            .compactMap(transcript)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let mergedLanguage = group.compactMap(language).first { !$0.isEmpty } ?? "de-DE"

        switch group.first {
        case .calendarEvent(var v):
            v.segment_id = baseID
            v.audio_file = audioFile
            v.transcript = mergedTranscript
            v.language = mergedLanguage
            v.todos_detected = group.flatMap { chunk -> [Todo] in
                if case .calendarEvent(let c) = chunk { return c.todos_detected }
                return []
            }
            v.linked_seed_ids = group.flatMap { chunk -> [String] in
                if case .calendarEvent(let c) = chunk { return c.linked_seed_ids }
                return []
            }
            return .calendarEvent(v)
        case .generalSection(var v):
            v.segment_id = baseID
            v.audio_file = audioFile
            v.transcript = mergedTranscript
            v.language = mergedLanguage
            return .generalSection(v)
        case .freeReflection(var v):
            v.segment_id = baseID
            v.audio_file = audioFile
            v.transcript = mergedTranscript
            v.language = mergedLanguage
            return .freeReflection(v)
        default:
            return nil
        }
    }
}
