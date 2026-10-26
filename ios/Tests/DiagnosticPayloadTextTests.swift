import Foundation
import Testing
@testable import VoiceDiary

// Detail view and share bundle text for a stored MetricKit payload. The
// collector reads the file; these tests pin how its bytes become the
// pretty-printed text, including the raw fallback.

@Suite("DiagnosticPayloadText")
struct DiagnosticPayloadTextTests {
    private static func text(_ json: String) -> String? {
        DiagnosticPayloadText.prettyPrinted(fromJSON: Data(json.utf8))
    }

    @Test("object keys are sorted and the output is pretty printed")
    func sortsKeys() {
        #expect(Self.text(#"{"b": 1, "a": 2}"#) == """
        {
          "a" : 2,
          "b" : 1
        }
        """)
    }

    @Test("nested object keys are sorted at every level")
    func sortsNestedKeys() {
        let json = #"{"z": {"y": 1, "x": {"d": true, "c": null}}, "a": []}"#
        #expect(Self.text(json) == """
        {
          "a" : [

          ],
          "z" : {
            "x" : {
              "c" : null,
              "d" : true
            },
            "y" : 1
          }
        }
        """)
    }

    @Test("arrays keep their order while objects inside them are sorted")
    func arrays() {
        let json = #"[3, {"b": 1, "a": 2}, "x"]"#
        #expect(Self.text(json) == """
        [
          3,
          {
            "a" : 2,
            "b" : 1
          },
          "x"
        ]
        """)
    }

    @Test("malformed JSON text comes back unchanged")
    func malformedJSON() {
        let truncated = #"{"b": 1, "a": "#
        #expect(Self.text(truncated) == truncated)
        let missingColon = #"{"b" 1}"#
        #expect(Self.text(missingColon) == missingColon)
        let notJSON = "not json\n"
        #expect(Self.text(notJSON) == notJSON)
    }

    @Test("empty data gives an empty string, not nil")
    func empty() {
        #expect(DiagnosticPayloadText.prettyPrinted(fromJSON: Data()) == "")
    }

    @Test("top-level fragments are not parsed, so they come back unchanged",
          arguments: ["42", #""text""#, "true", "null", "  3.5  "])
    func fragments(raw: String) {
        #expect(Self.text(raw) == raw)
    }

    @Test("invalid UTF-8 bytes give nil")
    func invalidUTF8() {
        #expect(DiagnosticPayloadText.prettyPrinted(fromJSON: Data([0xFF, 0xFE, 0xFD])) == nil)
        #expect(DiagnosticPayloadText.prettyPrinted(fromJSON: Data([0x7B, 0xC3, 0x28])) == nil)
    }

    @Test("non-ASCII text survives pretty printing")
    func unicode() {
        #expect(Self.text(#"{"k": "Grüße ✓"}"#) == """
        {
          "k" : "Grüße ✓"
        }
        """)
    }
}

@Suite("DiagnosticsCollector.readPayloadJSON(for:)")
struct DiagnosticsCollectorReadPayloadTests {
    private static func report(at url: URL) -> DiagnosticsCollector.Report {
        DiagnosticsCollector.Report(
            id: "test",
            timestamp: Date(timeIntervalSince1970: 0),
            summary: "Diagnostic",
            payloadURL: url,
            logURL: nil
        )
    }

    private static func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "DiagnosticsCollectorReadPayloadTests-\(UUID().uuidString).json")
    }

    @Test("a stored payload file is read and pretty printed")
    func readsFile() throws {
        let url = Self.tempURL()
        try Data(#"{"b": 1, "a": 2}"#.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(DiagnosticsCollector.shared.readPayloadJSON(for: Self.report(at: url)) == """
        {
          "a" : 2,
          "b" : 1
        }
        """)
    }

    @Test("a stored file that isn't JSON is returned unchanged")
    func rawFile() throws {
        let url = Self.tempURL()
        try Data("not json".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(DiagnosticsCollector.shared.readPayloadJSON(for: Self.report(at: url)) == "not json")
    }

    @Test("a missing file gives nil")
    func missingFile() {
        #expect(DiagnosticsCollector.shared.readPayloadJSON(for: Self.report(at: Self.tempURL())) == nil)
    }
}
