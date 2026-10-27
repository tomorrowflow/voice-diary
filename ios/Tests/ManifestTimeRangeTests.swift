import Foundation
import Testing
@testable import VoiceDiary

// `TimeRange` is the `time_range` of an `empty_block` manifest segment. The
// contract is SPEC §10 and `server/webapp/models.py`: an object with exactly
// two string keys, `start` and `end`, both `"HH:MM"` (SPEC example:
// `{"start": "14:00", "end": "16:00"}`). The Swift model uses the synthesized
// Codable conformance, so the property names are the wire keys.
//
// The contract tests below use `"HH:MM"` values and decode fixed JSON, then
// read the encoded keys back with `JSONSerialization`, so they pin the wire
// shape independently of the type under test.
//
// Extra keys differ by side and are not tested here: the server model is
// `extra="forbid"` and rejects unknown keys in the manifest it receives,
// while Swift's synthesized decoder ignores them. The encoder only ever
// writes `start` and `end`, so what the app sends satisfies the server's
// policy.
//
// The Swift type declares both values as plain `String`, with no parsing or
// validation. The characterization tests at the end record that current
// behaviour (offset-bearing timestamps, cross-midnight, arbitrary and empty
// strings pass through unchanged). They are not server contract examples.

@Suite("ManifestTimeRange")
struct ManifestTimeRangeTests {
    private static let start = "14:00"
    private static let end = "16:00"

    private static func decode(_ json: String) throws -> TimeRange {
        try JSONDecoder().decode(TimeRange.self, from: Data(json.utf8))
    }

    /// A `time_range` object with a valid value for the other key and
    /// `rawValue` (already JSON-encoded) for `key`.
    private static func json(_ key: String, _ rawValue: String) -> String {
        let other = key == "start" ? "end" : "start"
        return #"{"\#(key)": \#(rawValue), "\#(other)": "\#(start)"}"#
    }

    private static func wireObject(_ range: TimeRange) throws -> [String: Any] {
        let data = try JSONEncoder().encode(range)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private static func decodingError(_ json: String) throws -> DecodingError? {
        do {
            _ = try decode(json)
            return nil
        } catch let error as DecodingError {
            return error
        }
    }

    // MARK: - Contract: "HH:MM" values

    @Test("initializer keeps start and end in their own fields")
    func initializerAssignsFields() {
        let range = TimeRange(start: "14:00", end: "16:00")

        #expect(range.start == "14:00")
        #expect(range.end == "16:00")
    }

    @Test("decodes start and end from fixed JSON")
    func decodesFixedJSON() throws {
        let range = try Self.decode(#"{"start": "14:00", "end": "16:00"}"#)

        #expect(range.start == "14:00")
        #expect(range.end == "16:00")
    }

    @Test("key order in the JSON does not swap the boundaries")
    func decodesReversedKeyOrder() throws {
        let range = try Self.decode(#"{"end": "16:00", "start": "14:00"}"#)

        #expect(range.start == "14:00")
        #expect(range.end == "16:00")
    }

    @Test("encodes exactly the start and end keys with their own values")
    func encodesWireValues() throws {
        let object = try Self.wireObject(TimeRange(start: "14:00", end: "16:00"))

        #expect(Set(object.keys) == ["start", "end"])
        #expect(object["start"] as? String == "14:00")
        #expect(object["end"] as? String == "16:00")
    }

    @Test("a round trip keeps the boundaries unswapped")
    func roundTrip() throws {
        let decoded = try JSONDecoder().decode(
            TimeRange.self, from: JSONEncoder().encode(TimeRange(start: "14:00", end: "16:00"))
        )

        #expect(decoded.start == "14:00")
        #expect(decoded.end == "16:00")
    }

    // MARK: - Contract: decode failures

    @Test("a missing start or end fails with keyNotFound", arguments: ["start", "end"])
    func missingFieldFails(key: String) throws {
        let other = key == "start" ? "end" : "start"
        let error = try Self.decodingError(#"{"\#(other)": "\#(Self.start)"}"#)

        guard case .keyNotFound(let missing, _)? = error else {
            Issue.record("expected keyNotFound for \(key), got \(String(describing: error))")
            return
        }
        #expect(missing.stringValue == key)
    }

    @Test("a null start or end fails with valueNotFound", arguments: ["start", "end"])
    func nullFieldFails(key: String) throws {
        let error = try Self.decodingError(Self.json(key, "null"))

        guard case .valueNotFound(_, let context)? = error else {
            Issue.record("expected valueNotFound for \(key), got \(String(describing: error))")
            return
        }
        #expect(context.codingPath.last?.stringValue == key)
    }

    @Test(
        "a non-string start or end fails with typeMismatch",
        arguments: ["start", "end"],
        ["42", "1.5", "true", "[]", #"["14:00"]"#, "{}"]
    )
    func nonStringFieldFails(key: String, value: String) throws {
        let error = try Self.decodingError(Self.json(key, value))

        guard case .typeMismatch(_, let context)? = error else {
            Issue.record("expected typeMismatch for \(key)=\(value), got \(String(describing: error))")
            return
        }
        #expect(context.codingPath.last?.stringValue == key)
    }

    // MARK: - Characterization: the Swift model treats values as opaque strings

    @Test(
        "characterization: any string passes through verbatim",
        arguments: [
            // Offset-bearing timestamps, different offsets on each side.
            ("2026-04-27T13:00:00+02:00", "2026-04-27T11:30:00Z"),
            // Cross-midnight.
            ("2026-04-27T23:30:00+02:00", "2026-04-28T00:15:00+02:00"),
            ("23:30", "00:15"),
            // Negative and half-hour offsets.
            ("2026-04-27T08:00:00-05:00", "2026-04-27T21:30:00+05:30"),
            // End earlier than start: the model does not validate order.
            ("16:00", "14:00"),
            // Not a time at all: the model does not parse.
            ("not a time", "ünïcode ✓"),
            // Empty strings.
            ("", ""),
            ("", "16:00"),
            ("14:00", ""),
        ]
    )
    func opaqueStringsPassThrough(start: String, end: String) throws {
        let original = TimeRange(start: start, end: end)

        let object = try Self.wireObject(original)
        #expect(object["start"] as? String == start)
        #expect(object["end"] as? String == end)

        let decoded = try JSONDecoder().decode(
            TimeRange.self, from: JSONEncoder().encode(original)
        )
        #expect(decoded.start == start)
        #expect(decoded.end == end)
    }

    @Test("characterization: empty strings decode as empty strings, not as missing")
    func decodesEmptyStrings() throws {
        let range = try Self.decode(#"{"start": "", "end": ""}"#)

        #expect(range.start == "")
        #expect(range.end == "")
    }
}
