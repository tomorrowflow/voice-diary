import Foundation
import Testing
@testable import VoiceDiary

// `GeneralSectionSegment` is the `general_section` manifest segment (SPEC §10.4):
// one answer to a user-defined walkthrough section. The server's
// `GeneralSectionSegment` (`server/webapp/models.py`) requires `segment_id`,
// `audio_file`, `section_id`, `title` and `prompt_text`, and defaults
// `transcript` to "" and `language` to "de-DE". The Swift model uses the
// synthesized Codable conformance, so the property names are the wire keys.
//
// Decoding tests read fixed literal JSON and encoding tests read the keys back
// with `JSONSerialization`, so the wire shape is pinned independently of the
// type under test. `section_id`, `title` and `prompt_text` are opaque text: the
// model neither validates nor normalises them.

@Suite("GeneralSectionSegmentWire")
struct GeneralSectionSegmentWireTests {
    private static let contextKeys = ["section_id", "title", "prompt_text"]
    private static let requiredKeys = contextKeys + ["segment_id", "audio_file"]

    private static let fullJSON = """
    {
      "segment_type": "general_section",
      "segment_id": "seg-g1",
      "section_id": "sec-7",
      "title": "Gratitude",
      "prompt_text": "What went well today?",
      "audio_file": "segments/g1.m4a",
      "transcript": "The walk was lovely.",
      "language": "en-GB"
    }
    """

    private static let defaultValuesJSON = """
    {
      "segment_type": "general_section",
      "segment_id": "seg-g2",
      "section_id": "sec-8",
      "title": "Health",
      "prompt_text": "How did you sleep?",
      "audio_file": "segments/g2.m4a",
      "transcript": "",
      "language": "de-DE"
    }
    """

    /// The values in `fullJSON`.
    private static let fullSegment = GeneralSectionSegment(
        segment_id: "seg-g1", section_id: "sec-7", title: "Gratitude",
        prompt_text: "What went well today?", audio_file: "segments/g1.m4a",
        transcript: "The walk was lovely.", language: "en-GB"
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
        _ segment: GeneralSectionSegment, sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(segment.segment_type == "general_section", sourceLocation: sourceLocation)
        #expect(segment.segment_id == "seg-g1", sourceLocation: sourceLocation)
        #expect(segment.section_id == "sec-7", sourceLocation: sourceLocation)
        #expect(segment.title == "Gratitude", sourceLocation: sourceLocation)
        #expect(segment.prompt_text == "What went well today?", sourceLocation: sourceLocation)
        #expect(segment.audio_file == "segments/g1.m4a", sourceLocation: sourceLocation)
        #expect(segment.transcript == "The walk was lovely.", sourceLocation: sourceLocation)
        #expect(segment.language == "en-GB", sourceLocation: sourceLocation)
    }

    // MARK: - Decoding

    @Test("decodes every field from fixed JSON")
    func decodesFullJSON() throws {
        let segment = try JSONDecoder().decode(
            GeneralSectionSegment.self, from: Self.data(Self.fullJSON)
        )

        Self.expectFullFields(segment)
    }

    @Test("decodes an empty transcript and a de-DE language as written")
    func decodesEmptyTranscriptAndDefaultLanguage() throws {
        let segment = try JSONDecoder().decode(
            GeneralSectionSegment.self, from: Self.data(Self.defaultValuesJSON)
        )

        #expect(segment.transcript == "")
        #expect(segment.language == "de-DE")
    }

    @Test("decodes Unicode text byte for byte, without normalising")
    func decodesUnicodeVerbatim() throws {
        // `u` + combining diaeresis is canonically equal to `ü` but is
        // different bytes; `String ==` cannot tell them apart, so compare UTF-8.
        let json = #"""
        {"segment_type": "general_section", "segment_id": "seg⁠ü",
         "section_id": "Abschnitt 🌙", "title": "ü – 感謝",
         "prompt_text": "Wofür?\nZeile \"zwei\"", "audio_file": "ü.m4a",
         "transcript": "", "language": "de-DE"}
        """#

        let segment = try JSONDecoder().decode(GeneralSectionSegment.self, from: Self.data(json))

        #expect(Array(segment.segment_id.utf8) == Array("seg\u{2060}ü".utf8))
        #expect(Array(segment.section_id.utf8) == Array("Abschnitt 🌙".utf8))
        #expect(Array(segment.title.utf8) == Array("u\u{0308} – 感謝".utf8))
        #expect(Array(segment.prompt_text.utf8) == Array("Wofür?\nZeile \"zwei\"".utf8))
        #expect(Array(segment.audio_file.utf8) == Array("ü.m4a".utf8))
    }

    @Test("a missing required field fails with keyNotFound", arguments: requiredKeys)
    func missingRequiredFieldFails(key: String) throws {
        let json = try Self.fullJSONData(without: key)

        #expect(Self.missingKey(decoding: GeneralSectionSegment.self, from: json) == key)
    }

    @Test("a missing section context field also rejects the whole Segment", arguments: contextKeys)
    func missingContextFieldRejectsSegment(key: String) throws {
        let json = try Self.fullJSONData(without: key)

        #expect(Self.missingKey(decoding: Segment.self, from: json) == key)
    }

    // MARK: - Encoding

    @Test("encodes exactly the wire fields with their own values")
    func encodesWireFields() throws {
        let object = try Self.wireObject(Self.fullSegment)

        #expect(Set(object.keys) == [
            "segment_type", "segment_id", "section_id", "title", "prompt_text",
            "audio_file", "transcript", "language",
        ])
        #expect(object["segment_type"] as? String == "general_section")
        #expect(object["segment_id"] as? String == "seg-g1")
        #expect(object["section_id"] as? String == "sec-7")
        #expect(object["title"] as? String == "Gratitude")
        #expect(object["prompt_text"] as? String == "What went well today?")
        #expect(object["audio_file"] as? String == "segments/g1.m4a")
        #expect(object["transcript"] as? String == "The walk was lovely.")
        #expect(object["language"] as? String == "en-GB")
    }

    @Test("the initializer defaults the transcript to empty and the language to de-DE")
    func initializerDefaultsEncode() throws {
        let segment = GeneralSectionSegment(
            segment_id: "seg-g2", section_id: "sec-8", title: "Health",
            prompt_text: "How did you sleep?", audio_file: "segments/g2.m4a"
        )

        let object = try Self.wireObject(segment)

        #expect(segment.transcript == "")
        #expect(segment.language == "de-DE")
        #expect(object.count == 8)
        #expect(object["transcript"] as? String == "")
        #expect(object["language"] as? String == "de-DE")
    }

    // MARK: - Round trips

    @Test("opaque ids and text, including Unicode, survive a round trip byte for byte")
    func opaqueTextRoundTrips() throws {
        let original = GeneralSectionSegment(
            segment_id: " seg/ü·1 ",
            section_id: "Abschnitt 🌙/ß  (neu)",
            title: "Dankbarkeit – 感謝 ✨ u\u{0308}",
            prompt_text: "Wofür bist du heute dankbar?\nWhat about \"quotes\" and \\ slashes?",
            audio_file: "segments/ü 1.m4a",
            transcript: "Ich bin dankbar für den Spaziergang. 🙏",
            language: "de-CH"
        )

        let decoded = try JSONDecoder().decode(
            GeneralSectionSegment.self, from: JSONEncoder().encode(original)
        )

        #expect(Array(decoded.segment_id.utf8) == Array(original.segment_id.utf8))
        #expect(Array(decoded.section_id.utf8) == Array(original.section_id.utf8))
        #expect(Array(decoded.title.utf8) == Array(original.title.utf8))
        #expect(Array(decoded.prompt_text.utf8) == Array(original.prompt_text.utf8))
        #expect(Array(decoded.audio_file.utf8) == Array(original.audio_file.utf8))
        #expect(Array(decoded.transcript.utf8) == Array(original.transcript.utf8))
        #expect(decoded.language == original.language)
    }

    @Test("empty ids and text are not validated")
    func emptyStringsPassThrough() throws {
        let original = GeneralSectionSegment(
            segment_id: "", section_id: "", title: "", prompt_text: "", audio_file: ""
        )

        let object = try Self.wireObject(original)
        for key in Self.requiredKeys {
            #expect(object[key] as? String == "", "\(key) should encode as empty")
        }

        let decoded = try JSONDecoder().decode(
            GeneralSectionSegment.self, from: JSONEncoder().encode(original)
        )
        #expect(decoded.segment_id == "")
        #expect(decoded.section_id == "")
        #expect(decoded.title == "")
        #expect(decoded.prompt_text == "")
        #expect(decoded.audio_file == "")
    }

    @Test("a Segment round trip keeps every field and the general_section discriminator")
    func segmentRoundTrip() throws {
        let segment = Segment.generalSection(Self.fullSegment)

        let object = try Self.wireObject(segment)
        #expect(object.count == 8)
        #expect(object["segment_type"] as? String == "general_section")

        let decoded = try JSONDecoder().decode(Segment.self, from: JSONEncoder().encode(segment))
        guard case .generalSection(let payload) = decoded else {
            Issue.record("general_section should decode to .generalSection, got \(decoded)")
            return
        }
        Self.expectFullFields(payload)
        #expect(decoded.segmentID == "seg-g1")
        #expect(decoded.audioFile == "segments/g1.m4a")
    }

    @Test("fixed JSON decoded as a Segment reaches the general_section case with all fields")
    func segmentDecodesFixedJSON() throws {
        let decoded = try JSONDecoder().decode(Segment.self, from: Self.data(Self.fullJSON))

        guard case .generalSection(let payload) = decoded else {
            Issue.record("general_section should decode to .generalSection, got \(decoded)")
            return
        }
        Self.expectFullFields(payload)
    }
}
