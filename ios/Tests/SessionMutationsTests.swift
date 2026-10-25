import Foundation
import Testing
@testable import VoiceDiary

// IOS-A15 / #8: the destructive edits behind the Verlauf screens, run on
// disposable temp directories with a recording fake for the upload-queue
// purge. The purge callback is the only stand-in for the real queue, so the
// order of file operations and purges is read straight off one event log.

@Suite("SessionMutations")
@MainActor
struct SessionMutationsTests {
    private struct Failure: Error {}

    private final class Log {
        var events: [String] = []
        var purges: Int { events.filter { $0 == "purge" }.count }
    }

    private func scratchDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "ios-a15-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func mutations(
        log: Log,
        removeFails: Bool = false,
        writeFails: Bool = false
    ) -> SessionMutations {
        SessionMutations(
            removeItem: { url in
                log.events.append("remove:\(url.lastPathComponent)")
                if removeFails { throw Failure() }
                try FileManager.default.removeItem(at: url)
            },
            writeMetadata: { data, url in
                log.events.append("write:\(url.lastPathComponent)")
                if writeFails { throw Failure() }
                try SessionMutations.writeVoiceNoteMetadata(data, to: url)
            },
            schedulePurge: { log.events.append("purge") }
        )
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    private func chunk(_ name: String, _ seconds: Double, _ lang: String, _ text: String) -> VoiceNoteChunk {
        VoiceNoteChunk(filename: name, duration_seconds: seconds, language: lang, transcript: text)
    }

    private func decodeMetadata(in dir: URL) throws -> VoiceNote {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(VoiceNote.self, from: Data(contentsOf: dir.appending(path: "metadata.json")))
    }

    /// A note directory with one m4a per chunk and a metadata.json that
    /// mirrors the first chunk, like `CaptureCoordinator` writes it.
    private func makeNote(
        chunks: [VoiceNoteChunk]?,
        in root: URL
    ) throws -> SessionHistoryStore.VoiceNoteEntry {
        let dir = root.appending(path: "2026-05-20T08-00-00", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let names = chunks?.map(\.filename) ?? ["audio.m4a"]
        for name in names { try Data("audio".utf8).write(to: dir.appending(path: name)) }
        let first = chunks?.first
        let note = VoiceNote(
            seed_id: "note-a15",
            captured_at: Date(timeIntervalSince1970: 1_780_000_000),
            duration_seconds: chunks?.reduce(0) { $0 + $1.duration_seconds } ?? 5,
            language: first?.language ?? "de",
            transcript: first?.transcript ?? "eins",
            audio_file_url: dir.appending(path: names[0]),
            chunks: chunks
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(note).write(to: dir.appending(path: "metadata.json"))
        return SessionHistoryStore.VoiceNoteEntry(note: note, directory: dir)
    }

    private func descriptor(_ id: String, audio: URL?) -> SegmentDescriptor {
        SegmentDescriptor(
            id: id, title: id, subtitle: nil, transcript: "", language: nil,
            audioURL: audio, serverStatus: nil
        )
    }

    private func makeWalkthrough(in root: URL) throws -> (SessionHistoryStore.WalkthroughEntry, [URL]) {
        let dir = root.appending(path: "2026-05-20", directoryHint: .isDirectory)
        let segments = dir.appending(path: "segments", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: segments, withIntermediateDirectories: true)
        let urls = ["s01.m4a", "s02.m4a", "s03.m4a"].map { segments.appending(path: $0) }
        for url in urls { try Data("audio".utf8).write(to: url) }
        let entry = SessionHistoryStore.WalkthroughEntry(
            sessionID: "2026-05-20", date: "2026-05-20",
            capturedAt: Date(timeIntervalSince1970: 1_780_000_000),
            manifest: nil, segmentURLs: urls, directory: dir
        )
        return (entry, urls)
    }

    // MARK: - Whole entry

    @Test("deleting a walkthrough entry removes its directory, then schedules one purge")
    func deleteWalkthroughEntry() throws {
        let root = try scratchDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let (entry, urls) = try makeWalkthrough(in: root)
        let log = Log()

        try mutations(log: log).deleteEntry(.walkthrough(entry))

        #expect(!exists(entry.directory))
        #expect(urls.allSatisfy { !exists($0) })
        #expect(log.events == ["remove:2026-05-20", "purge"])
    }

    @Test("deleting a note entry removes audio and metadata, then schedules one purge")
    func deleteNoteEntry() throws {
        let root = try scratchDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let note = try makeNote(chunks: nil, in: root)
        let log = Log()

        try mutations(log: log).deleteEntry(.voiceNote(note))

        #expect(!exists(note.directory))
        #expect(log.events == ["remove:2026-05-20T08-00-00", "purge"])
    }

    @Test("a failed entry removal throws and schedules no purge")
    func deleteEntryFailureThrows() throws {
        let root = try scratchDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let (entry, _) = try makeWalkthrough(in: root)
        let log = Log()

        #expect(throws: Failure.self) {
            try mutations(log: log, removeFails: true).deleteEntry(.walkthrough(entry))
        }

        #expect(exists(entry.directory))
        #expect(log.events == ["remove:2026-05-20"])
    }

    // MARK: - Multi-chunk note

    @Test("removing a middle chunk keeps the others and re-derives duration from the survivors")
    func multiChunkSurvivorMetadata() throws {
        let root = try scratchDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let entry = try makeNote(chunks: [
            chunk("audio.m4a", 2, "de", "eins"),
            chunk("audio_002.m4a", 3, "en", "two"),
            chunk("audio_003.m4a", 4, "de", "drei"),
        ], in: root)
        let log = Log()
        let target = entry.directory.appending(path: "audio_002.m4a")

        let outcome = mutations(log: log).deleteSegment(
            descriptor("audio_002.m4a", audio: target), in: .voiceNote(entry))

        #expect(outcome == .rowRemoved)
        #expect(!exists(target))
        #expect(exists(entry.directory.appending(path: "audio.m4a")))
        let saved = try decodeMetadata(in: entry.directory)
        #expect(saved.chunks?.map(\.filename) == ["audio.m4a", "audio_003.m4a"])
        #expect(saved.duration_seconds == 6)
        #expect(saved.language == "de")
        #expect(saved.transcript == "eins")
        #expect(saved.audio_file_url == entry.directory.appending(path: "audio.m4a"))
        #expect(log.events == ["remove:audio_002.m4a", "write:metadata.json", "purge"])
    }

    @Test("removing the first chunk promotes the next one to the note's own fields")
    func multiChunkFirstAudioUpdate() throws {
        let root = try scratchDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let entry = try makeNote(chunks: [
            chunk("audio.m4a", 2, "de", "eins"),
            chunk("audio_002.m4a", 3, "en", "two"),
            chunk("audio_003.m4a", 4, "en", "three"),
        ], in: root)
        let log = Log()
        let target = entry.directory.appending(path: "audio.m4a")

        _ = mutations(log: log).deleteSegment(
            descriptor("audio.m4a", audio: target), in: .voiceNote(entry))

        let saved = try decodeMetadata(in: entry.directory)
        #expect(saved.chunks?.map(\.filename) == ["audio_002.m4a", "audio_003.m4a"])
        #expect(saved.duration_seconds == 7)
        #expect(saved.language == "en")
        #expect(saved.transcript == "two")
        #expect(saved.audio_file_url == entry.directory.appending(path: "audio_002.m4a"))
    }

    @Test("one surviving chunk collapses the note back to a single-shot capture")
    func oneChunkCollapse() throws {
        let root = try scratchDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let entry = try makeNote(chunks: [
            chunk("audio.m4a", 2, "de", "eins"),
            chunk("audio_002.m4a", 3, "en", "two"),
        ], in: root)
        let log = Log()
        let target = entry.directory.appending(path: "audio.m4a")

        let outcome = mutations(log: log).deleteSegment(
            descriptor("audio.m4a", audio: target), in: .voiceNote(entry))

        #expect(outcome == .rowRemoved)
        let saved = try decodeMetadata(in: entry.directory)
        #expect(saved.chunks == nil)
        #expect(saved.duration_seconds == 3)
        #expect(saved.language == "en")
        #expect(saved.transcript == "two")
        #expect(saved.audio_file_url == entry.directory.appending(path: "audio_002.m4a"))
        #expect(exists(entry.directory.appending(path: "audio_002.m4a")))
    }

    // The view stops playback itself and asks this to decide how widely.
    @Test("only a single-chunk note's row, or a chunk without audio, takes the whole entry with it")
    func removesWholeEntryDecision() throws {
        let root = try scratchDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let multi = try makeNote(chunks: [
            chunk("audio.m4a", 2, "de", "eins"),
            chunk("audio_002.m4a", 3, "de", "zwei"),
        ], in: root.appending(path: "multi", directoryHint: .isDirectory))
        let single = try makeNote(chunks: nil, in: root.appending(path: "single", directoryHint: .isDirectory))
        let (walkthrough, urls) = try makeWalkthrough(in: root)
        let sut = mutations(log: Log())

        let chunkRow = descriptor("audio_002.m4a", audio: multi.directory.appending(path: "audio_002.m4a"))
        #expect(!sut.removesWholeEntry(chunkRow, in: .voiceNote(multi)))
        #expect(sut.removesWholeEntry(descriptor("audio_002.m4a", audio: nil), in: .voiceNote(multi)))
        #expect(sut.removesWholeEntry(
            descriptor("audio.m4a", audio: single.directory.appending(path: "audio.m4a")),
            in: .voiceNote(single)))
        #expect(!sut.removesWholeEntry(descriptor("s01.m4a", audio: urls[0]), in: .walkthrough(walkthrough)))
    }

    // Two chunks sharing a file name is the only way a multi-chunk note can
    // lose every chunk to one removal: the metadata rewrite then finds no
    // survivor and takes the whole note with it.
    @Test("a removal that leaves no chunk deletes the whole note, purges once and asks to dismiss")
    func noSurvivorsRemovesEntry() throws {
        let root = try scratchDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let entry = try makeNote(chunks: [
            chunk("audio.m4a", 2, "de", "eins"),
            chunk("audio.m4a", 3, "de", "zwei"),
        ], in: root)
        let log = Log()

        let outcome = mutations(log: log).deleteSegment(
            descriptor("audio.m4a", audio: entry.directory.appending(path: "audio.m4a")),
            in: .voiceNote(entry))

        #expect(outcome == .entryRemoved)
        #expect(!exists(entry.directory))
        #expect(log.events == ["remove:audio.m4a", "remove:2026-05-20T08-00-00", "purge"])
    }

    @Test("a failed whole-note removal for a single-chunk note is swallowed, still purges and asks to dismiss")
    func singleChunkRemovalFailureSwallowed() throws {
        let root = try scratchDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let entry = try makeNote(chunks: nil, in: root)
        let log = Log()

        let outcome = mutations(log: log, removeFails: true).deleteSegment(
            descriptor("audio.m4a", audio: entry.directory.appending(path: "audio.m4a")),
            in: .voiceNote(entry))

        #expect(outcome == .entryRemoved)
        #expect(exists(entry.directory))
        #expect(log.events == ["remove:2026-05-20T08-00-00", "purge"])
    }

    @Test("a failed file removal or metadata write is swallowed, and the purge still follows")
    func multiChunkFailuresAreSwallowed() throws {
        let root = try scratchDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let entry = try makeNote(chunks: [
            chunk("audio.m4a", 2, "de", "eins"),
            chunk("audio_002.m4a", 3, "de", "zwei"),
        ], in: root)
        let target = entry.directory.appending(path: "audio_002.m4a")

        let removeLog = Log()
        let removeOutcome = mutations(log: removeLog, removeFails: true).deleteSegment(
            descriptor("audio_002.m4a", audio: target), in: .voiceNote(entry))
        #expect(removeOutcome == .rowRemoved)
        #expect(exists(target))
        #expect(removeLog.events == ["remove:audio_002.m4a", "write:metadata.json", "purge"])

        let before = try Data(contentsOf: entry.directory.appending(path: "metadata.json"))
        let writeLog = Log()
        let writeOutcome = mutations(log: writeLog, writeFails: true).deleteSegment(
            descriptor("audio_002.m4a", audio: target), in: .voiceNote(entry))
        #expect(writeOutcome == .rowRemoved)
        #expect(try Data(contentsOf: entry.directory.appending(path: "metadata.json")) == before)
        #expect(writeLog.events == ["remove:audio_002.m4a", "write:metadata.json", "purge"])
    }

    // MARK: - Single-chunk note

    @Test("the only row of a single-chunk note deletes the note and asks to dismiss")
    func singleChunkNoteIsWholeEntry() throws {
        let root = try scratchDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let entry = try makeNote(chunks: nil, in: root)
        let log = Log()

        let outcome = mutations(log: log).deleteSegment(
            descriptor("audio.m4a", audio: entry.directory.appending(path: "audio.m4a")),
            in: .voiceNote(entry))

        #expect(outcome == .entryRemoved)
        #expect(!exists(entry.directory))
        #expect(log.events == ["remove:2026-05-20T08-00-00", "purge"])
    }

    // MARK: - Walkthrough segment and surfaced note

    @Test("a walkthrough segment removes only its audio file, then schedules one purge")
    func walkthroughSegment() throws {
        let root = try scratchDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let (entry, urls) = try makeWalkthrough(in: root)
        let log = Log()

        let outcome = mutations(log: log).deleteSegment(
            descriptor("s02.m4a", audio: urls[1]), in: .walkthrough(entry))

        #expect(outcome == .rowRemoved)
        #expect(!exists(urls[1]))
        #expect(exists(urls[0]) && exists(urls[2]))
        #expect(log.events == ["remove:s02.m4a", "purge"])
    }

    @Test("a walkthrough segment without audio only schedules the purge")
    func walkthroughSegmentWithoutAudio() throws {
        let root = try scratchDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let (entry, urls) = try makeWalkthrough(in: root)
        let log = Log()

        let outcome = mutations(log: log).deleteSegment(
            descriptor("gone", audio: nil), in: .walkthrough(entry))

        #expect(outcome == .rowRemoved)
        #expect(urls.allSatisfy { exists($0) })
        #expect(log.events == ["purge"])
    }

    @Test("a failed walkthrough segment removal is swallowed and the purge still follows")
    func walkthroughSegmentFailureSwallowed() throws {
        let root = try scratchDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let (entry, urls) = try makeWalkthrough(in: root)
        let log = Log()

        let outcome = mutations(log: log, removeFails: true).deleteSegment(
            descriptor("s01.m4a", audio: urls[0]), in: .walkthrough(entry))

        #expect(outcome == .rowRemoved)
        #expect(exists(urls[0]))
        #expect(log.events == ["remove:s01.m4a", "purge"])
    }

    @Test("a surfaced note removes its whole directory, then schedules one purge")
    func surfacedNote() throws {
        let root = try scratchDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let entry = try makeNote(chunks: nil, in: root)
        let audio = entry.directory.appending(path: "audio.m4a")
        let log = Log()

        mutations(log: log).deleteSurfacedNote(SurfacedNoteEntry(note: entry.note, audioURL: audio))

        #expect(!exists(entry.directory))
        #expect(log.events == ["remove:2026-05-20T08-00-00", "purge"])
    }

    @Test("a failed surfaced-note removal is swallowed and the purge still follows")
    func surfacedNoteFailureSwallowed() throws {
        let root = try scratchDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let entry = try makeNote(chunks: nil, in: root)
        let log = Log()

        mutations(log: log, removeFails: true).deleteSurfacedNote(
            SurfacedNoteEntry(note: entry.note, audioURL: entry.directory.appending(path: "audio.m4a")))

        #expect(exists(entry.directory))
        #expect(log.events == ["remove:2026-05-20T08-00-00", "purge"])
    }
}
