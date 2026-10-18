import Foundation
import Testing
@testable import VoiceDiary

// IOS-SB-46 / #46: the session bundle owns the walkthrough's audio files and
// manifest. IOS-SB-47 / #47: it also journals its state so a reopened bundle
// restores pickup. Everything runs against a temporary root and a fake audio
// adapter, so no audio engine or AVFoundation export is involved.

/// Merges by concatenating the chunk files, or fails on demand, and reports
/// the scripted sample rates one per `sampleRate()` call (the last repeats).
private final class FakeBundleAudio: SessionBundleAudio, @unchecked Sendable {
    private let lock = NSLock()
    private var rates: [Double]
    private var _mergeCalls: [[String]] = []
    let failMerge: Bool
    /// The merge reports success but writes no output file, so moving the
    /// result into place fails.
    let skipOutput: Bool

    init(rates: [Double] = [48_000], failMerge: Bool = false, skipOutput: Bool = false) {
        self.rates = rates
        self.failMerge = failMerge
        self.skipOutput = skipOutput
    }

    var mergeCalls: [[String]] { lock.withLock { _mergeCalls } }

    func merge(chunks: [URL], into output: URL) async throws {
        lock.withLock { _mergeCalls.append(chunks.map(\.lastPathComponent)) }
        if failMerge { throw CocoaError(.fileWriteUnknown) }
        if skipOutput { return }
        var merged = Data()
        for chunk in chunks { merged.append(try Data(contentsOf: chunk)) }
        try merged.write(to: output)
    }

    func sampleRate() async -> Double {
        lock.withLock { rates.count > 1 ? rates.removeFirst() : (rates.first ?? 0) }
    }
}

private struct CaptureFailure: Error {}

/// A journal disk that rejects writes while `failing` and counts attempts.
@MainActor
private final class FlakyDisk {
    var failing = true
    var attempts = 0
}

@Suite("SessionBundle")
@MainActor
struct SessionBundleTests {

    // MARK: - Fixtures

    private func scratchRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "sb46-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeBundle(
        root: URL,
        audio: FakeBundleAudio = FakeBundleAudio(),
        protect: @escaping SessionBundle.Protector = { LocalStore.applyProtection(to: $0) }
    ) throws -> SessionBundle {
        try SessionBundle.create(
            in: root,
            sessionID: "2026-10-18T20:15:00+02:00",
            audio: audio,
            protect: protect
        )
    }

    private let calendarRef = CalendarRef(
        graph_event_id: "evt-1", title: "Planning", start: "2026-10-18T09:00:00", end: "2026-10-18T10:00:00"
    )

    private func event(_ baseID: String = "s01e02") -> SessionBundle.Kind {
        .event(baseID: baseID, calendarRef: calendarRef)
    }

    /// A capture that writes `payload` into the file it is handed.
    private func writing(_ payload: String) -> SessionBundle.Capture {
        { url in try Data(payload.utf8).write(to: url) }
    }

    private func makeVoiceNote(_ seedID: String, in dir: URL, transcript: String = "note") throws -> VoiceNote {
        let audio = dir.appending(path: "src-\(UUID().uuidString).m4a")
        try Data("audio-\(seedID)".utf8).write(to: audio)
        return VoiceNote(
            seed_id: seedID,
            captured_at: Date(timeIntervalSince1970: 1_760_000_000),
            duration_seconds: 4,
            language: "de",
            transcript: transcript,
            audio_file_url: audio
        )
    }

    private func audioFiles(of manifest: Manifest) -> Set<String> {
        Set(manifest.segments.map(\.audioFile))
    }

    // MARK: - record

    @Test("a successful record allocates the protected path, runs the capture and records the segment")
    func successfulRecord() async throws {
        let root = try scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = try makeBundle(root: root)

        try await bundle.record(event(), capture: writing("A"))

        #expect(bundle.currentSegmentID == "s01e02")
        #expect(bundle.segments.map(\.segmentID) == ["s01e02"])
        #expect(bundle.segments.first?.audioFile == "segments/s01e02.m4a")
        let url = try #require(bundle.audioURL(forSegmentID: "s01e02"))
        #expect(url == bundle.directory.appending(path: "segments/s01e02.m4a"))
        #expect(try Data(contentsOf: url) == Data("A".utf8))
        guard case .calendarEvent(let segment) = bundle.segments[0] else {
            Issue.record("expected a calendar event segment")
            return
        }
        #expect(segment.calendar_ref.graph_event_id == "evt-1")
    }

    @Test("general and reflection kinds record their own segment shapes")
    func otherKinds() async throws {
        let root = try scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = try makeBundle(root: root)
        let section = GeneralSection(id: "sec-1", title: "Wins", introText: "Was lief gut?")

        try await bundle.record(.general(baseID: "s01", section: section), capture: writing("G"))
        _ = bundle.finishCurrent()
        try await bundle.record(.reflection(baseID: "s02"), capture: writing("R"))

        guard case .generalSection(let general) = bundle.segments[0],
              case .freeReflection(let reflection) = bundle.segments[1] else {
            Issue.record("unexpected segment kinds: \(bundle.segments.map(\.segmentID))")
            return
        }
        #expect(general.section_id == "sec-1")
        #expect(general.title == "Wins")
        #expect(general.prompt_text == "Was lief gut?")
        #expect(reflection.segment_id == "s02")
        #expect(reflection.audio_file == "segments/s02.m4a")
    }

    @Test("a throwing capture records nothing and leaves the id free")
    func throwingRecord() async throws {
        let root = try scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = try makeBundle(root: root)

        await #expect(throws: CaptureFailure.self) {
            try await bundle.record(self.event()) { _ in throw CaptureFailure() }
        }

        #expect(bundle.segments.isEmpty)
        #expect(bundle.currentSegmentID == nil)
        #expect(bundle.audioURL(forSegmentID: "s01e02") == nil)
        // The failed attempt did not use up the base id.
        try await bundle.record(event(), capture: writing("A"))
        #expect(bundle.segments.map(\.segmentID) == ["s01e02"])
    }

    @Test("a throwing capture after earlier chunks keeps them and does not advance the chunk number")
    func throwingRecordAfterChunk() async throws {
        let root = try scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = try makeBundle(root: root)
        try await bundle.record(event(), capture: writing("A"))
        _ = bundle.finishCurrent()

        await #expect(throws: CaptureFailure.self) {
            try await bundle.record(self.event()) { _ in throw CaptureFailure() }
        }
        #expect(bundle.currentSegmentID == nil)
        try await bundle.record(event(), capture: writing("B"))

        #expect(bundle.segments.map(\.segmentID) == ["s01e02", "s01e02c2"])
    }

    @Test("after a pause the next recordings of a base id are c2, c3 and never overwrite a chunk")
    func chunkIDs() async throws {
        let root = try scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = try makeBundle(root: root)

        for (index, payload) in ["A", "B", "C"].enumerated() {
            try await bundle.record(event(), capture: writing(payload))
            #expect(bundle.currentSegmentID == ["s01e02", "s01e02c2", "s01e02c3"][index])
            _ = bundle.finishCurrent()
        }

        #expect(bundle.segments.map(\.segmentID) == ["s01e02", "s01e02c2", "s01e02c3"])
        #expect(try Data(contentsOf: #require(bundle.audioURL(forSegmentID: "s01e02"))) == Data("A".utf8))
        #expect(try Data(contentsOf: #require(bundle.audioURL(forSegmentID: "s01e02c2"))) == Data("B".utf8))
    }

    @Test("a reopened bundle continues the chunk numbers after the restored chunks")
    func reopenContinuesChunkNumbers() async throws {
        let root = try scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = try makeBundle(root: root)
        for payload in ["A", "B"] {
            try await bundle.record(event(), capture: writing(payload))
            _ = bundle.finishCurrent()
        }
        let reopened = try SessionBundle.open(bundle.directory, audio: FakeBundleAudio())

        try await reopened.record(event(), capture: writing("C"))

        #expect(reopened.currentSegmentID == "s01e02c3")
        #expect(reopened.segments.map(\.segmentID) == ["s01e02", "s01e02c2", "s01e02c3"])
    }

    @Test("finishCurrent returns the stopped recording once and clears it")
    func finishCurrent() async throws {
        let root = try scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = try makeBundle(root: root)
        #expect(bundle.finishCurrent() == nil)
        try await bundle.record(event(), capture: writing("A"))

        let finished = try #require(bundle.finishCurrent())

        #expect(finished.id == "s01e02")
        #expect(finished.url == bundle.audioURL(forSegmentID: "s01e02"))
        #expect(bundle.currentSegmentID == nil)
        #expect(bundle.finishCurrent() == nil)
        #expect(bundle.segments.count == 1)
    }

    // MARK: - dropCurrent

    @Test("dropCurrent deletes the current file and its segment")
    func dropCurrent() async throws {
        let root = try scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = try makeBundle(root: root)
        try await bundle.record(event(), capture: writing("A"))
        let url = try #require(bundle.audioURL(forSegmentID: "s01e02"))

        bundle.dropCurrent()

        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(bundle.segments.isEmpty)
        #expect(bundle.currentSegmentID == nil)
        #expect(bundle.audioURL(forSegmentID: "s01e02") == nil)
    }

    @Test("dropCurrent after a pause drops the c-suffixed chunk, not the base id")
    func dropCurrentChunk() async throws {
        let root = try scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = try makeBundle(root: root)
        try await bundle.record(event(), capture: writing("A"))
        let first = try #require(bundle.audioURL(forSegmentID: "s01e02"))
        _ = bundle.finishCurrent()
        try await bundle.record(event(), capture: writing("B"))
        let second = try #require(bundle.audioURL(forSegmentID: "s01e02c2"))

        bundle.dropCurrent(fallbackSegmentID: "s01e02")

        #expect(bundle.segments.map(\.segmentID) == ["s01e02"])
        #expect(FileManager.default.fileExists(atPath: first.path))
        #expect(!FileManager.default.fileExists(atPath: second.path))
    }

    @Test("dropCurrent with nothing recording uses the fallback id, and does nothing without one")
    func dropFallback() async throws {
        let root = try scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = try makeBundle(root: root)
        try await bundle.record(event(), capture: writing("A"))
        _ = bundle.finishCurrent()

        bundle.dropCurrent()
        #expect(bundle.segments.count == 1)

        bundle.dropCurrent(fallbackSegmentID: "s01e02")
        #expect(bundle.segments.isEmpty)
    }

    @Test("dropCurrent never removes a voice-note segment")
    func dropKeepsVoiceNotes() async throws {
        let root = try scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = try makeBundle(root: root)
        try await bundle.record(.reflection(baseID: "s03"), capture: writing("R"))
        bundle.attachVoiceNotes([try makeVoiceNote("seed-1", in: root)], excluding: [])

        bundle.dropCurrent()

        #expect(bundle.segments.map(\.segmentID) == ["db_seed-1"])
    }

    // MARK: - transcripts and todos

    @Test("a transcript lands on events, general sections and reflections; only events take todos")
    func transcriptRules() async throws {
        let root = try scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = try makeBundle(root: root)
        let section = GeneralSection(id: "sec-1", title: "Wins", introText: "x")
        let todo = Todo(text: "Mail senden", type: "explicit", due: nil, status: "Offen", source_segment_id: "s01e01")
        try await bundle.record(event("s01e01"), capture: writing("E"))
        try await bundle.record(.general(baseID: "s02", section: section), capture: writing("G"))
        try await bundle.record(.reflection(baseID: "s03"), capture: writing("R"))
        bundle.attachVoiceNotes([try makeVoiceNote("seed-1", in: root, transcript: "unchanged")], excluding: [])

        for id in ["s01e01", "s02", "s03"] {
            bundle.recordTranscript(segmentID: id, text: "text \(id)", language: "de-DE", todos: [todo])
        }
        bundle.recordTranscript(segmentID: "db_seed-1", text: "overwritten?", language: "en", todos: [todo])
        bundle.recordTranscript(segmentID: "s99", text: "no such segment", language: "de-DE", todos: [])

        guard case .calendarEvent(let e) = bundle.segments[0],
              case .generalSection(let g) = bundle.segments[1],
              case .freeReflection(let r) = bundle.segments[2],
              case .voiceNote(let v) = bundle.segments[3] else {
            Issue.record("unexpected segment order")
            return
        }
        #expect(e.transcript == "text s01e01" && e.language == "de-DE" && e.todos_detected.count == 1)
        #expect(g.transcript == "text s02" && g.language == "de-DE")
        #expect(r.transcript == "text s03" && r.language == "de-DE")
        #expect(v.transcript == "unchanged" && v.language == "de")
        #expect(bundle.transcript(forSegmentID: "s02") == "text s02")
        #expect(bundle.transcript(forSegmentID: "s99") == nil)
        #expect(bundle.segments.count == 4)
    }

    @Test("an empty transcript reads back as nil")
    func emptyTranscriptIsNil() async throws {
        let root = try scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = try makeBundle(root: root)
        try await bundle.record(event(), capture: writing("A"))
        #expect(bundle.transcript(forSegmentID: "s01e02") == nil)
    }

    @Test("prompts and todo verdicts end up in the manifest in order")
    func promptsAndVerdicts() async throws {
        let root = try scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = try makeBundle(root: root)
        let todo = Todo(text: "Angebot prüfen", type: "implicit", due: nil, status: "Offen", source_segment_id: "s01e02")

        bundle.recordPrompt(role: "session_opening", segmentID: nil, text: "Guten Abend")
        bundle.recordPrompt(role: "opener", segmentID: "s01e02", text: "Wie war Planning?")
        bundle.recordTodoConfirmed(todo)
        bundle.recordTodoRejected(text: "Kaffee holen", sourceSegmentID: "s01e02")
        let upload = await bundle.finalize(date: "2026-10-18", responseLanguage: "de")

        #expect(bundle.confirmedTodoCount == 1)
        #expect(upload.manifest.ai_prompts.map(\.role) == ["session_opening", "opener"])
        #expect(upload.manifest.ai_prompts.map(\.segment_id) == [nil, "s01e02"])
        #expect(upload.manifest.todos_implicit_confirmed.map(\.text) == ["Angebot prüfen"])
        #expect(upload.manifest.todos_implicit_rejected.map(\.text) == ["Kaffee holen"])
        #expect(upload.manifest.todos_implicit_rejected.first?.source_segment_id == "s01e02")
        #expect(upload.manifest.response_language_setting == "de")
        #expect(upload.manifest.date == "2026-10-18")
        #expect(upload.manifest.session_id == "2026-10-18T20:15:00+02:00")
    }

    // MARK: - voice notes

    @Test("voice notes are copied in, except deferred or dropped ones, and reported as surfaced")
    func voiceNoteAttach() async throws {
        let root = try scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = try makeBundle(root: root)
        let notes = [
            try makeVoiceNote("seed-a", in: root),
            try makeVoiceNote("seed-deferred", in: root),
            try makeVoiceNote("seed-dropped", in: root),
            try makeVoiceNote("2026-10-17T21:00:00+02:00", in: root),
        ]

        bundle.attachVoiceNotes(notes, excluding: ["seed-deferred", "seed-dropped"])

        #expect(bundle.surfacedNoteIDs == ["seed-a", "2026-10-17T21:00:00+02:00"])
        #expect(bundle.segments.map(\.segmentID) == ["db_seed-a", "db_2026-10-17T21-00-00_02-00"])
        let copy = try #require(bundle.audioURL(forSegmentID: "db_seed-a"))
        #expect(copy.lastPathComponent == "seed_seed-a.m4a")
        #expect(try Data(contentsOf: copy) == Data("audio-seed-a".utf8))
        let sanitized = bundle.directory.appending(path: "segments/seed_2026-10-17T21-00-00_02-00.m4a")
        #expect(FileManager.default.fileExists(atPath: sanitized.path))
        #expect(!FileManager.default.fileExists(
            atPath: bundle.directory.appending(path: "segments/seed_seed-dropped.m4a").path
        ))
        guard case .voiceNote(let segment) = bundle.segments[0] else {
            Issue.record("expected a voice note segment")
            return
        }
        #expect(segment.seed_id == "seed-a")
        #expect(segment.transcript == "note" && segment.language == "de")
    }

    @Test("a note whose copy fails is left out of the segments and the surfaced ids")
    func voiceNoteCopyFailure() async throws {
        let root = try scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = try makeBundle(root: root)
        let missing = VoiceNote(
            seed_id: "seed-missing",
            captured_at: Date(),
            duration_seconds: 1,
            language: "de",
            transcript: "",
            audio_file_url: root.appending(path: "gone.m4a")
        )

        bundle.attachVoiceNotes([missing, try makeVoiceNote("seed-ok", in: root)], excluding: [])

        #expect(bundle.surfacedNoteIDs == ["seed-ok"])
        #expect(bundle.segments.map(\.segmentID) == ["db_seed-ok"])
    }

    @Test("skipping the closing clears the surfaced notes but keeps their segments")
    func clearSurfaced() async throws {
        let root = try scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = try makeBundle(root: root)
        bundle.attachVoiceNotes([try makeVoiceNote("seed-a", in: root)], excluding: [])

        bundle.clearSurfacedNotes()
        let upload = await bundle.finalize(date: "2026-10-18", responseLanguage: "match_input")

        #expect(bundle.surfacedNoteIDs.isEmpty)
        #expect(upload.manifest.drive_by_seeds_surfaced.isEmpty)
        #expect(upload.manifest.segments.map(\.segmentID) == ["db_seed-a"])
    }

    // MARK: - finalize

    @Test("finalize merges c2/c3 into one segment and one file, and removes the chunk files")
    func finalizeMergesChunks() async throws {
        let root = try scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = FakeBundleAudio()
        let bundle = try makeBundle(root: root, audio: audio)
        let todo = Todo(text: "Folien schicken", type: "explicit", due: nil, status: "Offen", source_segment_id: "s01e02c2")
        for payload in ["A", "B", "C"] {
            try await bundle.record(event(), capture: writing(payload))
            _ = bundle.finishCurrent()
        }
        bundle.recordTranscript(segmentID: "s01e02", text: "Erster Teil", language: "de-DE", todos: [])
        bundle.recordTranscript(segmentID: "s01e02c2", text: "  ", language: "de-DE", todos: [todo])
        bundle.recordTranscript(segmentID: "s01e02c3", text: "Dritter Teil", language: "en-US", todos: [])

        let upload = await bundle.finalize(date: "2026-10-18", responseLanguage: "de")

        #expect(audio.mergeCalls == [["s01e02.m4a", "s01e02c2.m4a", "s01e02c3.m4a"]])
        #expect(upload.manifest.segments.map(\.segmentID) == ["s01e02"])
        guard case .calendarEvent(let merged) = upload.manifest.segments[0] else {
            Issue.record("expected one calendar event")
            return
        }
        #expect(merged.audio_file == "segments/s01e02.m4a")
        #expect(merged.transcript == "Erster Teil Dritter Teil")
        #expect(merged.language == "de-DE")
        #expect(merged.todos_detected.map(\.text) == ["Folien schicken"])
        #expect(Set(upload.files.keys) == ["segments/s01e02.m4a"])
        #expect(try Data(contentsOf: #require(upload.files["segments/s01e02.m4a"])) == Data("ABC".utf8))
        let segmentsDir = bundle.directory.appending(path: "segments")
        let names = try FileManager.default.contentsOfDirectory(atPath: segmentsDir.path)
        #expect(names == ["s01e02.m4a"])
    }

    @Test("chunks of different base ids are merged separately and a single chunk is left alone")
    func finalizeGroupsByBaseID() async throws {
        let root = try scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = FakeBundleAudio()
        let bundle = try makeBundle(root: root, audio: audio)
        let section = GeneralSection(id: "sec-1", title: "Wins", introText: "x")
        try await bundle.record(event("s01e01"), capture: writing("1"))
        _ = bundle.finishCurrent()
        try await bundle.record(event("s01e02"), capture: writing("A"))
        _ = bundle.finishCurrent()
        try await bundle.record(event("s01e02"), capture: writing("B"))
        _ = bundle.finishCurrent()
        try await bundle.record(.general(baseID: "s02", section: section), capture: writing("G"))
        _ = bundle.finishCurrent()
        bundle.attachVoiceNotes([try makeVoiceNote("seed-1", in: root)], excluding: [])

        let upload = await bundle.finalize(date: "2026-10-18", responseLanguage: "de")

        #expect(audio.mergeCalls == [["s01e02.m4a", "s01e02c2.m4a"]])
        #expect(upload.manifest.segments.map(\.segmentID) == ["s01e01", "s01e02", "s02", "db_seed-1"])
        #expect(Set(upload.files.keys) == audioFiles(of: upload.manifest))
        #expect(upload.files.count == 4)
    }

    @Test("a failed merge keeps the chunks, and they still upload")
    func finalizeMergeFailure() async throws {
        let root = try scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = try makeBundle(root: root, audio: FakeBundleAudio(failMerge: true))
        for payload in ["A", "B"] {
            try await bundle.record(event(), capture: writing(payload))
            _ = bundle.finishCurrent()
        }

        let upload = await bundle.finalize(date: "2026-10-18", responseLanguage: "de")

        #expect(upload.manifest.segments.map(\.segmentID) == ["s01e02", "s01e02c2"])
        #expect(Set(upload.files.keys) == ["segments/s01e02.m4a", "segments/s01e02c2.m4a"])
        for url in upload.files.values {
            #expect(FileManager.default.fileExists(atPath: url.path))
        }
        let names = try FileManager.default.contentsOfDirectory(
            atPath: bundle.directory.appending(path: "segments").path
        ).sorted()
        #expect(names == ["s01e02.m4a", "s01e02c2.m4a"])
    }

    @Test("a merge that cannot be moved into place leaves every chunk file on disk and uploadable")
    func finalizeMoveIntoPlaceFailure() async throws {
        let root = try scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = try makeBundle(root: root, audio: FakeBundleAudio(skipOutput: true))
        for payload in ["A", "B", "C"] {
            try await bundle.record(event(), capture: writing(payload))
            _ = bundle.finishCurrent()
        }

        let upload = await bundle.finalize(date: "2026-10-18", responseLanguage: "de")

        #expect(upload.manifest.segments.map(\.segmentID) == ["s01e02", "s01e02c2", "s01e02c3"])
        #expect(Set(upload.files.keys) == audioFiles(of: upload.manifest))
        for (path, payload) in zip(["segments/s01e02.m4a", "segments/s01e02c2.m4a", "segments/s01e02c3.m4a"], ["A", "B", "C"]) {
            let url = try #require(upload.files[path])
            #expect(try Data(contentsOf: url) == Data(payload.utf8), "\(path) lost or changed")
        }
        let names = try FileManager.default.contentsOfDirectory(
            atPath: bundle.directory.appending(path: "segments").path
        ).sorted()
        #expect(names == ["s01e02.m4a", "s01e02c2.m4a", "s01e02c3.m4a"])
    }

    @Test("manifest audio_file keys equal the upload files keys, and the snapshot on disk matches")
    func manifestFilesEquality() async throws {
        let root = try scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = try makeBundle(root: root)
        let section = GeneralSection(id: "sec-1", title: "Wins", introText: "x")
        try await bundle.record(.general(baseID: "s01", section: section), capture: writing("G"))
        _ = bundle.finishCurrent()
        for payload in ["A", "B"] {
            try await bundle.record(event("s02e01"), capture: writing(payload))
            _ = bundle.finishCurrent()
        }
        try await bundle.record(.reflection(baseID: "s03"), capture: writing("R"))
        bundle.attachVoiceNotes([try makeVoiceNote("seed-1", in: root)], excluding: [])
        // A skipped event leaves nothing behind in either set.
        try await bundle.record(event("s02e02"), capture: writing("X"))
        bundle.dropCurrent()

        let upload = await bundle.finalize(date: "2026-10-18", responseLanguage: "de")

        #expect(Set(upload.files.keys) == audioFiles(of: upload.manifest))
        for (path, url) in upload.files {
            #expect(url == bundle.directory.appending(path: path))
            #expect(FileManager.default.fileExists(atPath: url.path))
        }
        let snapshot = try Data(contentsOf: bundle.directory.appending(path: LocalStore.manifestFilename))
        let decoded = try JSONDecoder().decode(Manifest.self, from: snapshot)
        #expect(decoded.session_id == upload.manifest.session_id)
        #expect(audioFiles(of: decoded) == Set(upload.files.keys))
    }

    @Test("the manifest reports the real sample rate of the first capture")
    func realSampleRate() async throws {
        let root = try scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = try makeBundle(root: root, audio: FakeBundleAudio(rates: [48_000]))
        try await bundle.record(event(), capture: writing("A"))

        let upload = await bundle.finalize(date: "2026-10-18", responseLanguage: "de")

        #expect(upload.manifest.audio_codec.sample_rate == 48_000)
        #expect(upload.manifest.audio_codec.codec == "aac-lc")
        #expect(upload.manifest.audio_codec.channels == 1)
    }

    @Test("with differing chunk rates the first one is reported")
    func firstSampleRateWins() async throws {
        let root = try scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = try makeBundle(root: root, audio: FakeBundleAudio(rates: [16_000, 48_000, 44_100]))
        for payload in ["A", "B", "C"] {
            try await bundle.record(event(), capture: writing(payload))
            _ = bundle.finishCurrent()
        }

        let upload = await bundle.finalize(date: "2026-10-18", responseLanguage: "de")

        #expect(upload.manifest.audio_codec.sample_rate == 16_000)
    }

    @Test("a session with no recording of its own reports the default rate")
    func defaultSampleRate() async throws {
        let root = try scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = try makeBundle(root: root, audio: FakeBundleAudio(rates: [0]))
        try await bundle.record(event(), capture: writing("A"))

        let upload = await bundle.finalize(date: "2026-10-18", responseLanguage: "de")

        #expect(upload.manifest.audio_codec.sample_rate == SessionBundle.defaultSampleRate)
    }

    // MARK: - protection

    @Test("every directory and file the bundle creates gets the app-wide protection class")
    func appWideProtection() async throws {
        let root = try scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var protected: Set<String> = []
        let bundle = try makeBundle(root: root) { url in
            protected.insert(url.standardizedFileURL.path)
            LocalStore.applyProtection(to: url)
        }
        for payload in ["A", "B"] {
            try await bundle.record(event(), capture: writing(payload))
            _ = bundle.finishCurrent()
        }
        try await bundle.record(.reflection(baseID: "s02"), capture: writing("R"))
        bundle.attachVoiceNotes([try makeVoiceNote("seed-1", in: root)], excluding: [])

        let upload = await bundle.finalize(date: "2026-10-18", responseLanguage: "de")

        let manifestURL = bundle.directory.appending(path: LocalStore.manifestFilename)
        let journalURL = bundle.directory.appending(path: SessionBundle.journalFilename)
        var created = [bundle.directory]
        let enumerator = try #require(FileManager.default.enumerator(at: bundle.directory, includingPropertiesForKeys: nil))
        created += enumerator.compactMap { $0 as? URL }
        #expect(created.count >= 5)
        for url in created {
            // The manifest snapshot and the journal are written with the
            // app-wide write option.
            if url.lastPathComponent != manifestURL.lastPathComponent,
               url.lastPathComponent != journalURL.lastPathComponent {
                #expect(protected.contains(url.standardizedFileURL.path), "\(url.lastPathComponent) not protected")
            }
            #expect(LocalStore.currentProtection(of: url) == LocalStore.protectionClass, "\(url.lastPathComponent)")
        }
        #expect(upload.files.count == 3)
    }

    // MARK: - journal

    private let pauseMarker = SessionBundle.PauseMarker(
        phase: .listening, kind: .event, stepIndex: 0, eventIndex: 1, sectionID: nil,
        elapsedSeconds: 133, activeSegmentID: "s01e02", pausedAt: Date(timeIntervalSince1970: 1_760_000_000)
    )

    private func json(_ value: some Encodable) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    @Test("a reopened bundle restores segments, transcripts, prompts, verdicts, notes and the pause marker")
    func reopenRestoresEverything() async throws {
        let root = try scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = try makeBundle(root: root)
        let section = GeneralSection(id: "sec-1", title: "Wins", introText: "Was lief gut?")
        let todo = Todo(text: "Angebot prüfen", type: "implicit", source_segment_id: "s01e02")
        try await bundle.record(.general(baseID: "s01", section: section), capture: writing("G"))
        _ = bundle.finishCurrent()
        try await bundle.record(event(), capture: writing("A"))
        _ = bundle.finishCurrent()
        bundle.recordTranscript(segmentID: "s01", text: "Gut gelaufen", language: "de-DE", todos: [])
        bundle.recordTranscript(segmentID: "s01e02", text: "Planung besprochen", language: "de-DE", todos: [todo])
        bundle.recordPrompt(role: "opener", segmentID: "s01e02", text: "Wie war Planning?")
        bundle.recordTodoConfirmed(todo)
        bundle.recordTodoRejected(text: "Kaffee holen", sourceSegmentID: "s01e02")
        try await bundle.record(.reflection(baseID: "s03"), capture: writing("R"))
        bundle.attachVoiceNotes([try makeVoiceNote("seed-1", in: root)], excluding: [])
        bundle.setPauseMarker(pauseMarker)

        let reopened = try SessionBundle.open(bundle.directory, audio: FakeBundleAudio())

        #expect(reopened.sessionID == bundle.sessionID)
        #expect(try json(reopened.segments) == json(bundle.segments))
        #expect(reopened.transcript(forSegmentID: "s01e02") == "Planung besprochen")
        #expect(reopened.surfacedNoteIDs == ["seed-1"])
        #expect(reopened.confirmedTodoCount == 1)
        #expect(reopened.pauseMarker == pauseMarker)
        #expect(reopened.latestRecordedSegment?.segmentID == "s03")
        #expect(reopened.currentSegmentID == nil)
        let before = await bundle.finalize(date: "2026-10-18", responseLanguage: "de")
        let after = await reopened.finalize(date: "2026-10-18", responseLanguage: "de")
        #expect(try json(after.manifest) == json(before.manifest))
        #expect(after.manifest.ai_prompts.map(\.text) == ["Wie war Planning?"])
        #expect(after.manifest.todos_implicit_rejected.map(\.text) == ["Kaffee holen"])
    }

    @Test("a bundle without a journal cannot be opened for pickup")
    func openWithoutJournal() async throws {
        let root = try scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = try makeBundle(root: root)
        try await bundle.record(event(), capture: writing("A"))
        try FileManager.default.removeItem(at: bundle.directory.appending(path: SessionBundle.journalFilename))

        #expect(throws: SessionBundle.OpenError.self) {
            try SessionBundle.open(bundle.directory, audio: FakeBundleAudio())
        }
        // The audio is untouched, so the session stays uploadable and deletable.
        #expect(FileManager.default.fileExists(atPath: bundle.directory.appending(path: "segments/s01e02.m4a").path))
    }

    @Test("a failed journal write never escapes a mutator and the next write recovers")
    func journalWriteFailure() async throws {
        let root = try scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let disk = FlakyDisk()
        let bundle = try SessionBundle.create(
            in: root, sessionID: "2026-10-18T20:15:00+02:00", audio: FakeBundleAudio(),
            writeJournal: { data, url in
                disk.attempts += 1
                if disk.failing { throw CocoaError(.fileWriteOutOfSpace) }
                try SessionBundle.writeJournalData(data, to: url)
            }
        )

        try await bundle.record(event(), capture: writing("A"))
        _ = bundle.finishCurrent()
        bundle.recordTranscript(segmentID: "s01e02", text: "Planung", language: "de-DE", todos: [])
        bundle.recordPrompt(role: "opener", segmentID: "s01e02", text: "Hallo")
        bundle.recordTodoConfirmed(Todo(text: "a"))
        bundle.recordTodoRejected(text: "b", sourceSegmentID: nil)
        bundle.setPauseMarker(pauseMarker)
        bundle.clearPauseMarker()
        bundle.attachVoiceNotes([try makeVoiceNote("seed-1", in: root)], excluding: [])
        bundle.clearSurfacedNotes()
        bundle.dropCurrent(fallbackSegmentID: "s09")
        let upload = await bundle.finalize(date: "2026-10-18", responseLanguage: "de")

        #expect(disk.attempts >= 10)
        #expect(bundle.transcript(forSegmentID: "s01e02") == "Planung")
        #expect(upload.manifest.ai_prompts.count == 1)
        #expect(throws: SessionBundle.OpenError.self) {
            try SessionBundle.open(bundle.directory, audio: FakeBundleAudio())
        }

        disk.failing = false
        bundle.recordPrompt(role: "closing", segmentID: nil, text: "Gute Nacht")
        let reopened = try SessionBundle.open(bundle.directory, audio: FakeBundleAudio())
        #expect(reopened.transcript(forSegmentID: "s01e02") == "Planung")
    }

    @Test("a new recording supersedes the pause marker, and clearing it is journaled")
    func pauseMarkerLifecycle() async throws {
        let root = try scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = try makeBundle(root: root)
        try await bundle.record(event(), capture: writing("A"))
        _ = bundle.finishCurrent()
        bundle.setPauseMarker(pauseMarker)
        #expect(try SessionBundle.open(bundle.directory, audio: FakeBundleAudio()).pauseMarker == pauseMarker)

        bundle.clearPauseMarker()
        #expect(try SessionBundle.open(bundle.directory, audio: FakeBundleAudio()).pauseMarker == nil)

        bundle.setPauseMarker(pauseMarker)
        try await bundle.record(event(), capture: writing("B"))
        #expect(bundle.pauseMarker == nil)
        #expect(try SessionBundle.open(bundle.directory, audio: FakeBundleAudio()).pauseMarker == nil)
    }

    @Test("the latest recorded segment skips attached voice notes")
    func latestRecordedSegment() async throws {
        let root = try scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = try makeBundle(root: root)
        #expect(bundle.latestRecordedSegment == nil)
        try await bundle.record(event(), capture: writing("A"))
        _ = bundle.finishCurrent()
        try await bundle.record(event(), capture: writing("B"))
        _ = bundle.finishCurrent()
        bundle.attachVoiceNotes([try makeVoiceNote("seed-1", in: root)], excluding: [])

        #expect(bundle.latestRecordedSegment?.segmentID == "s01e02c2")
        #expect(bundle.chunks(sharingRecordingWith: "s01e02").map(\.segmentID) == ["s01e02", "s01e02c2"])
    }

    @Test("a segment whose audio is gone is dropped on open and the drop is journaled")
    func openDropsMissingAudio() async throws {
        let root = try scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = try makeBundle(root: root)
        try await bundle.record(event(), capture: writing("A"))
        _ = bundle.finishCurrent()
        try await bundle.record(event(), capture: writing("B"))
        _ = bundle.finishCurrent()
        try FileManager.default.removeItem(at: try #require(bundle.audioURL(forSegmentID: "s01e02c2")))

        let reopened = try SessionBundle.open(bundle.directory, audio: FakeBundleAudio())

        #expect(reopened.segments.map(\.segmentID) == ["s01e02"])
        #expect(try SessionBundle.open(bundle.directory, audio: FakeBundleAudio()).segments.count == 1)
    }

    @Test("the journal is replaced atomically and leaves no temporary file behind")
    func journalAtomicReplace() throws {
        let root = try scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: SessionBundle.journalFilename)

        try SessionBundle.writeJournalData(Data("first".utf8), to: url)
        try SessionBundle.writeJournalData(Data("second".utf8), to: url)

        #expect(try Data(contentsOf: url) == Data("second".utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == [SessionBundle.journalFilename])
    }

    // MARK: - ids

    @Test("segment ids parse into base id and chunk number, and map to the media path")
    func idParsing() {
        #expect(SessionBundle.parseSegmentID("s01").baseID == "s01")
        #expect(SessionBundle.parseSegmentID("s01").chunkIndex == 1)
        #expect(SessionBundle.parseSegmentID("s01e02").baseID == "s01e02")
        let chunk = SessionBundle.parseSegmentID("s01e02c3")
        #expect(chunk.baseID == "s01e02" && chunk.chunkIndex == 3)
        #expect(SessionBundle.parseSegmentID("db_seed").baseID == "db_seed")
        #expect(SessionBundle.mediaPath(for: "s01e02c2") == "segments/s01e02c2.m4a")
        #expect(SessionBundle.sanitize("a:b+c") == "a-b_c")
    }
}
