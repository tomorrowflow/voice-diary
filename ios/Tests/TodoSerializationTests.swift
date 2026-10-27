import Foundation
import Testing
@testable import VoiceDiary

// `Todo` and `TodoRejected` are nested in `Manifest.todos_detected`,
// `todos_implicit_confirmed` and `todos_implicit_rejected` (SPEC §10.3) and
// mirror the server's todo models (`server/webapp/models.py`). They use the
// synthesized Codable conformance, so the Swift property names are the wire
// keys and nil optionals are left out of the encoded JSON. `due` is an opaque
// string: the app never parses it. These tests pin the initializer defaults and
// decode fixed JSON written independently of the encoder, then encode and
// inspect the resulting keys and values.

@Suite("TodoSerialization")
struct TodoSerializationTests {
    private static let populatedTodo = """
        {
          "text": "Jörg wegen der Größe anrufen – 🎁 besorgen",
          "type": "implicit",
          "due": "morgen nach dem Standup",
          "status": "Erledigt",
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

    @Test("TodoRejected initializer defaults to the implicit type without attribution")
    func todoRejectedInitializerDefaults() {
        let rejected = TodoRejected(text: "Steuer prüfen")

        #expect(rejected.text == "Steuer prüfen")
        #expect(rejected.type == "implicit")
        #expect(rejected.source_segment_id == nil)
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
        #expect(todo.status == "Erledigt")
        #expect(todo.source_segment_id == "s02")
        #expect(todo.source_quote == "ruf bitte Jörg an, wegen der Größe „L“")
    }

    @Test("Todo encodes every field under its wire key")
    func todoEncodesPopulatedFields() throws {
        let todo = Todo(
            text: "Jörg wegen der Größe anrufen – 🎁 besorgen",
            type: "implicit",
            due: "morgen nach dem Standup",
            status: "Erledigt",
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
        #expect(object["status"] as? String == "Erledigt")
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

    @Test("Todo keeps due as an opaque string through a round trip")
    func todoDueStaysOpaque() throws {
        for due in ["2026-04-28", "2026-04-28T09:00:00+02:00", "next Friday", ""] {
            let data = try JSONEncoder().encode(Todo(text: "t", due: due))
            let decoded = try JSONDecoder().decode(Todo.self, from: data)

            #expect(decoded.due == due)
        }
    }

    @Test("TodoRejected decodes with and without source_segment_id")
    func todoRejectedDecoding() throws {
        let withSource = #"{"text": "Steuer prüfen", "type": "implicit", "source_segment_id": "s03"}"#
        let nullSource = #"{"text": "Steuer prüfen", "type": "implicit", "source_segment_id": null}"#
        let noSource = #"{"text": "Steuer prüfen", "type": "implicit"}"#

        let decoder = JSONDecoder()
        let first = try decoder.decode(TodoRejected.self, from: Data(withSource.utf8))
        let second = try decoder.decode(TodoRejected.self, from: Data(nullSource.utf8))
        let third = try decoder.decode(TodoRejected.self, from: Data(noSource.utf8))

        #expect(first.text == "Steuer prüfen")
        #expect(first.type == "implicit")
        #expect(first.source_segment_id == "s03")
        #expect(second.source_segment_id == nil)
        #expect(third.source_segment_id == nil)
    }

    @Test("TodoRejected encodes its implicit type and attribution")
    func todoRejectedEncoding() throws {
        let attributed = try Self.encodedObject(
            TodoRejected(text: "Steuer prüfen – „bald“ 📮", source_segment_id: "s03")
        )
        let bare = try Self.encodedObject(TodoRejected(text: "Steuer prüfen"))

        #expect(Set(attributed.keys) == ["text", "type", "source_segment_id"])
        #expect(attributed["text"] as? String == "Steuer prüfen – „bald“ 📮")
        #expect(attributed["type"] as? String == "implicit")
        #expect(attributed["source_segment_id"] as? String == "s03")
        #expect(Set(bare.keys) == ["text", "type"])
        #expect(bare["type"] as? String == "implicit")
    }
}
