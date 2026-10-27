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
    private static let requiredContextKeys = ["section_id", "title", "prompt_text"]

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

    private static let defaultsJSON = """
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

    private static func data(_ json: String) -> Data { Data(json.utf8) }

    /// `fullJSON` without `key`.
    private static func fullJSON(without key: String) throws -> Data {
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

    // MARK: - Decoding

    @Test("decodes every field from fixed JSON")
    func decodesFullJSON() throws {
        let segment = try JSONDecoder().decode(
            GeneralSectionSegment.self, from: Self.data(Self.fullJSON)
        )

        #expect(segment.segment_type == "general_section")
        #expect(segment.segment_id == "seg-g1")
        #expect(segment.section_id == "sec-7")
        #expect(segment.title == "Gratitude")
        #expect(segment.prompt_text == "What went well today?")
        #expect(segment.audio_file == "segments/g1.m4a")
        #expect(segment.transcript == "The walk was lovely.")
        #expect(segment.language == "en-GB")
    }

    @Test("decodes an empty transcript and the default language from fixed JSON")
    func decodesDefaultValues() throws {
        let segment = try JSONDecoder().decode(
            GeneralSectionSegment.self, from: Self.data(Self.defaultsJSON)
        )

        #expect(segment.transcript == "")
        #expect(segment.language == "de-DE")
    }

    @Test("the initializer defaults the transcript to empty and the language to de-DE")
    func initializerDefaultsEncode() throws {
        let segment = GeneralSectionSegment(
            segment_id: "seg-g2", section_id: "sec-8", title: "Health",
            prompt_text: "How did you sleep?", audio_file: "segments/g2.m4a"
        )

        #expect(segment.transcript == "")
        #expect(segment.language == "de-DE")

        let object = try Self.wireObject(segment)
        #expect(object["transcript"] as? String == "")
        #expect(object["language"] as? String == "de-DE")
    }

    @Test("a missing required field is rejected", arguments: requiredContextKeys + ["segment_id", "audio_file"])
    func missingRequiredFieldFails(key: String) throws {
        let json = try Self.fullJSON(without: key)

        let error = try #require(throws: DecodingError.self) {
            try JSONDecoder().decode(GeneralSectionSegment.self, from: json)
        }
        guard case .keyNotFound(let missing, _) = error else {
            Issue.record("expected keyNotFound for \(key), got \(error)")
            return
        }
        #expect(missing.stringValue == key)
    }

    @Test("a missing required context field also rejects the whole Segment", arguments: requiredContextKeys)
    func missingContextFieldRejectsSegment(key: String) throws {
        let json = try Self.fullJSON(without: key)

        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(Segment.self, from: json)
        }
    }

    // MARK: - Encoding

    @Test("encodes exactly the wire fields with their own values")
    func encodesWireFields() throws {
        let segment = GeneralSectionSegment(
            segment_id: "seg-g1", section_id: "sec-7", title: "Gratitude",
            prompt_text: "What went well today?", audio_file: "segments/g1.m4a",
            transcript: "The walk was lovely.", language: "en-GB"
        )

        let object = try Self.wireObject(segment)

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

    // MARK: - Round trips

    @Test("opaque ids and text, including Unicode, survive a round trip unchanged")
    func opaqueTextRoundTrips() throws {
        let original = GeneralSectionSegment(
            segment_id: " seg/ü·1 ",
            section_id: "Abschnitt 🌙/ß  (neu)",
            title: "Dankbarkeit – 感謝 ✨",
            prompt_text: "Wofür bist du heute dankbar?\nWhat about \"quotes\" and \\ slashes?",
            audio_file: "segments/ü 1.m4a",
            transcript: "Ich bin dankbar für den Spaziergang. 🙏",
            language: "de-CH"
        )

        let decoded = try JSONDecoder().decode(
            GeneralSectionSegment.self, from: JSONEncoder().encode(original)
        )

        #expect(decoded.segment_id == original.segment_id)
        #expect(decoded.section_id == original.section_id)
        #expect(decoded.title == original.title)
        #expect(decoded.prompt_text == original.prompt_text)
        #expect(decoded.audio_file == original.audio_file)
        #expect(decoded.transcript == original.transcript)
        #expect(decoded.language == original.language)
    }

    @Test("empty context strings are not validated")
    func emptyContextStringsPassThrough() throws {
        let original = GeneralSectionSegment(
            segment_id: "", section_id: "", title: "", prompt_text: "", audio_file: ""
        )

        let object = try Self.wireObject(original)
        for key in Self.requiredContextKeys + ["segment_id", "audio_file"] {
            #expect(object[key] as? String == "", "\(key)")
        }

        let decoded = try JSONDecoder().decode(
            GeneralSectionSegment.self, from: JSONEncoder().encode(original)
        )
        #expect(decoded.section_id == "")
        #expect(decoded.title == "")
        #expect(decoded.prompt_text == "")
    }

    @Test("a Segment round trip keeps every field and the general_section discriminator")
    func segmentRoundTrip() throws {
        let segment = Segment.generalSection(GeneralSectionSegment(
            segment_id: "seg-g1", section_id: "sec-7", title: "Gratitude",
            prompt_text: "What went well today?", audio_file: "segments/g1.m4a",
            transcript: "The walk was lovely.", language: "en-GB"
        ))

        let object = try Self.wireObject(segment)
        #expect(object["segment_type"] as? String == "general_section")

        let decoded = try JSONDecoder().decode(Segment.self, from: JSONEncoder().encode(segment))
        guard case .generalSection(let payload) = decoded else {
            Issue.record("general_section should decode to .generalSection, got \(decoded)")
            return
        }
        #expect(decoded.segmentID == "seg-g1")
        #expect(decoded.audioFile == "segments/g1.m4a")
        #expect(payload.section_id == "sec-7")
        #expect(payload.title == "Gratitude")
        #expect(payload.prompt_text == "What went well today?")
        #expect(payload.transcript == "The walk was lovely.")
        #expect(payload.language == "en-GB")
    }

    @Test("fixed JSON decoded as a Segment reaches the general_section case with all fields")
    func segmentDecodesFixedJSON() throws {
        let decoded = try JSONDecoder().decode(Segment.self, from: Self.data(Self.fullJSON))

        guard case .generalSection(let payload) = decoded else {
            Issue.record("general_section should decode to .generalSection, got \(decoded)")
            return
        }
        #expect(payload.segment_id == "seg-g1")
        #expect(payload.section_id == "sec-7")
        #expect(payload.title == "Gratitude")
        #expect(payload.prompt_text == "What went well today?")
        #expect(payload.audio_file == "segments/g1.m4a")
        #expect(payload.transcript == "The walk was lovely.")
        #expect(payload.language == "en-GB")
    }
}
