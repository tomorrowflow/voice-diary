import Foundation
import Testing
@testable import VoiceDiary

// IOS-SB-48 / #48: Verlauf and the pickup lookup read the staging directory
// through the session bundle. Everything runs against a temporary root.

private struct NoAudio: SessionBundleAudio {
    func merge(chunks: [URL], into output: URL) async throws {}
    func sampleRate() async -> Double { 48_000 }
}

@Suite("SessionBundle reading")
@MainActor
struct SessionBundleReadingTests {

    // MARK: - Fixtures

    private let plus2 = TimeZone(secondsFromGMT: 2 * 3600)!

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = plus2
        return calendar
    }

    /// A moment on the calendar day `day` (`2026-10-18`) at `time` (`23:50`), in +02:00.
    private func moment(_ day: String, _ time: String = "12:00") -> Date {
        ISO8601DateFormatter().date(from: "\(day)T\(time):00+02:00")!
    }

    private func scratchRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "sb48-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private let calendarRef = CalendarRef(
        graph_event_id: "evt-1", title: "Planning", start: "2026-10-18T09:00:00", end: "2026-10-18T10:00:00"
    )

    /// A bundle started at `day` `time` (+02:00) with one recorded segment.
    @discardableResult
    private func makeBundle(
        in root: URL, day: String, time: String = "12:00", recording: Bool = true
    ) async throws -> SessionBundle {
        let bundle = try SessionBundle.create(
            in: root, sessionID: "\(day)T\(time):00+02:00", audio: NoAudio(), protect: { _ in }
        )
        if recording {
            try await bundle.record(.event(baseID: "s01e01", calendarRef: calendarRef)) { url in
                try Data("audio".utf8).write(to: url)
            }
        }
        return bundle
    }

    private func unfinished(on day: String, in root: URL, at time: String = "12:00") -> SessionBundle.Summary? {
        SessionBundle.unfinished(on: moment(day, time), in: root, calendar: calendar)
    }

    // MARK: - unfinished

    @Test("the latest bundle started on the day wins, and other days are ignored")
    func latestForTheDay() async throws {
        let root = try scratchRoot()
        try await makeBundle(in: root, day: "2026-10-17", time: "21:00")
        try await makeBundle(in: root, day: "2026-10-18", time: "09:00")
        let latest = try await makeBundle(in: root, day: "2026-10-18", time: "18:30")
        try await makeBundle(in: root, day: "2026-10-19", time: "08:00")

        #expect(unfinished(on: "2026-10-18", in: root)?.directory == latest.directory)
        #expect(unfinished(on: "2026-10-16", in: root) == nil)
    }

    @Test("a session started at 23:50 is offered for that day, also when picked up the next day")
    func lateNightSession() async throws {
        let root = try scratchRoot()
        let late = try await makeBundle(in: root, day: "2026-10-18", time: "23:50")

        #expect(unfinished(on: "2026-10-18", in: root, at: "00:05")?.directory == late.directory)
        #expect(unfinished(on: "2026-10-19", in: root) == nil)
    }

    @Test("a finalized bundle is not unfinished")
    func finalizedIsSkipped() async throws {
        let root = try scratchRoot()
        let done = try await makeBundle(in: root, day: "2026-10-18", time: "20:00")
        _ = await done.finalize(date: "2026-10-18", responseLanguage: "de")
        let open = try await makeBundle(in: root, day: "2026-10-18", time: "10:00")

        #expect(unfinished(on: "2026-10-18", in: root)?.directory == open.directory)
    }

    @Test("a bundle without audio is skipped")
    func noAudioIsSkipped() async throws {
        let root = try scratchRoot()
        try await makeBundle(in: root, day: "2026-10-18", time: "20:00", recording: false)

        #expect(unfinished(on: "2026-10-18", in: root) == nil)
    }

    @Test("a bundle with only orphan temp audio is skipped, and orphans never count as audio")
    func orphanTempIsSkipped() async throws {
        let root = try scratchRoot()
        let orphaned = try await makeBundle(in: root, day: "2026-10-18", time: "20:00", recording: false)
        let segments = orphaned.directory.appending(path: "segments")
        try Data("x".utf8).write(to: segments.appending(path: "s01e01.tmp.m4a"))
        try Data("x".utf8).write(to: segments.appending(path: "s01e02.m4a.tmp"))

        #expect(unfinished(on: "2026-10-18", in: root) == nil)
        #expect(SessionBundle.list(in: root).isEmpty)
    }

    @Test("a bundle without a journal cannot be picked up")
    func noJournalIsSkipped() async throws {
        let root = try scratchRoot()
        let legacy = try await makeBundle(in: root, day: "2026-10-18", time: "20:00")
        try FileManager.default.removeItem(at: legacy.directory.appending(path: SessionBundle.journalFilename))

        #expect(unfinished(on: "2026-10-18", in: root) == nil)
        #expect(SessionBundle.list(in: root).count == 1)
    }

    // MARK: - list

    @Test("a finalized bundle lists its manifest, session id, diary date and audio")
    func listFinalized() async throws {
        let root = try scratchRoot()
        let bundle = try await makeBundle(in: root, day: "2026-10-18", time: "20:15")
        try await bundle.record(.reflection(baseID: "s09")) { url in try Data("more".utf8).write(to: url) }
        // A leftover temp file next to the real audio stays out of the list.
        try Data("x".utf8).write(to: bundle.directory.appending(path: "segments/s05.tmp.m4a"))
        _ = await bundle.finalize(date: "2026-10-17", responseLanguage: "de")

        let summaries = SessionBundle.list(in: root)
        #expect(summaries.count == 1)
        let summary = try #require(summaries.first)
        #expect(summary.sessionID == "2026-10-18T20:15:00+02:00")
        #expect(summary.date == "2026-10-17")
        #expect(summary.capturedAt == moment("2026-10-18", "20:15"))
        #expect(summary.isFinalized)
        #expect(summary.manifest?.segments.count == 2)
        #expect(summary.audioFiles.map(\.lastPathComponent) == ["s01e01.m4a", "s09.m4a"])
        #expect(summary.directory == bundle.directory)
    }

    @Test("an unfinished bundle lists without a manifest, from its directory name and capture day")
    func listUnfinished() async throws {
        let root = try scratchRoot()
        let bundle = try await makeBundle(in: root, day: "2026-10-18", time: "12:00")

        let summary = try #require(SessionBundle.list(in: root).first)
        #expect(summary.manifest == nil)
        #expect(!summary.isFinalized)
        #expect(summary.sessionID == bundle.directory.lastPathComponent)
        #expect(summary.capturedAt == moment("2026-10-18"))
        #expect(summary.date == "2026-10-18")
        #expect(summary.audioFiles.map(\.lastPathComponent) == ["s01e01.m4a"])
    }

    @Test("the list is newest capture first and ignores stray files in the root")
    func listOrder() async throws {
        let root = try scratchRoot()
        try await makeBundle(in: root, day: "2026-10-17")
        try await makeBundle(in: root, day: "2026-10-19")
        try await makeBundle(in: root, day: "2026-10-18")
        try Data("x".utf8).write(to: root.appending(path: "stray.txt"))

        #expect(SessionBundle.list(in: root).map(\.sessionID) == [
            "2026-10-19T12-00-00_02-00", "2026-10-18T12-00-00_02-00", "2026-10-17T12-00-00_02-00"
        ])
    }

    @Test("a missing root lists nothing")
    func missingRoot() {
        let root = FileManager.default.temporaryDirectory.appending(path: "sb48-missing-\(UUID().uuidString)")
        #expect(SessionBundle.list(in: root).isEmpty)
        #expect(SessionBundle.unfinished(on: Date(), in: root) == nil)
    }
}
