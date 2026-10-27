import Foundation
import Testing
@testable import VoiceDiary

// `Todo` is nested in `Manifest.todos_detected` and `todos_implicit_confirmed`
// (SPEC §10.3) and feeds the server's todo models (`server/webapp/models.py`),
// which ignore the app-only `source_quote`. `TodoRejected` has its own suite in
// `TodoRejectedWireTests`. It uses the synthesized Codable conformance, so the
// Swift property names are the wire keys and nil optionals are left out of the
// encoded JSON. `due` is an opaque string: the app never parses it. These tests
// pin the initializer defaults and decode fixed JSON written independently of
// the encoder, then encode and inspect the resulting keys and values.

@Suite("TodoSerialization")
struct TodoSerializationTests {
    private static let populatedTodo = """
        {
          "text": "Jörg wegen der Größe anrufen – 🎁 besorgen",
          "type": "implicit",
          "due": "morgen nach dem Standup",
          "status": "Abgeschlossen",
          "source_segment_id": "s02",
          "source_quote": "ruf bitte Jörg an, wegen der Größe „L“"
        }
        """

    private static let absentOptionals = """
        {"text": "Müll rausbringen", "type": "explicit", "status": "Offen"}
        """

    private static let nullOptionals = """
        {"text": "Müll rausbringen", "type": "explicit", "status": "Offen",
         "due": null, "source_segment_id": null, "source_quote": null}
        """

    private static func encodedObject(_ value: some Encodable) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test("Todo initializer defaults to an explicit, open todo without attribution")
    func todoInitializerDefaults() {
        let todo = Todo(text: "Müll rausbringen")

        #expect(todo.text == "Müll rausbringen")
        #expect(todo.type == "explicit")
        #expect(todo.status == "Offen")
        #expect(todo.due == nil)
        #expect(todo.source_segment_id == nil)
        #expect(todo.source_quote == nil)
    }

    @Test(
        "Todo decodes absent and null optionals as nil",
        arguments: [absentOptionals, nullOptionals]
    )
    func todoDecodesMissingOptionals(json: String) throws {
        let todo = try JSONDecoder().decode(Todo.self, from: Data(json.utf8))

        #expect(todo.text == "Müll rausbringen")
        #expect(todo.type == "explicit")
        #expect(todo.status == "Offen")
        #expect(todo.due == nil)
        #expect(todo.source_segment_id == nil)
        #expect(todo.source_quote == nil)
    }

    @Test("Todo decodes populated due, source_segment_id and source_quote verbatim")
    func todoDecodesPopulatedFields() throws {
        let todo = try JSONDecoder().decode(Todo.self, from: Data(Self.populatedTodo.utf8))

        #expect(todo.text == "Jörg wegen der Größe anrufen – 🎁 besorgen")
        #expect(todo.type == "implicit")
        #expect(todo.due == "morgen nach dem Standup")
        #expect(todo.status == "Abgeschlossen")
        #expect(todo.source_segment_id == "s02")
        #expect(todo.source_quote == "ruf bitte Jörg an, wegen der Größe „L“")
    }

    @Test("Todo encodes every field under its wire key")
    func todoEncodesPopulatedFields() throws {
        let todo = Todo(
            text: "Jörg wegen der Größe anrufen – 🎁 besorgen",
            type: "implicit",
            due: "morgen nach dem Standup",
            status: "Abgeschlossen",
            source_segment_id: "s02",
            source_quote: "ruf bitte Jörg an, wegen der Größe „L“"
        )

        let object = try Self.encodedObject(todo)

        #expect(Set(object.keys) == [
            "text", "type", "due", "status", "source_segment_id", "source_quote",
        ])
        #expect(object["text"] as? String == "Jörg wegen der Größe anrufen – 🎁 besorgen")
        #expect(object["type"] as? String == "implicit")
        #expect(object["due"] as? String == "morgen nach dem Standup")
        #expect(object["status"] as? String == "Abgeschlossen")
        #expect(object["source_segment_id"] as? String == "s02")
        #expect(object["source_quote"] as? String == "ruf bitte Jörg an, wegen der Größe „L“")
    }

    @Test("Todo encoding leaves out nil optionals and keeps the default values")
    func todoEncodesDefaults() throws {
        let object = try Self.encodedObject(Todo(text: "Müll rausbringen"))

        #expect(Set(object.keys) == ["text", "type", "status"])
        #expect(object["text"] as? String == "Müll rausbringen")
        #expect(object["type"] as? String == "explicit")
        #expect(object["status"] as? String == "Offen")
    }

    @Test(
        "Todo keeps due as an opaque string through a round trip",
        arguments: ["2026-04-28", "2026-04-28T09:00:00+02:00", "next Friday", ""]
    )
    func todoDueStaysOpaque(due: String) throws {
        let data = try JSONEncoder().encode(Todo(text: "Müll rausbringen", due: due))
        let decoded = try JSONDecoder().decode(Todo.self, from: data)

        #expect(decoded.due == due)
    }

    @Test("Todo text and quote keep their exact Unicode scalars")
    func todoKeepsUnicodeScalars() throws {
        // Swift `==` treats precomposed and decomposed forms as equal, so
        // compare scalars. The JSON escapes spell a decomposed "ö" (o + U+0308).
        let json = #"{"text": "Jörg", "type": "explicit", "status": "Offen", "#
            + #""source_quote": "Jörg 🎁"}"#
        let text = Array("Jo\u{0308}rg".unicodeScalars)
        let quote = Array("Jo\u{0308}rg 🎁".unicodeScalars)

        let todo = try JSONDecoder().decode(Todo.self, from: Data(json.utf8))
        let object = try Self.encodedObject(todo)

        #expect(Array(todo.text.unicodeScalars) == text)
        #expect(Array(try #require(todo.source_quote).unicodeScalars) == quote)
        #expect(Array(try #require(object["text"] as? String).unicodeScalars) == text)
        #expect(Array(try #require(object["source_quote"] as? String).unicodeScalars) == quote)
    }
}
