import Foundation
import Testing
@testable import VoiceDiary

// `FreeReflectionSegment` is the `free_reflection` member of `Segment`
// (SPEC §10). It uses the synthesized Codable conformance, so the Swift
// property names are the wire keys, a nil `captured_at` is left out of the
// encoded JSON, and `segment_id`, `audio_file`, `transcript` and `language`
// are required on decode (the initializer defaults do not apply there).
// `captured_at` is an opaque string here: no date parsing or validation.
// These tests decode fixed JSON written independently of the encoder, encode
// and inspect the resulting keys and values, and round-trip through `Segment`.

@Suite("FreeReflectionWire")
struct FreeReflectionWireTests {
    private static let populated = """
        {
          "segment_type": "free_reflection",
          "segment_id": "s07",
          "captured_at": "2026-04-24T19:42:00+02:00",
          "audio_file": "segments/s07.m4a",
          "transcript": "Der Tag war „lang“ 🌙",
          "language": "en-US"
        }
        """

    private static let nullCapturedAt = """
        {
          "segment_type": "free_reflection",
          "segment_id": "s07",
          "captured_at": null,
          "audio_file": "segments/s07.m4a",
          "transcript": "Der Tag war lang",
          "language": "de-DE"
        }
        """

    private static let absentCapturedAt = """
        {
          "segment_type": "free_reflection",
          "segment_id": "s07",
          "audio_file": "segments/s07.m4a",
          "transcript": "Der Tag war lang",
          "language": "de-DE"
        }
        """

    private static func encodedObject(_ value: some Encodable) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test("Initializer defaults to an empty German transcript without a timestamp")
    func initializerDefaults() {
        let reflection = FreeReflectionSegment(segment_id: "s07", audio_file: "segments/s07.m4a")

        #expect(reflection.segment_type == "free_reflection")
        #expect(reflection.segment_id == "s07")
        #expect(reflection.audio_file == "segments/s07.m4a")
        #expect(reflection.transcript == "")
        #expect(reflection.language == "de-DE")
        #expect(reflection.captured_at == nil)
    }

    @Test("Decodes every populated field verbatim")
    func decodesPopulatedFields() throws {
        let reflection = try JSONDecoder().decode(
            FreeReflectionSegment.self, from: Data(Self.populated.utf8)
        )

        #expect(reflection.segment_id == "s07")
        #expect(reflection.captured_at == "2026-04-24T19:42:00+02:00")
        #expect(reflection.audio_file == "segments/s07.m4a")
        #expect(reflection.transcript == "Der Tag war „lang“ 🌙")
        #expect(reflection.language == "en-US")
    }

    @Test(
        "Decodes absent and null captured_at as nil",
        arguments: [absentCapturedAt, nullCapturedAt]
    )
    func decodesMissingCapturedAt(json: String) throws {
        let reflection = try JSONDecoder().decode(FreeReflectionSegment.self, from: Data(json.utf8))

        #expect(reflection.captured_at == nil)
        #expect(reflection.segment_id == "s07")
        #expect(reflection.audio_file == "segments/s07.m4a")
        #expect(reflection.transcript == "Der Tag war lang")
        #expect(reflection.language == "de-DE")
    }

    @Test("captured_at stays an opaque string, whatever its shape")
    func capturedAtIsOpaque() throws {
        let json = """
            {"segment_id": "s07", "captured_at": "not a date", "audio_file": "a.m4a",
             "transcript": "", "language": "de-DE"}
            """

        let reflection = try JSONDecoder().decode(FreeReflectionSegment.self, from: Data(json.utf8))
        let object = try Self.encodedObject(reflection)

        #expect(reflection.captured_at == "not a date")
        #expect(object["captured_at"] as? String == "not a date")
    }

    @Test(
        "Decoding rejects JSON missing a required key, naming that key",
        arguments: [
            (#"{"audio_file": "a.m4a", "transcript": "", "language": "de-DE"}"#, "segment_id"),
            (#"{"segment_id": "s07", "transcript": "", "language": "de-DE"}"#, "audio_file"),
            (#"{"segment_id": "s07", "audio_file": "a.m4a", "language": "de-DE"}"#, "transcript"),
            (#"{"segment_id": "s07", "audio_file": "a.m4a", "transcript": ""}"#, "language"),
        ]
    )
    func decodingRequiresMissingKey(json: String, missingKey: String) {
        #expect {
            try JSONDecoder().decode(FreeReflectionSegment.self, from: Data(json.utf8))
        } throws: { error in
            guard case DecodingError.keyNotFound(let key, _) = error else { return false }
            return key.stringValue == missingKey
        }
    }

    @Test("Encodes every populated field under its snake_case wire key")
    func encodesPopulatedFields() throws {
        let object = try Self.encodedObject(
            FreeReflectionSegment(
                segment_id: "s07",
                audio_file: "segments/s07.m4a",
                transcript: "Der Tag war „lang“ 🌙",
                language: "en-US",
                captured_at: "2026-04-24T19:42:00+02:00"
            )
        )

        #expect(
            Set(object.keys)
                == ["segment_type", "segment_id", "captured_at", "audio_file", "transcript", "language"]
        )
        #expect(object["segment_type"] as? String == "free_reflection")
        #expect(object["segment_id"] as? String == "s07")
        #expect(object["captured_at"] as? String == "2026-04-24T19:42:00+02:00")
        #expect(object["audio_file"] as? String == "segments/s07.m4a")
        #expect(object["transcript"] as? String == "Der Tag war „lang“ 🌙")
        #expect(object["language"] as? String == "en-US")
    }

    @Test("Encoding writes default transcript and language and omits a nil captured_at")
    func encodingOmitsNilCapturedAt() throws {
        let object = try Self.encodedObject(
            FreeReflectionSegment(segment_id: "s07", audio_file: "segments/s07.m4a")
        )

        #expect(
            Set(object.keys)
                == ["segment_type", "segment_id", "audio_file", "transcript", "language"]
        )
        #expect(object["transcript"] as? String == "")
        #expect(object["language"] as? String == "de-DE")
    }

    @Test("A fully populated segment round-trips through Segment with every field intact")
    func roundTripsThroughSegment() throws {
        let original = FreeReflectionSegment(
            segment_id: "s07",
            audio_file: "segments/s07.m4a",
            transcript: "Der Tag war „lang“ 🌙",
            language: "en-US",
            captured_at: "2026-04-24T19:42:00+02:00"
        )

        let data = try JSONEncoder().encode(Segment.freeReflection(original))
        let decoded = try JSONDecoder().decode(Segment.self, from: data)

        guard case .freeReflection(let reflection) = decoded else {
            Issue.record("expected .freeReflection")
            return
        }
        #expect(reflection.segment_id == "s07")
        #expect(reflection.captured_at == "2026-04-24T19:42:00+02:00")
        #expect(reflection.audio_file == "segments/s07.m4a")
        #expect(reflection.transcript == "Der Tag war „lang“ 🌙")
        #expect(reflection.language == "en-US")
    }

    @Test(
        "A decoded nil captured_at stays omitted when re-encoded through Segment",
        arguments: [absentCapturedAt, nullCapturedAt]
    )
    func nilCapturedAtStaysOmittedThroughSegment(json: String) throws {
        let segment = try JSONDecoder().decode(Segment.self, from: Data(json.utf8))

        let object = try Self.encodedObject(segment)

        #expect(object["captured_at"] == nil)
        #expect(object["segment_type"] as? String == "free_reflection")
        #expect(object["segment_id"] as? String == "s07")
    }

    @Test("Segment decodes the populated fixture to a free reflection")
    func segmentDecodesFixture() throws {
        let segment = try JSONDecoder().decode(Segment.self, from: Data(Self.populated.utf8))

        guard case .freeReflection(let reflection) = segment else {
            Issue.record("free_reflection should decode to .freeReflection")
            return
        }
        #expect(reflection.captured_at == "2026-04-24T19:42:00+02:00")
        #expect(reflection.language == "en-US")
    }
}
