import Foundation
import Testing
@testable import VoiceDiary

// Summary line behind each row of the Diagnostics list. The collector
// reads the stored payload file; these tests pin how its JSON bytes
// become the summary, plus the collector's file-reading wrapper.

@Suite("DiagnosticPayloadSummary")
struct DiagnosticPayloadSummaryTests {
    private static func summary(_ json: String) -> String {
        DiagnosticPayloadSummary.summary(fromJSON: Data(json.utf8))
    }

    @Test("each diagnostic kind gets its label and count",
          arguments: [
            ("crashDiagnostics", "Crash×1"),
            ("hangDiagnostics", "Hang×1"),
            ("cpuExceptionDiagnostics", "CPU×1"),
            ("diskWriteExceptionDiagnostics", "Disk×1"),
          ])
    func singleKind(key: String, expected: String) {
        #expect(Self.summary(#"{"\#(key)": [{}]}"#) == expected)
    }

    @Test("the count is the array length")
    func counts() {
        #expect(Self.summary(#"{"crashDiagnostics": [{}, {}, {}]}"#) == "Crash×3")
    }

    @Test("several kinds are joined in Crash, Hang, CPU, Disk order")
    func allKinds() {
        let json = #"""
        {"crashDiagnostics": [{}], "hangDiagnostics": [{}, {}],
         "cpuExceptionDiagnostics": [{}, {}, {}],
         "diskWriteExceptionDiagnostics": [{}, {}, {}, {}]}
        """#
        #expect(Self.summary(json) == "Crash×1 · Hang×2 · CPU×3 · Disk×4")
    }

    @Test("JSON key order does not change the summary order")
    func shuffledKeyOrder() {
        let reversed = #"""
        {"diskWriteExceptionDiagnostics": [{}], "cpuExceptionDiagnostics": [{}],
         "hangDiagnostics": [{}], "crashDiagnostics": [{}]}
        """#
        let mixed = #"""
        {"hangDiagnostics": [{}], "diskWriteExceptionDiagnostics": [{}],
         "crashDiagnostics": [{}], "cpuExceptionDiagnostics": [{}]}
        """#
        let expected = "Crash×1 · Hang×1 · CPU×1 · Disk×1"
        #expect(Self.summary(reversed) == expected)
        #expect(Self.summary(mixed) == expected)
        #expect(Self.summary(#"{"diskWriteExceptionDiagnostics": [{}], "hangDiagnostics": [{}]}"#)
                == "Hang×1 · Disk×1")
    }

    @Test("empty arrays are left out")
    func emptyArrays() {
        #expect(Self.summary(#"{"crashDiagnostics": [], "hangDiagnostics": [{}]}"#) == "Hang×1")
        #expect(Self.summary(#"{"crashDiagnostics": [], "diskWriteExceptionDiagnostics": []}"#)
                == "Diagnostic")
    }

    @Test("array elements are counted whatever they hold")
    func mixedElements() {
        #expect(Self.summary(#"{"crashDiagnostics": [1, "two", null, [3], {"a": 4}, true]}"#)
                == "Crash×6")
        #expect(Self.summary(#"{"hangDiagnostics": [null]}"#) == "Hang×1")
    }

    @Test("unrelated keys are ignored")
    func unrelatedKeys() {
        #expect(Self.summary(#"{"timeStampBegin": "x", "metaData": {"a": 1}}"#) == "Diagnostic")
        #expect(Self.summary(#"{"metaData": {}, "cpuExceptionDiagnostics": [{}], "other": [1, 2]}"#)
                == "CPU×1")
    }

    @Test("a key of the wrong value type is ignored",
          arguments: [
            #"{"crashDiagnostics": 3}"#,
            #"{"crashDiagnostics": "Crash"}"#,
            #"{"crashDiagnostics": {"a": 1}}"#,
            #"{"crashDiagnostics": null}"#,
            #"{"crashDiagnostics": true}"#,
          ])
    func wrongType(json: String) {
        #expect(Self.summary(json) == "Diagnostic")
    }

    @Test("a wrongly typed key does not hide the others")
    func wrongTypeBesideValid() {
        #expect(Self.summary(#"{"crashDiagnostics": "x", "hangDiagnostics": [{}]}"#) == "Hang×1")
    }

    @Test("an empty object is the fallback")
    func emptyObject() {
        #expect(Self.summary("{}") == "Diagnostic")
    }

    @Test("a non-object root is the fallback",
          arguments: [
            "[]",
            #"[{"crashDiagnostics": [{}]}]"#,
            "5",
            #""crashDiagnostics""#,
            "null",
            "true",
          ])
    func nonObjectRoot(json: String) {
        #expect(Self.summary(json) == "Diagnostic")
    }

    @Test("malformed or empty bytes are the fallback")
    func malformedBytes() {
        #expect(Self.summary("") == "Diagnostic")
        #expect(Self.summary("not json") == "Diagnostic")
        #expect(Self.summary(#"{"crashDiagnostics": [{}]"#) == "Diagnostic")
        #expect(DiagnosticPayloadSummary.summary(fromJSON: Data([0xFF, 0xFE, 0x00, 0x7B])) == "Diagnostic")
    }
}

@Suite("DiagnosticsCollector.summarize(payloadAt:)")
struct DiagnosticsCollectorSummarizeTests {
    private static func withFile(_ contents: Data, _ body: (URL) -> Void) throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "DiagnosticsCollectorSummarizeTests-\(UUID().uuidString).json")
        try contents.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        body(url)
    }

    @Test("the stored payload's bytes go through the summary decoder")
    func readsFile() throws {
        let json = #"{"hangDiagnostics": [{}, {}], "crashDiagnostics": [{}]}"#
        try Self.withFile(Data(json.utf8)) { url in
            #expect(DiagnosticsCollector.summarize(payloadAt: url) == "Crash×1 · Hang×2")
        }
    }

    @Test("a payload file that isn't a JSON object is the fallback")
    func unusableFile() throws {
        try Self.withFile(Data("not json".utf8)) { url in
            #expect(DiagnosticsCollector.summarize(payloadAt: url) == "Diagnostic")
        }
    }

    @Test("an unreadable payload file is the fallback")
    func missingFile() {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "DiagnosticsCollectorSummarizeTests-missing-\(UUID().uuidString).json")
        #expect(DiagnosticsCollector.summarize(payloadAt: url) == "Diagnostic")
    }
}
