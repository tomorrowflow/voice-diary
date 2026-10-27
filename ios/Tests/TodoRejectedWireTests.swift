import Foundation
import Testing
@testable import VoiceDiary

// `TodoRejected` is the element type of `Manifest.todos_implicit_rejected`
// (SPEC §10.3): an implicit todo the user declined, kept so the server can
// learn from it. It uses the synthesized Codable conformance, so the Swift
// property names are the wire keys, a nil `source_segment_id` is left out of
// the encoded JSON, and `text` and `type` are required on decode (`type`'s
// default only applies to the initializer). These tests pin the initializer,
// decode fixed JSON written independently of the encoder, and encode and
// inspect the resulting keys and values.

@Suite("TodoRejectedWire")
struct TodoRejectedWireTests {
    private static let populated = """
        {"text": "Steuer prüfen – „bald“ 📮", "type": "implicit", "source_segment_id": "s03"}
        """

    private static let nullSource = """
        {"text": "Steuer prüfen", "type": "implicit", "source_segment_id": null}
        """

    private static let absentSource = """
        {"text": "Steuer prüfen", "type": "implicit"}
        """

    private static func encodedObject(_ value: some Encodable) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test("Initializer defaults to the implicit type without attribution")
    func initializerDefaults() {
        let rejected = TodoRejected(text: "Steuer prüfen")

        #expect(rejected.text == "Steuer prüfen")
        #expect(rejected.type == "implicit")
        #expect(rejected.source_segment_id == nil)
    }

    @Test("Decodes populated text, type and source_segment_id verbatim")
    func decodesPopulatedFields() throws {
        let rejected = try JSONDecoder().decode(TodoRejected.self, from: Data(Self.populated.utf8))

        #expect(rejected.text == "Steuer prüfen – „bald“ 📮")
        #expect(rejected.type == "implicit")
        #expect(rejected.source_segment_id == "s03")
    }

    @Test(
        "Decodes absent and null source_segment_id as nil",
        arguments: [absentSource, nullSource]
    )
    func decodesMissingSourceSegment(json: String) throws {
        let rejected = try JSONDecoder().decode(TodoRejected.self, from: Data(json.utf8))

        #expect(rejected.text == "Steuer prüfen")
        #expect(rejected.type == "implicit")
        #expect(rejected.source_segment_id == nil)
    }

    @Test("Decoding keeps a type other than the implicit default")
    func decodesCustomType() throws {
        let json = #"{"text": "Steuer prüfen", "type": "explicit"}"#

        let rejected = try JSONDecoder().decode(TodoRejected.self, from: Data(json.utf8))

        #expect(rejected.type == "explicit")
    }

    @Test(
        "Decoding rejects JSON missing a required key",
        arguments: [
            (#"{"type": "implicit", "source_segment_id": "s03"}"#, "text"),
            (#"{"text": "Steuer prüfen", "source_segment_id": "s03"}"#, "type"),
        ]
    )
    func decodingRequiresTextAndType(json: String, missingKey: String) {
        #expect {
            try JSONDecoder().decode(TodoRejected.self, from: Data(json.utf8))
        } throws: { error in
            guard case DecodingError.keyNotFound(let key, _) = error else { return false }
            return key.stringValue == missingKey
        }
    }

    @Test("Encodes text, type and source_segment_id under their wire keys")
    func encodesPopulatedFields() throws {
        let object = try Self.encodedObject(
            TodoRejected(text: "Steuer prüfen – „bald“ 📮", source_segment_id: "s03")
        )

        #expect(Set(object.keys) == ["text", "type", "source_segment_id"])
        #expect(object["text"] as? String == "Steuer prüfen – „bald“ 📮")
        #expect(object["type"] as? String == "implicit")
        #expect(object["source_segment_id"] as? String == "s03")
    }

    @Test("Encoding leaves out a nil source_segment_id")
    func encodingOmitsNilSourceSegment() throws {
        let object = try Self.encodedObject(TodoRejected(text: "Steuer prüfen"))

        #expect(Set(object.keys) == ["text", "type"])
        #expect(object["text"] as? String == "Steuer prüfen")
        #expect(object["type"] as? String == "implicit")
    }

    @Test("Encoding writes a customized type instead of the implicit default")
    func encodesCustomType() throws {
        var rejected = TodoRejected(text: "Steuer prüfen", source_segment_id: "s03")
        rejected.type = "explicit"

        let object = try Self.encodedObject(rejected)

        #expect(Set(object.keys) == ["text", "type", "source_segment_id"])
        #expect(object["type"] as? String == "explicit")
    }

    @Test("Text keeps its exact Unicode scalars through decode and encode")
    func keepsUnicodeScalars() throws {
        // Swift `==` treats precomposed and decomposed forms as equal, so
        // compare scalars. The literal below spells a decomposed "ü" (u + U+0308).
        let json = #"{"text": "Pru\#u{0308}fen 📮", "type": "implicit"}"#
        let text = Array("Pru\u{0308}fen 📮".unicodeScalars)

        let rejected = try JSONDecoder().decode(TodoRejected.self, from: Data(json.utf8))
        let object = try Self.encodedObject(rejected)

        #expect(Array(rejected.text.unicodeScalars) == text)
        #expect(Array(try #require(object["text"] as? String).unicodeScalars) == text)
    }
}
