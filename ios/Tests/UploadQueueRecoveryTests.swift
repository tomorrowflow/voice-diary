import Foundation
import Testing
@testable import VoiceDiary

// A queued session whose audio files are partly gone keeps its surviving
// segments (IOS-A4, #4): only the missing file and its manifest segment are
// pruned, the entry is marked partial, and the survivors upload. Covers the
// pure recovery rule plus `purgeOrphans` and `flush` on a real queue file
// in a temp directory, with the upload stubbed.

@Suite("SessionUploader missing-file recovery")
struct UploadQueueRecoveryTests {
    private let sessionID = "2026-04-27T19:30:00+02:00"
    private let ids = ["s01", "s02", "s03"]

    private func field(_ id: String) -> String { "segments/\(id).m4a" }

    private func makeDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "vd-queue-recovery-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: dir.appending(path: "segments"), withIntermediateDirectories: true
        )
        return dir
    }

    /// An entry over `ids` with every audio file written under `dir`, then
    /// the files in `missing` removed again.
    private func makeEntry(in dir: URL, missing: Set<String> = []) throws -> SessionUploader.QueueEntry {
        var paths: [String: String] = [:]
        var segments: [Segment] = []
        for id in ids {
            let url = dir.appending(path: field(id))
            try Data("audio-\(id)".utf8).write(to: url)
            if missing.contains(id) { try FileManager.default.removeItem(at: url) }
            paths[field(id)] = url.path
            segments.append(.voiceNote(VoiceNoteSegment(
                segment_id: id, captured_at: "2026-04-27T19:31:00+02:00", audio_file: field(id)
            )))
        }
        return SessionUploader.QueueEntry(
            id: sessionID,
            manifest: Manifest(session_id: sessionID, date: "2026-04-27", segments: segments),
            audio_file_paths: paths,
            attempts: 2,
            next_attempt_at: Date(timeIntervalSince1970: 0),
            last_failure_code: "whisper_unavailable"
        )
    }

    private func segmentIDs(_ entry: SessionUploader.QueueEntry) -> [String] {
        entry.manifest.segments.map { segment in
            switch segment {
            case .voiceNote(let v): return v.segment_id
            default: return "?"
            }
        }
    }

    private func seed(_ entries: [SessionUploader.QueueEntry], in dir: URL) throws -> URL {
        let file = dir.appending(path: "upload_queue.json")
        try JSONEncoder().encode(entries).write(to: file)
        return file
    }

    // --- pure rule -----------------------------------------------------

    @Test("one missing file among several prunes only that file and its segment")
    func prunesOnlyTheMissingSegment() throws {
        let dir = try makeDir()
        let entry = try makeEntry(in: dir, missing: ["s02"])
        guard case .pruned(let pruned, let missing, let lostIDs) = entry.recoveringFromMissingFiles(
            fileExists: { FileManager.default.fileExists(atPath: $0) }
        ) else {
            Issue.record("expected a pruned entry")
            return
        }
        #expect(missing == [field("s02")])
        #expect(lostIDs == ["s02"])
        #expect(segmentIDs(pruned) == ["s01", "s03"])
        #expect(Set(pruned.audio_file_paths.keys) == [field("s01"), field("s03")])
        #expect(pruned.partial)
        // Schedule, failure history and identity are untouched.
        #expect(pruned.id == entry.id)
        #expect(pruned.attempts == entry.attempts)
        #expect(pruned.next_attempt_at == entry.next_attempt_at)
        #expect(pruned.last_failure_code == entry.last_failure_code)
        #expect(pruned.permanentlyFailed == false)
    }

    @Test("an entry with all its files is left alone and not partial")
    func intactEntryIsUntouched() throws {
        let entry = try makeEntry(in: try makeDir())
        guard case .intact = entry.recoveringFromMissingFiles(
            fileExists: { FileManager.default.fileExists(atPath: $0) }
        ) else {
            Issue.record("expected an intact entry")
            return
        }
    }

    @Test("a missing file no segment refers to is dropped without marking the entry partial")
    func strayFileDoesNotMakePartial() throws {
        var entry = try makeEntry(in: try makeDir())
        entry.audio_file_paths["segments/stray.m4a"] = "/nonexistent/stray.m4a"
        guard case .pruned(let pruned, _, let lostIDs) = entry.recoveringFromMissingFiles(
            fileExists: { FileManager.default.fileExists(atPath: $0) }
        ) else {
            Issue.record("expected a pruned entry")
            return
        }
        #expect(pruned.partial == false)
        #expect(lostIDs.isEmpty)
        #expect(segmentIDs(pruned) == ids)
        #expect(pruned.audio_file_paths["segments/stray.m4a"] == nil)
    }

    @Test("an entry with no surviving segment is unrecoverable")
    func allMissingIsUnrecoverable() throws {
        let entry = try makeEntry(in: try makeDir(), missing: Set(ids))
        guard case .unrecoverable(let missing, let lostIDs) = entry.recoveringFromMissingFiles(
            fileExists: { FileManager.default.fileExists(atPath: $0) }
        ) else {
            Issue.record("expected an unrecoverable entry")
            return
        }
        #expect(lostIDs == ids)
        #expect(missing == Set(ids.map(field)))
    }

    @Test("partial survives a JSON round trip and defaults to false in old queue files")
    func partialRoundTrip() throws {
        var entry = try makeEntry(in: try makeDir())
        entry.partial = true
        let decoded = try JSONDecoder().decode(
            [SessionUploader.QueueEntry].self, from: JSONEncoder().encode([entry])
        )
        #expect(decoded.first?.partial == true)

        var json = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode([entry])) as? [[String: Any]]
        )
        json[0].removeValue(forKey: "partial")
        let old = try JSONDecoder().decode(
            [SessionUploader.QueueEntry].self, from: JSONSerialization.data(withJSONObject: json)
        )
        #expect(old.first?.partial == false)
    }

    // --- purgeOrphans --------------------------------------------------

    @Test("purgeOrphans keeps the surviving segments, marks the entry partial and persists it")
    func purgeKeepsSurvivors() async throws {
        let dir = try makeDir()
        let file = try seed([try makeEntry(in: dir, missing: ["s02"])], in: dir)
        let uploader = SessionUploader(queueFile: { file }, upload: UploadLog().upload)

        let dropped = await uploader.purgeOrphans()

        #expect(dropped == 0)
        let pending = await uploader.pending()
        #expect(pending.count == 1)
        #expect(segmentIDs(pending[0]) == ["s01", "s03"])
        #expect(pending[0].partial)
        // Persisted: a fresh uploader over the same file sees the pruned entry.
        let reloaded = await SessionUploader(queueFile: { file }, upload: UploadLog().upload).pending()
        #expect(segmentIDs(reloaded[0]) == ["s01", "s03"])
        #expect(reloaded[0].partial)
    }

    @Test("purgeOrphans still drops an entry when every file is gone")
    func purgeDropsEmptyEntry() async throws {
        let dir = try makeDir()
        let file = try seed([try makeEntry(in: dir, missing: Set(ids))], in: dir)
        let uploader = SessionUploader(queueFile: { file }, upload: UploadLog().upload)

        #expect(await uploader.purgeOrphans() == 1)
        #expect(await uploader.pending().isEmpty)
    }

    // --- flush / retry -------------------------------------------------

    @Test("flush uploads only the surviving segments and files, then dequeues the entry")
    func flushUploadsSurvivors() async throws {
        let dir = try makeDir()
        let file = try seed([try makeEntry(in: dir, missing: ["s02"])], in: dir)
        let log = UploadLog()
        let uploader = SessionUploader(queueFile: { file }, upload: log.upload)

        await uploader.flush()

        let calls = await log.calls
        #expect(calls.count == 1)
        #expect(calls[0].segmentIDs == ["s01", "s03"])
        #expect(calls[0].fields == [field("s01"), field("s03")])
        #expect(await uploader.pending().isEmpty)
    }

    @Test("a failed upload keeps the pruned partial entry and the retry uploads the same survivors")
    func retryUsesPrunedEntry() async throws {
        let dir = try makeDir()
        let file = try seed([try makeEntry(in: dir, missing: ["s02"])], in: dir)
        let log = UploadLog()
        await log.failNext(ServerClientError.notConfigured)
        let uploader = SessionUploader(queueFile: { file }, upload: log.upload)

        await uploader.flush()

        // Nothing went out, but the queue already holds the pruned entry.
        #expect(await log.calls.count == 1)
        let waiting = await uploader.pending()
        #expect(waiting.count == 1)
        #expect(segmentIDs(waiting[0]) == ["s01", "s03"])
        #expect(waiting[0].partial)

        await uploader.flush()

        let calls = await log.calls
        #expect(calls.count == 2)
        #expect(calls[1].segmentIDs == ["s01", "s03"])
        #expect(await uploader.pending().isEmpty)
    }

    @Test("a backed-off retry keeps the entry partial with its survivors")
    func backoffKeepsPartial() async throws {
        let dir = try makeDir()
        let file = try seed([try makeEntry(in: dir, missing: ["s01"])], in: dir)
        let log = UploadLog()
        await log.failNext(ServerClientError.http(status: 503, detail: "down"))
        let uploader = SessionUploader(queueFile: { file }, upload: log.upload)

        await uploader.flush()

        let waiting = await uploader.pending()
        #expect(waiting.count == 1)
        #expect(waiting[0].partial)
        #expect(waiting[0].attempts == 3)
        #expect(segmentIDs(waiting[0]) == ["s02", "s03"])
        #expect(Set(waiting[0].audio_file_paths.keys) == [field("s02"), field("s03")])
    }

    // --- diagnostics and manifest -----------------------------------------

    @Test("pruning writes one Diag line naming the session and the pruned segment ids, once")
    func pruneIsLoggedOnce() async throws {
        let dir = try makeDir()
        let file = try seed([try makeEntry(in: dir, missing: ["s02"])], in: dir)
        let lines = DiagLines()
        let uploader = SessionUploader(queueFile: { file }, upload: UploadLog().upload, diag: lines.record)

        await uploader.purgeOrphans()
        await uploader.flush()   // the entry is already pruned: nothing new to say

        let logged = lines.all
        #expect(logged.count == 1)
        #expect(logged[0].session == sessionID)
        #expect(logged[0].message.contains("segments=[s02]"))
        #expect(logged[0].message.contains(field("s02")))
        #expect(logged[0].message.contains("kept=2"))
    }

    @Test("flush logs the pruning too, even though the upload then dequeues the entry")
    func flushPruneIsLogged() async throws {
        let dir = try makeDir()
        let file = try seed([try makeEntry(in: dir, missing: ["s01", "s03"])], in: dir)
        let lines = DiagLines()
        let uploader = SessionUploader(queueFile: { file }, upload: UploadLog().upload, diag: lines.record)

        await uploader.flush()

        #expect(await uploader.pending().isEmpty)
        let logged = lines.all
        #expect(logged.count == 1)
        #expect(logged[0].message.contains("segments=[s01, s03]"))
    }

    @Test("dropping an entry with nothing left is logged with all its segment ids")
    func dropIsLogged() async throws {
        let dir = try makeDir()
        let file = try seed([try makeEntry(in: dir, missing: Set(ids))], in: dir)
        let lines = DiagLines()
        let uploader = SessionUploader(queueFile: { file }, upload: UploadLog().upload, diag: lines.record)

        await uploader.purgeOrphans()

        let logged = lines.all
        #expect(logged.count == 1)
        #expect(logged[0].session == sessionID)
        #expect(logged[0].message.contains("upload.dropped"))
        #expect(logged[0].message.contains("segments=[s01, s02, s03]"))
    }

    @Test("an intact entry writes no Diag line")
    func intactIsSilent() async throws {
        let dir = try makeDir()
        let file = try seed([try makeEntry(in: dir)], in: dir)
        let lines = DiagLines()
        let uploader = SessionUploader(queueFile: { file }, upload: UploadLog().upload, diag: lines.record)

        await uploader.purgeOrphans()
        await uploader.flush()

        #expect(lines.all.isEmpty)
    }

    @Test("the manifest that is sent carries only the survivors and no partial marker")
    func sentManifestHasNoPartialMarker() async throws {
        let dir = try makeDir()
        let file = try seed([try makeEntry(in: dir, missing: ["s02"])], in: dir)
        let log = UploadLog()
        let uploader = SessionUploader(queueFile: { file }, upload: log.upload)

        await uploader.flush()

        let sent = try #require(await log.manifests.first)
        let json = try #require(String(data: JSONEncoder().encode(sent), encoding: .utf8))
        #expect(!json.contains("partial"))
        #expect(!json.contains("s02"))
        #expect(json.contains("s01") && json.contains("s03"))
    }

    @Test("flush still drops an entry whose files are all gone and goes on to the next one")
    func flushDropsEmptyEntryAndContinues() async throws {
        let dir = try makeDir()
        var gone = try makeEntry(in: dir, missing: Set(ids))
        gone.id = "gone"
        gone.manifest.session_id = "gone"
        let alive = try makeEntry(in: try makeDir())
        let file = try seed([gone, alive], in: dir)
        let log = UploadLog()
        let uploader = SessionUploader(queueFile: { file }, upload: log.upload)

        await uploader.flush()

        let calls = await log.calls
        #expect(calls.count == 1)
        #expect(calls[0].sessionID == sessionID)
        #expect(await uploader.pending().isEmpty)
    }
}

/// Stub for the uploader's diagnostics seam; records the lines it was given.
/// Synchronous, so a line is there as soon as the uploader call returns.
private final class DiagLines: @unchecked Sendable {
    struct Line {
        let session: String
        let message: String
    }

    private let lock = NSLock()
    private var lines: [Line] = []

    var all: [Line] { lock.withLock { lines } }

    var record: @Sendable (String, String) -> Void {
        { session, message in self.lock.withLock { self.lines.append(Line(session: session, message: message)) } }
    }
}

/// Stub for the uploader's network seam; records what would have been sent.
private actor UploadLog {
    struct Call: Sendable {
        let sessionID: String
        let segmentIDs: [String]
        let fields: [String]
    }

    private(set) var calls: [Call] = []
    private(set) var manifests: [Manifest] = []
    private var failure: (any Error)?

    func failNext(_ error: any Error) { failure = error }

    nonisolated var upload: @Sendable (Manifest, [String: URL]) async throws -> SessionAccepted {
        { manifest, files in try await self.record(manifest, files) }
    }

    private func record(_ manifest: Manifest, _ files: [String: URL]) throws -> SessionAccepted {
        let ids = manifest.segments.map { segment -> String in
            if case .voiceNote(let v) = segment { return v.segment_id }
            return "?"
        }
        manifests.append(manifest)
        calls.append(Call(sessionID: manifest.session_id, segmentIDs: ids, fields: files.keys.sorted()))
        if let failure {
            self.failure = nil
            throw failure
        }
        return SessionAccepted(
            status: "accepted",
            session_id: manifest.session_id,
            received_at: "2026-04-27T19:40:00+02:00",
            processing_status_url: "",
            segments: []
        )
    }
}
