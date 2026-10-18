import Foundation
import OSLog
import Testing
@testable import VoiceDiary

// The MATCH diagnostic must not publish the matched spoken token: it is a
// fragment of the user's transcript (Logging.swift privacy rule). The rest of
// the line (canonical word, distance, action) stays public so the line is
// still useful. Neither `OSLogStore` nor `OSLogEntryLog` exposes an
// argument's privacy (the simulator also does not redact private values in
// `composedMessage`), so the privacy is asserted on the logging call in the
// source, and the line's content is read back from the process's own log.

@Suite("WakeWordDetector logging")
struct WakeWordDetectorLoggingTests {
    private func matchLine(since start: Date) throws -> String? {
        let store = try OSLogStore(scope: .currentProcessIdentifier)
        let entries = try store.getEntries(
            at: store.position(date: start),
            matching: NSPredicate(format: "subsystem == %@", argumentArray: [Log.subsystem])
        )
        return entries
            .compactMap { ($0 as? OSLogEntryLog)?.composedMessage }
            .last { $0.contains("WakeWordDetector MATCH") }
    }

    /// The statement that writes the MATCH diagnostic, from the detector source.
    private func matchStatement() throws -> String {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Capture/WakeWordDetector.swift")
        let lines = try String(contentsOf: source, encoding: .utf8).components(separatedBy: "\n")
        return try #require(lines.first { $0.contains("WakeWordDetector MATCH") })
    }

    @Test("MATCH statement interpolates the spoken token privately")
    func tokenIsPrivate() throws {
        let statement = try matchStatement()
        #expect(statement.contains("\\(token, privacy: .private)"), "token not private: \(statement)")
        // The diagnostic stays useful: everything but the token is public.
        #expect(!statement.contains("Diag.log"), "Diag.log publishes the whole string: \(statement)")
        #expect(statement.contains("\\(phrase.canonical, privacy: .public)"))
        #expect(statement.contains("\\(dist, privacy: .public)"))
        #expect(statement.contains("\\(phrase.action.rawValue, privacy: .public)"))
    }

    @Test("MATCH line still reports canonical word, distance and action")
    func lineStaysUseful() throws {
        let start = Date().addingTimeInterval(-1)
        let detector = WakeWordDetector(
            phrases: [.init("weiter", action: .advance)],
            onMatch: { _, _ in }
        )
        // "weitr" is one edit from "weiter".
        detector.consume(partial: "ich sage weitr")

        let line = try #require(try matchLine(since: start))
        #expect(line.contains("canonical='weiter'"))
        #expect(line.contains("lev=1"))
        #expect(line.contains("action=advance"))
    }
}
