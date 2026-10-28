import Foundation
import Testing
@testable import VoiceDiary

// `EmptyBlockSegment` is the `empty_block` manifest segment (SPEC §10): audio
// recorded for a free calendar block. The server's `EmptyBlockSegment`
// (`server/webapp/models.py`) is a `SegmentBase` (`segment_id`, `audio_file`,
// `transcript` defaulting to "", `language` defaulting to "de-DE") plus a
// required `time_range` of "HH:MM" `start` and `end`. The Swift model uses the
// synthesized Codable conformance, so the property names are the wire keys, and
// the initializer defaults do not make `transcript` or `language` optional on
// decode.
//
// Decoding tests read fixed literal JSON and encoding tests read the keys back
// with `JSONSerialization`, so the wire shape is pinned independently of the
// type under test. The "HH:MM" format of `time_range` is not validated by the
// model and these tests do not add that; see `ManifestTimeRangeTests` for how
// `TimeRange` handles arbitrary strings.

@Suite("EmptyBlockSegmentWire")
struct EmptyBlockSegmentWireTests {
    private static let requiredKeys = ["segment_id", "time_range", "audio_file", "transcript", "language"]

    private static let fullJSON = """
    {
      "segment_type": "empty_block",
      "segment_id": "seg-e1",
      "time_range": {"start": "09:30", "end": "11:45"},
      "audio_file": "segments/e1.m4a",
      "transcript": "Ruhiger Vormittag – 静かな朝 ☕️",
      "language": "ja-JP"
    }
    """

    /// The values in `fullJSON`.
    private static let fullSegment = EmptyBlockSegment(
        segment_id: "seg-e1",
        time_range: TimeRange(start: "09:30", end: "11:45"),
        audio_file: "segments/e1.m4a",
        transcript: "Ruhiger Vormittag – 静かな朝 ☕️",
        language: "ja-JP"
    )

    private static func data(_ json: String) -> Data { Data(json.utf8) }

    private static func fullJSONData(without key: String) throws -> Data {
        var object = try #require(
            try JSONSerialization.jsonObject(with: data(fullJSON)) as? [String: Any]
        )
        object[key] = nil
        return try JSONSerialization.data(withJSONObject: object)
    }

    private static func wireObject(_ value: some Encodable) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// The `keyNotFound` key from decoding `json` as `type`, or nil if decoding
    /// succeeds or fails differently.
    private static func missingKey<T: Decodable>(decoding type: T.Type, from json: Data) -> String? {
        do {
            _ = try JSONDecoder().decode(type, from: json)
            return nil
        } catch DecodingError.keyNotFound(let key, _) {
            return key.stringValue
        } catch {
            return nil
        }
    }

    /// Asserts `segment` holds the `fullJSON` values.
    private static func expectFullFields(
        _ segment: EmptyBlockSegment, sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(segment.segment_type == "empty_block", sourceLocation: sourceLocation)
        #expect(segment.segment_id == "seg-e1", sourceLocation: sourceLocation)
        #expect(segment.time_range.start == "09:30", sourceLocation: sourceLocation)
        #expect(segment.time_range.end == "11:45", sourceLocation: sourceLocation)
        #expect(segment.audio_file == "segments/e1.m4a", sourceLocation: sourceLocation)
        #expect(
            Array(segment.transcript.utf8) == Array("Ruhiger Vormittag – 静かな朝 ☕️".utf8),
            sourceLocation: sourceLocation
        )
        #expect(segment.language == "ja-JP", sourceLocation: sourceLocation)
    }

    // MARK: - Decoding

    @Test("decodes every field from fixed JSON, with distinct start and end")
    func decodesFullJSON() throws {
        let segment = try JSONDecoder().decode(
            EmptyBlockSegment.self, from: Self.data(Self.fullJSON)
        )

        Self.expectFullFields(segment)
    }

    @Test("decodes an empty transcript and a de-DE language as written")
    func decodesEmptyTranscriptAndDefaultLanguage() throws {
        let json = """
        {"segment_type": "empty_block", "segment_id": "seg-e2",
         "time_range": {"start": "13:00", "end": "14:00"},
         "audio_file": "segments/e2.m4a", "transcript": "", "language": "de-DE"}
        """

        let segment = try JSONDecoder().decode(EmptyBlockSegment.self, from: Self.data(json))

        #expect(segment.transcript == "")
        #expect(segment.language == "de-DE")
    }

    @Test("a missing required field fails with keyNotFound", arguments: requiredKeys)
    func missingRequiredFieldFails(key: String) throws {
        let json = try Self.fullJSONData(without: key)

        #expect(Self.missingKey(decoding: EmptyBlockSegment.self, from: json) == key)
    }

    @Test("a missing required field also rejects the whole Segment", arguments: requiredKeys)
    func missingRequiredFieldRejectsSegment(key: String) throws {
        let json = try Self.fullJSONData(without: key)

        #expect(Self.missingKey(decoding: Segment.self, from: json) == key)
    }

    @Test("a missing time_range start or end fails with keyNotFound", arguments: ["start", "end"])
    func missingTimeRangeBoundFails(key: String) throws {
        var object = try #require(
            try JSONSerialization.jsonObject(with: Self.data(Self.fullJSON)) as? [String: Any]
        )
        var timeRange = try #require(object["time_range"] as? [String: Any])
        timeRange[key] = nil
        object["time_range"] = timeRange
        let json = try JSONSerialization.data(withJSONObject: object)

        #expect(Self.missingKey(decoding: EmptyBlockSegment.self, from: json) == key)
    }

    // MARK: - Encoding

    @Test("encodes exactly the wire fields with their own values")
    func encodesWireFields() throws {
        let object = try Self.wireObject(Self.fullSegment)

        #expect(Set(object.keys) == [
            "segment_type", "segment_id", "time_range", "audio_file", "transcript", "language",
        ])
        #expect(object["segment_type"] as? String == "empty_block")
        #expect(object["segment_id"] as? String == "seg-e1")
        #expect(object["audio_file"] as? String == "segments/e1.m4a")
        #expect(object["transcript"] as? String == "Ruhiger Vormittag – 静かな朝 ☕️")
        #expect(object["language"] as? String == "ja-JP")
    }

    @Test("encodes time_range as a nested object with exactly start and end")
    func encodesNestedTimeRange() throws {
        let object = try Self.wireObject(Self.fullSegment)

        let timeRange = try #require(object["time_range"] as? [String: Any])
        #expect(Set(timeRange.keys) == ["start", "end"])
        #expect(timeRange["start"] as? String == "09:30")
        #expect(timeRange["end"] as? String == "11:45")
    }

    @Test("the initializer defaults the transcript to empty and the language to de-DE")
    func initializerDefaultsEncode() throws {
        let segment = EmptyBlockSegment(
            segment_id: "seg-e2",
            time_range: TimeRange(start: "13:00", end: "14:00"),
            audio_file: "segments/e2.m4a"
        )

        let object = try Self.wireObject(segment)

        #expect(segment.transcript == "")
        #expect(segment.language == "de-DE")
        #expect(object.count == 6)
        #expect(object["transcript"] as? String == "")
        #expect(object["language"] as? String == "de-DE")
    }

    // MARK: - Round trips

    @Test("a round trip keeps every field")
    func roundTrip() throws {
        let decoded = try JSONDecoder().decode(
            EmptyBlockSegment.self, from: JSONEncoder().encode(Self.fullSegment)
        )

        Self.expectFullFields(decoded)
    }

    @Test("a Segment round trip keeps every field and the empty_block discriminator")
    func segmentRoundTrip() throws {
        let segment = Segment.emptyBlock(Self.fullSegment)

        let object = try Self.wireObject(segment)
        #expect(object.count == 6)
        #expect(object["segment_type"] as? String == "empty_block")

        let decoded = try JSONDecoder().decode(Segment.self, from: JSONEncoder().encode(segment))
        guard case .emptyBlock(let payload) = decoded else {
            Issue.record("empty_block should decode to .emptyBlock, got \(decoded)")
            return
        }
        Self.expectFullFields(payload)
        #expect(decoded.segmentID == "seg-e1")
        #expect(decoded.audioFile == "segments/e1.m4a")
    }

    @Test("fixed JSON decoded as a Segment reaches the empty_block case with all fields")
    func segmentDecodesFixedJSON() throws {
        let decoded = try JSONDecoder().decode(Segment.self, from: Self.data(Self.fullJSON))

        guard case .emptyBlock(let payload) = decoded else {
            Issue.record("empty_block should decode to .emptyBlock, got \(decoded)")
            return
        }
        Self.expectFullFields(payload)
    }
}
