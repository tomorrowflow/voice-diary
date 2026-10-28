import Foundation
import Testing
@testable import VoiceDiary

// `VoxtralVoice` is one entry of the server's `GET /api/tts/voices` catalog:
// `{"DE": [{id, language, label, description}, ...], "EN": [...]}`
// (`server/webapp/voice_catalog.py`). The Swift model uses the synthesized
// Codable conformance, so the property names are the wire keys. `voiceID` is
// derived, not on the wire: the persisted voice selection is `voxtral:` plus
// the server's `id`.
//
// Decoding tests read fixed literal JSON and encoding tests read the keys back
// with `JSONSerialization`, so the wire shape is pinned independently of the
// type under test. The `voxtral:` prefix is spelled out literally for the same
// reason. The model neither validates nor normalises its text fields.

@Suite("VoxtralVoiceWire")
struct VoxtralVoiceWireTests {
    private static let wireKeys = ["id", "language", "label", "description"]

    private static let voiceJSON = """
    {
      "id": "de_male",
      "language": "DE",
      "label": "Deutsch — männlich",
      "description": "Native deutsche Stimme, neutral."
    }
    """

    private static let catalogJSON = """
    {
      "EN": [
        {"id": "casual_male", "language": "EN", "label": "Casual", "description": "Relaxed."},
        {"id": "neutral_female", "language": "EN", "label": "Neutral", "description": "Even."},
        {"id": "cheerful_female", "language": "EN", "label": "Cheerful", "description": "Bright."}
      ],
      "DE": [
        {"id": "de_male", "language": "DE", "label": "Deutsch — männlich", "description": "Neutral."},
        {"id": "de_female", "language": "DE", "label": "Deutsch — weiblich", "description": "Neutral."}
      ]
    }
    """

    private static func data(_ json: String) -> Data { Data(json.utf8) }

    private static func decodeVoice(_ json: String) throws -> VoxtralVoice {
        try JSONDecoder().decode(VoxtralVoice.self, from: data(json))
    }

    private static func voiceJSONData(without key: String) throws -> Data {
        var object = try #require(
            try JSONSerialization.jsonObject(with: data(voiceJSON)) as? [String: Any]
        )
        object[key] = nil
        return try JSONSerialization.data(withJSONObject: object)
    }

    private static func wireObject(_ value: some Encodable) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// The `keyNotFound` key from decoding `json` as a `VoxtralVoice`, or nil if
    /// decoding succeeds or fails differently.
    private static func missingKey(from json: Data) -> String? {
        do {
            _ = try JSONDecoder().decode(VoxtralVoice.self, from: json)
            return nil
        } catch DecodingError.keyNotFound(let key, _) {
            return key.stringValue
        } catch {
            return nil
        }
    }

    // MARK: - Decoding

    @Test("decodes every field from fixed JSON")
    func decodesFullJSON() throws {
        let voice = try Self.decodeVoice(Self.voiceJSON)

        #expect(voice.id == "de_male")
        #expect(voice.language == "DE")
        #expect(voice.label == "Deutsch — männlich")
        #expect(voice.description == "Native deutsche Stimme, neutral.")
    }

    @Test("decodes Unicode text byte for byte, without normalising")
    func decodesUnicodeVerbatim() throws {
        // `u` + combining diaeresis is canonically equal to `ü` but is
        // different bytes; `String ==` cannot tell them apart, so compare UTF-8.
        let json = #"""
        {"id": "stimme_ü_1", "language": "DE", "label": "ü – 感謝 🌙",
         "description": "Wofür?\nZeile \"zwei\""}
        """#

        let voice = try Self.decodeVoice(json)

        #expect(Array(voice.id.utf8) == Array("stimme_ü_1".utf8))
        #expect(Array(voice.label.utf8) == Array("u\u{0308} – 感謝 🌙".utf8))
        #expect(Array(voice.description.utf8) == Array("Wofür?\nZeile \"zwei\"".utf8))
    }

    @Test("a missing field fails with keyNotFound", arguments: wireKeys)
    func missingFieldFails(key: String) throws {
        let json = try Self.voiceJSONData(without: key)

        #expect(Self.missingKey(from: json) == key)
    }

    @Test("the catalog keeps each language's own array in server order")
    func catalogPreservesOrderPerLanguage() throws {
        let catalog = try JSONDecoder().decode(
            [String: [VoxtralVoice]].self, from: Self.data(Self.catalogJSON)
        )

        #expect(Set(catalog.keys) == ["DE", "EN"])
        #expect(catalog["EN"]?.map(\.id) == ["casual_male", "neutral_female", "cheerful_female"])
        #expect(catalog["DE"]?.map(\.id) == ["de_male", "de_female"])
        #expect(catalog["EN"]?.map(\.language) == ["EN", "EN", "EN"])
        #expect(catalog["DE"]?.map(\.language) == ["DE", "DE"])
        #expect(catalog["DE"]?.first?.label == "Deutsch — männlich")
        #expect(catalog["EN"]?.last?.description == "Bright.")
    }

    // MARK: - Encoding

    @Test("encodes exactly the four wire fields and leaves out the derived voiceID")
    func encodesWireFields() throws {
        let voice = try Self.decodeVoice(Self.voiceJSON)

        let object = try Self.wireObject(voice)

        #expect(Set(object.keys) == Set(Self.wireKeys))
        #expect(object["id"] as? String == "de_male")
        #expect(object["language"] as? String == "DE")
        #expect(object["label"] as? String == "Deutsch — männlich")
        #expect(object["description"] as? String == "Native deutsche Stimme, neutral.")
    }

    @Test("a decoded catalog survives an encode and decode with every voice intact")
    func catalogRoundTrips() throws {
        let original = try JSONDecoder().decode(
            [String: [VoxtralVoice]].self, from: Self.data(Self.catalogJSON)
        )

        let decoded = try JSONDecoder().decode(
            [String: [VoxtralVoice]].self, from: JSONEncoder().encode(original)
        )

        #expect(decoded == original)
        #expect(decoded["EN"]?.map(\.id) == ["casual_male", "neutral_female", "cheerful_female"])
        #expect(decoded["DE"]?.map(\.id) == ["de_male", "de_female"])
    }

    // MARK: - voiceID

    @Test("voiceID is the literal voxtral: prefix plus the server id, and id is unchanged")
    func voiceIDPrefixesServerID() throws {
        let voice = try Self.decodeVoice(Self.voiceJSON)

        #expect(voice.voiceID == "voxtral:de_male")
        #expect(voice.id == "de_male")
        #expect(voice.voiceID.hasPrefix("voxtral:"))
        #expect(voice.voiceID.dropFirst("voxtral:".count) == "de_male")
    }

    @Test("voiceID adds the prefix once per computation, so repeated reads agree")
    func voiceIDIsStableAcrossReads() throws {
        let voice = try Self.decodeVoice(Self.voiceJSON)

        let first = voice.voiceID
        let second = voice.voiceID

        #expect(first == "voxtral:de_male")
        #expect(second == first)
        #expect(voice.id == "de_male")
    }

    @Test("voiceID does not detect an id that already starts with the prefix")
    func voiceIDPrefixesAnAlreadyPrefixedID() throws {
        let voice = try Self.decodeVoice(
            #"{"id": "voxtral:de_male", "language": "DE", "label": "L", "description": "D"}"#
        )

        #expect(voice.voiceID == "voxtral:voxtral:de_male")
        #expect(voice.id == "voxtral:de_male")
    }

    @Test("an empty id is not validated and yields the bare prefix")
    func emptyIDYieldsBarePrefix() throws {
        let voice = try Self.decodeVoice(
            #"{"id": "", "language": "DE", "label": "L", "description": "D"}"#
        )

        #expect(voice.id == "")
        #expect(voice.voiceID == "voxtral:")
    }
}
