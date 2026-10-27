import Foundation
import Testing
@testable import VoiceDiary

// `CalendarEventSegment` is the `calendar_event` manifest segment (SPEC §10.3):
// one calendar meeting's recording, with the todos detected in it and the seeds
// it answers. The server's `CalendarEventSegment` (`server/webapp/models.py`)
// defaults `todos_detected` and `linked_seed_ids` to empty lists, but the Swift
// model uses the synthesized Codable conformance, so both arrays are required
// on decode (the initializer defaults only apply in code) and the property
// names are the wire keys.
//
// Decoding tests read fixed literal JSON written independently of the encoder;
// encoding tests read the keys back with `JSONSerialization`. `CalendarRef` and
// `Todo` have their own suites, so only their position and order inside the
// segment are checked here.

@Suite("CalendarEventSegmentWire")
struct CalendarEventSegmentWireTests {
    private static let outerKeys: Set<String> = [
        "segment_type", "segment_id", "calendar_ref", "audio_file", "transcript",
        "language", "todos_detected", "linked_seed_ids",
    ]
    private static let requiredKeys = outerKeys.subtracting(["segment_type"]).sorted()
    private static let arrayKeys = ["todos_detected", "linked_seed_ids"]

    private static let fullJSON = """
    {
      "segment_type": "calendar_event",
      "segment_id": "seg-c4",
      "calendar_ref": {
        "graph_event_id": "AAMkAD-cal-4=",
        "title": "Quarterly review",
        "start": "2026-04-27T09:00:00+02:00",
        "end": "2026-04-27T10:00:00+02:00",
        "attendees": ["ana@example.org"],
        "rsvp_status": "organizer"
      },
      "audio_file": "segments/c4.m4a",
      "transcript": "We agreed to ship on Friday.",
      "language": "en-GB",
      "todos_detected": [
        {"text": "Send the deck", "type": "explicit", "due": "2026-04-30",
         "status": "Offen", "source_segment_id": "seg-origin-1", "source_quote": "send the deck"},
        {"text": "Book the room", "type": "implicit", "status": "Erledigt"},
        {"text": "Ping Ana", "type": "explicit", "due": null, "status": "Offen"}
      ],
      "linked_seed_ids": ["seed-9", "seed-2", "seed-5"]
    }
    """

    /// The values in `fullJSON`.
    private static let fullSegment = CalendarEventSegment(
        segment_id: "seg-c4",
        calendar_ref: CalendarRef(
            graph_event_id: "AAMkAD-cal-4=", title: "Quarterly review",
            start: "2026-04-27T09:00:00+02:00", end: "2026-04-27T10:00:00+02:00",
            attendees: ["ana@example.org"], rsvp_status: "organizer"
        ),
        audio_file: "segments/c4.m4a",
        transcript: "We agreed to ship on Friday.",
        language: "en-GB",
        todos_detected: [
            Todo(
                text: "Send the deck", type: "explicit", due: "2026-04-30", status: "Offen",
                source_segment_id: "seg-origin-1", source_quote: "send the deck"
            ),
            Todo(text: "Book the room", type: "implicit", status: "Erledigt"),
            Todo(text: "Ping Ana", type: "explicit", status: "Offen"),
        ],
        linked_seed_ids: ["seed-9", "seed-2", "seed-5"]
    )

    private static func data(_ json: String) -> Data { Data(json.utf8) }

    private static func fullJSONObject() throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: data(fullJSON)) as? [String: Any])
    }

    private static func fullJSONData(without key: String) throws -> Data {
        var object = try fullJSONObject()
        object[key] = nil
        return try JSONSerialization.data(withJSONObject: object)
    }

    /// Asserts `segment` holds the `fullJSON` values, with the todos and seed ids in order.
    private static func expectFullFields(
        _ segment: CalendarEventSegment, sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(segment.segment_id == "seg-c4", sourceLocation: sourceLocation)
        #expect(segment.calendar_ref.graph_event_id == "AAMkAD-cal-4=", sourceLocation: sourceLocation)
        #expect(segment.audio_file == "segments/c4.m4a", sourceLocation: sourceLocation)
        #expect(segment.transcript == "We agreed to ship on Friday.", sourceLocation: sourceLocation)
        #expect(segment.language == "en-GB", sourceLocation: sourceLocation)
        #expect(
            segment.todos_detected.map(\.text) == ["Send the deck", "Book the room", "Ping Ana"],
            sourceLocation: sourceLocation
        )
        #expect(segment.linked_seed_ids == ["seed-9", "seed-2", "seed-5"], sourceLocation: sourceLocation)
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

    // MARK: - Decoding

    @Test("decodes every outer field, the ordered todos and the ordered seed ids from fixed JSON")
    func decodesFullJSON() throws {
        let segment = try JSONDecoder().decode(
            CalendarEventSegment.self, from: Self.data(Self.fullJSON)
        )

        Self.expectFullFields(segment)
        #expect(segment.calendar_ref.title == "Quarterly review")
        #expect(segment.todos_detected.map(\.type) == ["explicit", "implicit", "explicit"])
        #expect(segment.todos_detected.map(\.due) == ["2026-04-30", nil, nil])
        #expect(segment.todos_detected.map(\.status) == ["Offen", "Erledigt", "Offen"])
        #expect(segment.todos_detected.map(\.source_segment_id) == ["seg-origin-1", nil, nil])
        #expect(segment.todos_detected.map(\.source_quote) == ["send the deck", nil, nil])
    }

    @Test("decodes empty todos_detected and linked_seed_ids as empty arrays")
    func decodesEmptyArrays() throws {
        var object = try Self.fullJSONObject()
        object["todos_detected"] = [Any]()
        object["linked_seed_ids"] = [Any]()

        let segment = try JSONDecoder().decode(
            CalendarEventSegment.self, from: JSONSerialization.data(withJSONObject: object)
        )

        #expect(segment.todos_detected.isEmpty)
        #expect(segment.linked_seed_ids.isEmpty)
        #expect(segment.segment_id == "seg-c4")
    }

    @Test("a missing required field fails with keyNotFound", arguments: requiredKeys)
    func missingRequiredFieldFails(key: String) throws {
        let json = try Self.fullJSONData(without: key)

        #expect(Self.missingKey(decoding: CalendarEventSegment.self, from: json) == key)
    }

    @Test(
        "a missing todos_detected or linked_seed_ids also rejects the whole Segment",
        arguments: arrayKeys
    )
    func missingArrayRejectsSegment(key: String) throws {
        let json = try Self.fullJSONData(without: key)

        #expect(Self.missingKey(decoding: Segment.self, from: json) == key)
    }

    // MARK: - Encoding

    @Test("encodes exactly the wire fields with their own values")
    func encodesWireFields() throws {
        let object = try Self.wireObject(Self.fullSegment)

        #expect(Set(object.keys) == Self.outerKeys)
        #expect(object["segment_type"] as? String == "calendar_event")
        #expect(object["segment_id"] as? String == "seg-c4")
        #expect(object["audio_file"] as? String == "segments/c4.m4a")
        #expect(object["transcript"] as? String == "We agreed to ship on Friday.")
        #expect(object["language"] as? String == "en-GB")
        let calendarRef = try #require(object["calendar_ref"] as? [String: Any])
        #expect(calendarRef["graph_event_id"] as? String == "AAMkAD-cal-4=")
        let todos = try #require(object["todos_detected"] as? [[String: Any]])
        #expect(todos.map { $0["text"] as? String } == ["Send the deck", "Book the room", "Ping Ana"])
        #expect(object["linked_seed_ids"] as? [String] == ["seed-9", "seed-2", "seed-5"])
    }

    @Test("the initializer defaults to an empty transcript, de-DE and empty arrays that still encode")
    func initializerDefaultsEncode() throws {
        let segment = CalendarEventSegment(
            segment_id: "seg-c5",
            calendar_ref: CalendarRef(graph_event_id: "g5", title: "t", start: "s", end: "e"),
            audio_file: "segments/c5.m4a"
        )

        let object = try Self.wireObject(segment)

        #expect(segment.transcript == "")
        #expect(segment.language == "de-DE")
        #expect(segment.todos_detected.isEmpty)
        #expect(segment.linked_seed_ids.isEmpty)
        #expect(Set(object.keys) == Self.outerKeys)
        #expect(object["transcript"] as? String == "")
        #expect(object["language"] as? String == "de-DE")
        #expect((object["todos_detected"] as? [Any])?.isEmpty == true)
        #expect((object["linked_seed_ids"] as? [Any])?.isEmpty == true)
    }

    @Test("a Unicode transcript and a custom language encode verbatim")
    func unicodeTranscriptAndLanguageEncode() throws {
        let expected = "Wir treffen uns „später“ 🌙 – 感謝\nZeile \"zwei\""
        let segment = CalendarEventSegment(
            segment_id: "seg-c6",
            calendar_ref: CalendarRef(graph_event_id: "g6", title: "t", start: "s", end: "e"),
            audio_file: "segments/c6.m4a",
            transcript: expected,
            language: "de-CH"
        )

        let object = try Self.wireObject(segment)

        let transcript = try #require(object["transcript"] as? String)
        #expect(Array(transcript.utf8) == Array(expected.utf8))
        #expect(object["language"] as? String == "de-CH")
    }

    // MARK: - Round trips

    @Test("a Segment round trip keeps every field and the calendar_event discriminator")
    func segmentRoundTrip() throws {
        let segment = Segment.calendarEvent(Self.fullSegment)

        let object = try Self.wireObject(segment)
        #expect(Set(object.keys) == Self.outerKeys)
        #expect(object["segment_type"] as? String == "calendar_event")

        let decoded = try JSONDecoder().decode(Segment.self, from: JSONEncoder().encode(segment))
        guard case .calendarEvent(let payload) = decoded else {
            Issue.record("calendar_event should decode to .calendarEvent, got \(decoded)")
            return
        }
        Self.expectFullFields(payload)
        #expect(decoded.segmentID == "seg-c4")
        #expect(decoded.audioFile == "segments/c4.m4a")
    }
}
