import Foundation
import Testing
@testable import VoiceDiary

// `AiPrompt` is one entry of the manifest's `ai_prompts[]` (SPEC §10.3),
// mirrored by the server's `AiPrompt` model (`server/webapp/models.py`). It
// uses the synthesized Codable conformance, so the Swift property names are
// the wire keys; `at` and `role` are required, `segment_id` and `text` are
// optional, and `at` and `role` are opaque strings the app does not validate.
// These tests decode fixed JSON and inspect the encoded bytes so a renamed,
// dropped or re-typed field fails here instead of in the server's ingest.

@Suite("AiPromptSerialization")
struct AiPromptSerializationTests {
    private static func decode(_ json: String) throws -> AiPrompt {
        try JSONDecoder().decode(AiPrompt.self, from: Data(json.utf8))
    }

    private static func encodedObject(_ prompt: AiPrompt) throws -> [String: Any] {
        let data = try JSONEncoder().encode(prompt)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test("initializer keeps the given values and defaults the optionals to nil")
    func initializerValues() {
        let minimal = AiPrompt(at: "2026-04-27T19:30:00+02:00", role: "opener")
        #expect(minimal.at == "2026-04-27T19:30:00+02:00")
        #expect(minimal.role == "opener")
        #expect(minimal.segment_id == nil)
        #expect(minimal.text == nil)

        let full = AiPrompt(
            at: "2026-04-27T19:31:00+02:00", role: "follow_up", segment_id: "s02", text: "Und dann?"
        )
        #expect(full.at == "2026-04-27T19:31:00+02:00")
        #expect(full.role == "follow_up")
        #expect(full.segment_id == "s02")
        #expect(full.text == "Und dann?")
    }

    @Test("decodes a fully populated prompt")
    func decodesPopulated() throws {
        let prompt = try Self.decode("""
            {"at": "2026-04-27T19:31:00+02:00", "role": "follow_up",
             "segment_id": "s02", "text": "Und dann?"}
            """)
        #expect(prompt.at == "2026-04-27T19:31:00+02:00")
        #expect(prompt.role == "follow_up")
        #expect(prompt.segment_id == "s02")
        #expect(prompt.text == "Und dann?")
    }

    @Test(
        "segment_id decodes as nil when absent or null and as the value when present",
        arguments: [
            (#"{"at": "a", "role": "r"}"#, String?.none),
            (#"{"at": "a", "role": "r", "segment_id": null}"#, String?.none),
            (#"{"at": "a", "role": "r", "segment_id": "s07"}"#, "s07"),
        ]
    )
    func segmentIDOptionality(json: String, expected: String?) throws {
        let prompt = try Self.decode(json)
        #expect(prompt.segment_id == expected)
        #expect(prompt.text == nil)
    }

    @Test(
        "text decodes as nil when absent or null and as the value when present",
        arguments: [
            (#"{"at": "a", "role": "r"}"#, String?.none),
            (#"{"at": "a", "role": "r", "text": null}"#, String?.none),
            (#"{"at": "a", "role": "r", "text": "Hallo"}"#, "Hallo"),
            (#"{"at": "a", "role": "r", "text": ""}"#, ""),
        ]
    )
    func textOptionality(json: String, expected: String?) throws {
        let prompt = try Self.decode(json)
        #expect(prompt.text == expected)
        #expect(prompt.segment_id == nil)
    }

    @Test("decodes JSON unicode escapes in text")
    func decodesEscapedUnicode() throws {
        let prompt = try Self.decode(
            #"{"at": "a", "role": "r", "text": "Grüße 😀"}"#
        )
        #expect(prompt.text == "Grüße 😀")
    }

    @Test("at and role are opaque strings: any value is kept as is")
    func atAndRoleAreOpaque() throws {
        let prompt = try Self.decode(#"{"at": "not a timestamp", "role": "no_such_role"}"#)
        #expect(prompt.at == "not a timestamp")
        #expect(prompt.role == "no_such_role")

        let empty = try Self.decode(#"{"at": "", "role": ""}"#)
        #expect(empty.at == "")
        #expect(empty.role == "")
    }

    @Test(
        "a prompt without at or role fails to decode",
        arguments: [
            #"{"role": "opener"}"#,
            #"{"at": "2026-04-27T19:30:00+02:00"}"#,
            #"{"at": null, "role": "opener"}"#,
            #"{"at": "2026-04-27T19:30:00+02:00", "role": null}"#,
        ]
    )
    func requiredFields(json: String) {
        #expect(throws: DecodingError.self) { try Self.decode(json) }
    }

    @Test("encodes every populated field under its snake_case key")
    func encodesPopulated() throws {
        let prompt = AiPrompt(
            at: "2026-04-27T19:31:00+02:00", role: "enrichment_answer",
            segment_id: "s02", text: "Grüße, 日本語 😀"
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let json = try #require(String(data: encoder.encode(prompt), encoding: .utf8))
        #expect(json == """
            {"at":"2026-04-27T19:31:00+02:00","role":"enrichment_answer",\
            "segment_id":"s02","text":"Grüße, 日本語 😀"}
            """)
    }

    @Test("encoding leaves out nil segment_id and text")
    func encodesMinimal() throws {
        let object = try Self.encodedObject(AiPrompt(at: "a", role: "r"))
        #expect(Set(object.keys) == ["at", "role"])
        #expect(object["at"] as? String == "a")
        #expect(object["role"] as? String == "r")
    }

    @Test("encoding keeps an empty text instead of treating it as nil")
    func encodesEmptyText() throws {
        let object = try Self.encodedObject(AiPrompt(at: "a", role: "r", text: ""))
        #expect(Set(object.keys) == ["at", "role", "text"])
        #expect(object["text"] as? String == "")
    }

    @Test("round trip preserves every populated field")
    func roundTrip() throws {
        let original = AiPrompt(
            at: "2026-04-27T19:31:00+02:00", role: "enrichment_failed",
            segment_id: "s02", text: "Grüße, 日本語 😀\nZweite Zeile"
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AiPrompt.self, from: data)
        #expect(decoded.at == original.at)
        #expect(decoded.role == original.role)
        #expect(decoded.segment_id == original.segment_id)
        #expect(decoded.text == original.text)
    }

    @Test("round trip of a minimal prompt keeps the optionals nil")
    func roundTripMinimal() throws {
        let data = try JSONEncoder().encode(AiPrompt(at: "a", role: "r"))
        let decoded = try JSONDecoder().decode(AiPrompt.self, from: data)
        #expect(decoded.at == "a")
        #expect(decoded.role == "r")
        #expect(decoded.segment_id == nil)
        #expect(decoded.text == nil)
    }
}
