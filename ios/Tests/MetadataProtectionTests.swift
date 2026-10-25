import Foundation
import Testing
@testable import VoiceDiary

// SEC-45 / #45: the session journal (which holds the pause marker) and the
// voice-note metadata are written
// while the screen may be locked, so they must take the app-wide
// `completeUntilFirstUserAuthentication` class. `.complete` makes the
// write fail once the device locks.

@Suite("Metadata file protection")
@MainActor
struct MetadataProtectionTests {
    private func scratchDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "sec45-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func expectAppWideProtection(_ url: URL, expecting payload: Data) throws {
        #expect(LocalStore.currentProtection(of: url) == LocalStore.protectionClass)
        #expect(try Data(contentsOf: url) == payload)
    }

    // The simulator reports the default class whatever write option is
    // passed, so the class itself is checked at the three call sites.
    @Test("the three writes pass the app-wide write option, not .completeFileProtection")
    func writeOptionsAtCallSites() throws {
        let iosDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        let sites = [
            ("Sources/Capture/CaptureCoordinator.swift", "static func writeMetadata("),
            ("Sources/Dialog/SessionBundle.swift", "static func writeJournalData("),
            ("Sources/UI/Verlauf/SessionMutations.swift", "static func writeVoiceNoteMetadata("),
        ]
        for (path, marker) in sites {
            let source = try String(contentsOf: iosDir.appending(path: path), encoding: .utf8)
            let start = try #require(source.range(of: marker), "missing \(marker)")
            let body = source[start.lowerBound...].prefix(400)
            #expect(body.contains("LocalStore.dataProtectionWriteOption"), "\(path)")
            #expect(!body.contains(".completeFileProtection]"), "\(path)")
        }
    }

    @Test("capture metadata.json uses the app-wide class and stays readable")
    func captureMetadata() throws {
        let dir = try scratchDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let note = VoiceNote(
            seed_id: "note-sec45",
            captured_at: Date(),
            duration_seconds: 3,
            language: "en",
            transcript: "hello",
            audio_file_url: dir.appending(path: "audio.m4a")
        )

        try CaptureCoordinator.writeMetadata(note: note, into: dir)

        let url = dir.appending(path: "metadata.json")
        try expectAppWideProtection(url, expecting: try Data(contentsOf: url))
        #expect(try Data(contentsOf: url).count > 0)
    }

    @Test("session journal uses the app-wide class and stays readable")
    func sessionJournal() throws {
        let dir = try scratchDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let payload = Data(#"{"pauseMarker":{"phase":"listening"}}"#.utf8)
        let url = dir.appending(path: SessionBundle.journalFilename)

        try SessionBundle.writeJournalData(payload, to: url)

        try expectAppWideProtection(url, expecting: payload)
    }

    @Test("rewritten voice-note metadata uses the app-wide class and stays readable")
    func rewrittenVoiceNoteMetadata() throws {
        let dir = try scratchDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let payload = Data(#"{"seed_id":"note-sec45"}"#.utf8)
        let url = dir.appending(path: "metadata.json")

        try SessionMutations.writeVoiceNoteMetadata(payload, to: url)

        try expectAppWideProtection(url, expecting: payload)
    }
}
