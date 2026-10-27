import Foundation
import Testing
@testable import VoiceDiary

// `TimeRange` is the `time_range` of an `empty_block` manifest segment
// (`server/webapp/models.py`, SPEC §10). It uses the synthesized Codable
// conformance, so the Swift property names are the wire keys, and both values
// are opaque strings: the app neither parses nor normalises them, so offsets,
// cross-midnight ranges and empty strings must pass through verbatim. These
// tests decode fixed JSON and read the encoded keys back to pin the wire
// shape independently of the type under test.

@Suite("ManifestTimeRange")
struct ManifestTimeRangeTests {
    private static let start = "2026-04-27T13:00:00+02:00"
    private static let end = "2026-04-27T14:30:00+02:00"

    private static func decode(_ json: String) throws -> TimeRange {
        try JSONDecoder().decode(TimeRange.self, from: Data(json.utf8))
    }

    private static func wireObject(_ range: TimeRange) throws -> [String: Any] {
        let data = try JSONEncoder().encode(range)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private static func decodingError(_ json: String) -> DecodingError? {
        do {
            _ = try decode(json)
            return nil
        } catch let error as DecodingError {
            return error
        } catch {
            return nil
        }
    }

    // MARK: - Initializer

    @Test("initializer keeps start and end in their own fields")
    func initializerAssignsFields() {
        let range = TimeRange(start: Self.start, end: Self.end)

        #expect(range.start == Self.start)
        #expect(range.end == Self.end)
    }

    // MARK: - Decoding

    @Test("decodes start and end from fixed JSON")
    func decodesFixedJSON() throws {
        let range = try Self.decode(
            #"{"start": "2026-04-27T13:00:00+02:00", "end": "2026-04-27T14:30:00+02:00"}"#
        )

        #expect(range.start == "2026-04-27T13:00:00+02:00")
        #expect(range.end == "2026-04-27T14:30:00+02:00")
    }

    @Test("key order in the JSON does not swap the boundaries")
    func decodesReversedKeyOrder() throws {
        let range = try Self.decode(
            #"{"end": "2026-04-27T14:30:00+02:00", "start": "2026-04-27T13:00:00+02:00"}"#
        )

        #expect(range.start == "2026-04-27T13:00:00+02:00")
        #expect(range.end == "2026-04-27T14:30:00+02:00")
    }

    @Test("extra keys are ignored")
    func ignoresExtraKeys() throws {
        let range = try Self.decode(
            #"{"start": "a", "end": "b", "timezone": "Europe/Berlin"}"#
        )

        #expect(range.start == "a")
        #expect(range.end == "b")
    }

    // MARK: - Encoding

    @Test("encodes exactly the start and end keys with their own values")
    func encodesWireValues() throws {
        let object = try Self.wireObject(TimeRange(start: Self.start, end: Self.end))

        #expect(Set(object.keys) == ["start", "end"])
        #expect(object["start"] as? String == Self.start)
        #expect(object["end"] as? String == Self.end)
    }

    // MARK: - Verbatim strings

    @Test(
        "start and end pass through verbatim, offsets and all",
        arguments: [
            // Different offsets on each side.
            ("2026-04-27T13:00:00+02:00", "2026-04-27T11:30:00Z"),
            // Cross-midnight.
            ("2026-04-27T23:30:00+02:00", "2026-04-28T00:15:00+02:00"),
            // Negative and half-hour offsets.
            ("2026-04-27T08:00:00-05:00", "2026-04-27T21:30:00+05:30"),
            // End earlier than start: the model does not validate order.
            ("2026-04-27T14:30:00+02:00", "2026-04-27T13:00:00+02:00"),
            // Not a date at all: the model does not parse.
            ("not a date", "ünïcode ✓"),
            // Empty strings.
            ("", ""),
            ("", "2026-04-27T14:30:00+02:00"),
            ("2026-04-27T13:00:00+02:00", ""),
        ]
    )
    func verbatimRoundTrip(start: String, end: String) throws {
        let original = TimeRange(start: start, end: end)

        let object = try Self.wireObject(original)
        #expect(object["start"] as? String == start)
        #expect(object["end"] as? String == end)

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TimeRange.self, from: data)
        #expect(decoded.start == start)
        #expect(decoded.end == end)
    }

    @Test("empty strings decode as empty strings, not as missing")
    func decodesEmptyStrings() throws {
        let range = try Self.decode(#"{"start": "", "end": ""}"#)

        #expect(range.start == "")
        #expect(range.end == "")
    }

    // MARK: - Decode failures

    @Test("a missing start or end fails with keyNotFound", arguments: ["start", "end"])
    func missingFieldFails(key: String) {
        let other = key == "start" ? "end" : "start"
        let error = Self.decodingError(#"{"\#(other)": "2026-04-27T13:00:00+02:00"}"#)

        guard case .keyNotFound(let missing, _)? = error else {
            Issue.record("expected keyNotFound for \(key), got \(String(describing: error))")
            return
        }
        #expect(missing.stringValue == key)
    }

    @Test("an empty object fails")
    func emptyObjectFails() {
        #expect(Self.decodingError("{}") != nil)
    }

    @Test("a null start or end fails with valueNotFound", arguments: ["start", "end"])
    func nullFieldFails(key: String) {
        let other = key == "start" ? "end" : "start"
        let error = Self.decodingError(
            #"{"\#(key)": null, "\#(other)": "2026-04-27T13:00:00+02:00"}"#
        )

        guard case .valueNotFound(_, let context)? = error else {
            Issue.record("expected valueNotFound for \(key), got \(String(describing: error))")
            return
        }
        #expect(context.codingPath.last?.stringValue == key)
    }

    @Test(
        "a non-string start or end fails with typeMismatch",
        arguments: ["start", "end"],
        ["42", "1.5", "true", "[]", #"["2026-04-27T13:00:00+02:00"]"#, "{}"]
    )
    func nonStringFieldFails(key: String, value: String) {
        let other = key == "start" ? "end" : "start"
        let error = Self.decodingError(
            #"{"\#(key)": \#(value), "\#(other)": "2026-04-27T13:00:00+02:00"}"#
        )

        guard case .typeMismatch(_, let context)? = error else {
            Issue.record("expected typeMismatch for \(key)=\(value), got \(String(describing: error))")
            return
        }
        #expect(context.codingPath.last?.stringValue == key)
    }
}
