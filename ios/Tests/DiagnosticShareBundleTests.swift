import Foundation
import Testing
@testable import VoiceDiary

// Text bundle shared from the Diagnostics detail view (AirDrop, Mail,
// Save to Files). The collector reads the payload and log files; these
// tests pin how the report fields and file contents become the text.

@Suite("DiagnosticShareBundle")
struct DiagnosticShareBundleTests {
    // 2026-06-02T09:14:22Z, independent of the machine's timezone.
    private static let capturedAt = Date(timeIntervalSince1970: 1_780_391_662)

    private static func text(
        payload: String? = "{}",
        log: String? = "line"
    ) -> String {
        DiagnosticShareBundle.text(
            id: "2026-06-02T09-14-22Z",
            timestamp: capturedAt,
            summary: "Crash×1",
            payloadText: payload,
            logText: log
        )
    }

    @Test("payload and log present: header, payload section, log section in order")
    func bothPresent() {
        let expected = """
        Voice Diary diagnostic report
        id: 2026-06-02T09-14-22Z
        captured: 2026-06-02T09:14:22Z
        summary: Crash×1
        ----- MetricKit payload -----
        {"a": 1}
        ----- Log window -----
        09:14:00.000 [app] I started

        """
        #expect(Self.text(payload: #"{"a": 1}"#, log: "09:14:00.000 [app] I started")
                == expected)
    }

    @Test("missing payload falls back to (unavailable)")
    func payloadNil() {
        let expected = "Voice Diary diagnostic report\n"
            + "id: 2026-06-02T09-14-22Z\n"
            + "captured: 2026-06-02T09:14:22Z\n"
            + "summary: Crash×1\n"
            + "----- MetricKit payload -----\n"
            + "(unavailable)\n"
            + "----- Log window -----\n"
            + "line\n"
        #expect(Self.text(payload: nil) == expected)
    }

    @Test("missing log falls back to (no log snapshot)")
    func logNil() {
        let expected = "Voice Diary diagnostic report\n"
            + "id: 2026-06-02T09-14-22Z\n"
            + "captured: 2026-06-02T09:14:22Z\n"
            + "summary: Crash×1\n"
            + "----- MetricKit payload -----\n"
            + "{}\n"
            + "----- Log window -----\n"
            + "(no log snapshot)\n"
        #expect(Self.text(log: nil) == expected)
    }

    @Test("both missing use both fallbacks")
    func bothNil() {
        let expected = "Voice Diary diagnostic report\n"
            + "id: 2026-06-02T09-14-22Z\n"
            + "captured: 2026-06-02T09:14:22Z\n"
            + "summary: Crash×1\n"
            + "----- MetricKit payload -----\n"
            + "(unavailable)\n"
            + "----- Log window -----\n"
            + "(no log snapshot)\n"
        #expect(Self.text(payload: nil, log: nil) == expected)
    }

    @Test("empty strings are content, not missing")
    func emptyDistinctFromNil() {
        let out = Self.text(payload: "", log: "")
        let expected = "Voice Diary diagnostic report\n"
            + "id: 2026-06-02T09-14-22Z\n"
            + "captured: 2026-06-02T09:14:22Z\n"
            + "summary: Crash×1\n"
            + "----- MetricKit payload -----\n"
            + "\n"
            + "----- Log window -----\n"
            + "\n"
        #expect(out == expected)
        #expect(!out.contains("(unavailable)"))
        #expect(!out.contains("(no log snapshot)"))
    }

    @Test("Unicode and embedded newlines pass through verbatim")
    func unicodeAndNewlines() {
        let payload = "{\n  \"name\": \"Grüße 🎙️ 日本語\"\n}"
        let log = "first\nzweite Zeile ✓\n\nlast\n"
        let out = DiagnosticShareBundle.text(
            id: "id-ü",
            timestamp: Self.capturedAt,
            summary: "Hang×2 · Disk×1",
            payloadText: payload,
            logText: log
        )
        let expected = "Voice Diary diagnostic report\n"
            + "id: id-ü\n"
            + "captured: 2026-06-02T09:14:22Z\n"
            + "summary: Hang×2 · Disk×1\n"
            + "----- MetricKit payload -----\n"
            + "{\n  \"name\": \"Grüße 🎙️ 日本語\"\n}\n"
            + "----- Log window -----\n"
            + "first\nzweite Zeile ✓\n\nlast\n\n"
        #expect(out == expected)
    }

    @Test("the timestamp is UTC ISO8601 whatever the process timezone")
    func timestampIgnoresTimezone() {
        let saved = NSTimeZone.default
        defer { NSTimeZone.default = saved }
        for name in ["Pacific/Auckland", "America/Los_Angeles", "UTC"] {
            NSTimeZone.default = TimeZone(identifier: name)!
            #expect(Self.text().contains("\ncaptured: 2026-06-02T09:14:22Z\n"), "\(name)")
        }
    }

    @Test("fractional seconds are dropped from the timestamp")
    func wholeSeconds() {
        let out = DiagnosticShareBundle.text(
            id: "x",
            timestamp: Date(timeIntervalSince1970: 1_780_391_662.987),
            summary: "s",
            payloadText: nil,
            logText: nil
        )
        #expect(out.contains("\ncaptured: 2026-06-02T09:14:22Z\n"))
    }
}
