import Foundation
import Testing
@testable import VoiceDiary

// Filename stem behind every stored diagnostic report. The collector
// names `<stem>.json` / `<stem>.log` from the payload's end date and
// parses the stem back for ordering and retention; these tests pin the
// codec in isolation, with synthetic dates and no files.

@Suite("DiagnosticFilenameTimestamp")
struct DiagnosticFilenameTimestampTests {
    private static func date(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSince1970: seconds)
    }

    @Test("known dates encode as UTC stems",
          arguments: [
            (0.0, "1970-01-01T00-00-00Z"),
            (1_780_391_662.0, "2026-06-02T09-14-22Z"),
            // Winter and summer, so a local-offset bug can't cancel out.
            (1_767_225_600.0, "2026-01-01T00-00-00Z"),
            (1_782_864_000.0, "2026-07-01T00-00-00Z"),
          ])
    func encodesKnownDates(seconds: TimeInterval, stem: String) {
        #expect(DiagnosticFilenameTimestamp.stem(from: Self.date(seconds)) == stem)
    }

    @Test("stems across midnight and year boundaries",
          arguments: [
            (1_767_225_599.0, "2025-12-31T23-59-59Z"),
            (1_767_225_600.0, "2026-01-01T00-00-00Z"),
            (1_772_323_199.0, "2026-02-28T23-59-59Z"),
            (1_772_323_200.0, "2026-03-01T00-00-00Z"),
            // 2028 is a leap year.
            (1_835_395_199.0, "2028-02-28T23-59-59Z"),
            (1_835_395_200.0, "2028-02-29T00-00-00Z"),
          ])
    func boundaries(seconds: TimeInterval, stem: String) {
        #expect(DiagnosticFilenameTimestamp.stem(from: Self.date(seconds)) == stem)
        #expect(DiagnosticFilenameTimestamp.date(fromStem: stem) == Self.date(seconds))
    }

    @Test("stems decode to the exact instant")
    func decodes() {
        #expect(DiagnosticFilenameTimestamp.date(fromStem: "2026-06-02T09-14-22Z")
                == Self.date(1_780_391_662))
        #expect(DiagnosticFilenameTimestamp.date(fromStem: "1970-01-01T00-00-00Z")
                == Self.date(0))
    }

    @Test("round trip keeps second precision and drops fractions")
    func roundTrip() {
        let whole = Self.date(1_780_391_662)
        #expect(DiagnosticFilenameTimestamp.date(
            fromStem: DiagnosticFilenameTimestamp.stem(from: whole)) == whole)

        let fractional = Self.date(1_780_391_662.987)
        #expect(DiagnosticFilenameTimestamp.stem(from: fractional) == "2026-06-02T09-14-22Z")
        #expect(DiagnosticFilenameTimestamp.date(
            fromStem: DiagnosticFilenameTimestamp.stem(from: fractional)) == whole)
    }

    @Test("stems are filename safe")
    func filenameSafe() {
        let stem = DiagnosticFilenameTimestamp.stem(from: Self.date(1_780_391_662))
        #expect(!stem.contains(":"))
        #expect(!stem.contains("/"))
    }

    // Existing behavior, deliberately not tightened: DateFormatter's
    // default parsing tolerates these separator and suffix variations.
    @Test("DateFormatter's lenient parsing is preserved",
          arguments: [
            "2026-06-02T09:14:22Z",   // colons instead of dashes
            "2026-06-02T09-14-22",    // missing literal Z
          ])
    func lenient(stem: String) {
        #expect(DiagnosticFilenameTimestamp.date(fromStem: stem) == Self.date(1_780_391_662))
    }

    @Test("malformed stems do not decode",
          arguments: [
            "",
            "not-a-date",
            "2026-06-02 09-14-22Z",   // missing literal T
            "2026-13-02T09-14-22Z",   // month out of range
            "2026-06-02T09-14-22Z.json",
          ])
    func malformed(stem: String) {
        #expect(DiagnosticFilenameTimestamp.date(fromStem: stem) == nil)
    }
}
