import Foundation
import Testing
@testable import VoiceDiary

// `VoiceNoteSegment` is the `drive_by` member of `Segment` (SPEC §10). It uses
// the synthesized Codable conformance, so the Swift property names are the wire
// keys, nil links are left out of the encoded JSON, and `segment_id`,
// `captured_at`, `audio_file`, `transcript` and `language` are required on
// decode (the initializer defaults do not apply there). `captured_at` is an
// opaque string: no date parsing or validation. `linked_calendar_event_id` and
// `seed_id` are independent optional links. These tests decode fixed JSON
// written independently of the encoder and inspect the encoded keys and values.

@Suite("VoiceNoteSegmentWire")
struct VoiceNoteSegmentWireTests {
    private static func note(links: String) -> String {
        """
        {
          "segment_type": "drive_by",
          "segment_id": "n01",
          "captured_at": "2026-04-24T09:15:00+02:00",
          "audio_file": "segments/n01.m4a",
          "transcript": "Kurz notiert",
          "language": "de-DE"\(links)
        }
        """
    }

    private static let populatedNote = VoiceNoteSegment(
        segment_id: "n01",
        captured_at: "2026-04-24T09:15:00+02:00",
        audio_file: "segments/n01.m4a",
        transcript: "Der Tag war „lang“ 🌙",
        language: "en-US",
        linked_calendar_event_id: "evt-42",
        seed_id: "seed-7"
    )

    private static func decode(_ json: String) throws -> VoiceNoteSegment {
        try JSONDecoder().decode(VoiceNoteSegment.self, from: Data(json.utf8))
    }

    private static func encodedObject(_ value: some Encodable) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test("Initializer defaults to an empty German transcript with no links")
    func initializerDefaults() {
        let note = VoiceNoteSegment(
            segment_id: "n01", captured_at: "2026-04-24T09:15:00+02:00", audio_file: "segments/n01.m4a"
        )

        #expect(note.segment_type == "drive_by")
        #expect(note.segment_id == "n01")
        #expect(note.captured_at == "2026-04-24T09:15:00+02:00")
        #expect(note.audio_file == "segments/n01.m4a")
        #expect(note.transcript == "")
        #expect(note.language == "de-DE")
        #expect(note.linked_calendar_event_id == nil)
        #expect(note.seed_id == nil)
    }

    @Test("Decodes every populated field verbatim, both links included")
    func decodesPopulatedFields() throws {
        let json = """
            {
              "segment_type": "drive_by",
              "segment_id": "n01",
              "captured_at": "2026-04-24T09:15:00+02:00",
              "audio_file": "segments/n01.m4a",
              "transcript": "Der Tag war „lang“ 🌙",
              "language": "en-US",
              "linked_calendar_event_id": "evt-42",
              "seed_id": "seed-7"
            }
            """

        let note = try Self.decode(json)

        #expect(note.segment_id == "n01")
        #expect(note.captured_at == "2026-04-24T09:15:00+02:00")
        #expect(note.audio_file == "segments/n01.m4a")
        #expect(note.transcript == "Der Tag war „lang“ 🌙")
        #expect(note.language == "en-US")
        #expect(note.linked_calendar_event_id == "evt-42")
        #expect(note.seed_id == "seed-7")
    }

    @Test(
        "Each link decodes independently as absent, null or populated",
        arguments: [
            ("", nil, nil),
            (#", "linked_calendar_event_id": null, "seed_id": null"#, nil, nil),
            (#", "linked_calendar_event_id": "evt-42""#, "evt-42", nil),
            (#", "seed_id": "seed-7""#, nil, "seed-7"),
            (#", "linked_calendar_event_id": "evt-42", "seed_id": null"#, "evt-42", nil),
            (#", "linked_calendar_event_id": null, "seed_id": "seed-7""#, nil, "seed-7"),
            (#", "linked_calendar_event_id": "evt-42", "seed_id": "seed-7""#, "evt-42", "seed-7"),
        ] as [(String, String?, String?)]
    )
    func decodesLinksIndependently(links: String, event: String?, seed: String?) throws {
        let note = try Self.decode(Self.note(links: links))

        #expect(note.linked_calendar_event_id == event)
        #expect(note.seed_id == seed)
        #expect(note.segment_id == "n01")
        #expect(note.captured_at == "2026-04-24T09:15:00+02:00")
        #expect(note.audio_file == "segments/n01.m4a")
        #expect(note.transcript == "Kurz notiert")
        #expect(note.language == "de-DE")
    }

    @Test(
        "captured_at stays an opaque string, whatever its shape",
        arguments: ["not a date", "", "2026-04-24", "2026-04-24T07:15:00.123Z", "2026-04-24 09:15"]
    )
    func capturedAtIsOpaque(capturedAt: String) throws {
        let json = """
            {"segment_id": "n01", "captured_at": "\(capturedAt)", "audio_file": "a.m4a",
             "transcript": "", "language": "de-DE"}
            """

        let note = try Self.decode(json)
        let object = try Self.encodedObject(note)

        #expect(note.captured_at == capturedAt)
        #expect(object["captured_at"] as? String == capturedAt)
    }

    @Test(
        "Decoding rejects JSON missing a required key, naming that key",
        arguments: [
            (
                #"{"captured_at": "t", "audio_file": "a.m4a", "transcript": "", "language": "de-DE"}"#,
                "segment_id"
            ),
            (#"{"segment_id": "n01", "audio_file": "a.m4a", "transcript": "", "language": "de-DE"}"#, "captured_at"),
            (#"{"segment_id": "n01", "captured_at": "t", "transcript": "", "language": "de-DE"}"#, "audio_file"),
            (#"{"segment_id": "n01", "captured_at": "t", "audio_file": "a.m4a", "language": "de-DE"}"#, "transcript"),
            (#"{"segment_id": "n01", "captured_at": "t", "audio_file": "a.m4a", "transcript": ""}"#, "language"),
        ]
    )
    func decodingRequiresMissingKey(json: String, missingKey: String) {
        #expect {
            try Self.decode(json)
        } throws: { error in
            guard case DecodingError.keyNotFound(let key, _) = error else { return false }
            return key.stringValue == missingKey
        }
    }

    @Test("Decoding rejects a null captured_at")
    func decodingRejectsNullCapturedAt() {
        let json = """
            {"segment_id": "n01", "captured_at": null, "audio_file": "a.m4a",
             "transcript": "", "language": "de-DE"}
            """

        #expect(throws: DecodingError.self) { try Self.decode(json) }
    }

    @Test("Encodes exact drive_by keys with a Unicode transcript, custom language and both links")
    func encodesPopulatedFields() throws {
        let object = try Self.encodedObject(Self.populatedNote)

        #expect(
            Set(object.keys) == [
                "segment_type", "segment_id", "captured_at", "audio_file", "transcript", "language",
                "linked_calendar_event_id", "seed_id",
            ]
        )
        #expect(object["segment_type"] as? String == "drive_by")
        #expect(object["segment_id"] as? String == "n01")
        #expect(object["captured_at"] as? String == "2026-04-24T09:15:00+02:00")
        #expect(object["audio_file"] as? String == "segments/n01.m4a")
        #expect(object["transcript"] as? String == "Der Tag war „lang“ 🌙")
        #expect(object["language"] as? String == "en-US")
        #expect(object["linked_calendar_event_id"] as? String == "evt-42")
        #expect(object["seed_id"] as? String == "seed-7")
    }

    @Test("Encoding writes default transcript and language and omits nil links")
    func encodingOmitsNilLinks() throws {
        let object = try Self.encodedObject(
            VoiceNoteSegment(
                segment_id: "n01", captured_at: "2026-04-24T09:15:00+02:00", audio_file: "segments/n01.m4a"
            )
        )

        #expect(
            Set(object.keys) == ["segment_type", "segment_id", "captured_at", "audio_file", "transcript", "language"]
        )
        #expect(object["transcript"] as? String == "")
        #expect(object["language"] as? String == "de-DE")
    }

    @Test(
        "Encoding omits only the link that is nil",
        arguments: [
            ("evt-42", nil, "linked_calendar_event_id", "seed_id"),
            (nil, "seed-7", "seed_id", "linked_calendar_event_id"),
        ] as [(String?, String?, String, String)]
    )
    func encodingKeepsOneLink(
        event: String?, seed: String?, presentKey: String, omittedKey: String
    ) throws {
        let object = try Self.encodedObject(
            VoiceNoteSegment(
                segment_id: "n01",
                captured_at: "2026-04-24T09:15:00+02:00",
                audio_file: "segments/n01.m4a",
                linked_calendar_event_id: event,
                seed_id: seed
            )
        )

        #expect(object[presentKey] as? String == (event ?? seed))
        #expect(object[omittedKey] == nil)
    }

    @Test("A fully populated note round-trips through Segment with every field intact")
    func roundTripsThroughSegment() throws {
        let data = try JSONEncoder().encode(Segment.voiceNote(Self.populatedNote))
        let decoded = try JSONDecoder().decode(Segment.self, from: data)

        guard case .voiceNote(let note) = decoded else {
            Issue.record("expected .voiceNote")
            return
        }
        #expect(note.segment_id == "n01")
        #expect(note.captured_at == "2026-04-24T09:15:00+02:00")
        #expect(note.audio_file == "segments/n01.m4a")
        #expect(note.transcript == "Der Tag war „lang“ 🌙")
        #expect(note.language == "en-US")
        #expect(note.linked_calendar_event_id == "evt-42")
        #expect(note.seed_id == "seed-7")
    }

    @Test(
        "Decoded nil links stay omitted when re-encoded through Segment",
        arguments: ["", #", "linked_calendar_event_id": null, "seed_id": null"#]
    )
    func nilLinksStayOmittedThroughSegment(links: String) throws {
        let segment = try JSONDecoder().decode(Segment.self, from: Data(Self.note(links: links).utf8))

        let object = try Self.encodedObject(segment)

        #expect(object["linked_calendar_event_id"] == nil)
        #expect(object["seed_id"] == nil)
        #expect(object["segment_type"] as? String == "drive_by")
        #expect(object["captured_at"] as? String == "2026-04-24T09:15:00+02:00")
    }
}
