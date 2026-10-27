import Foundation
import Testing
@testable import VoiceDiary

// The calendar models mirror the server's `/today/calendar` response
// (`server/webapp/routers/calendar.py`). They use the synthesized Codable
// conformance, so the Swift property names are the wire keys and every
// field is required, even where the server defaults it. These tests decode
// API-shaped JSON from memory to pin those keys and failure modes.

@Suite("CalendarResponseDecoding")
struct CalendarResponseDecodingTests {
    private static var eventObject: [String: Any] {
        [
            "graph_event_id": "AAMk-event-1",
            "subject": "Design review",
            "start": "2026-06-02T09:00:00+02:00",
            "end": "2026-06-02T09:45:00+02:00",
            "is_all_day": false,
            "show_as": "busy",
            "rsvp_status": "tentative",
            "organizer": ["name": "Ada Lovelace", "email": "ada@example.com"],
            "attendees": [
                ["name": "Grace Hopper", "email": "grace@other.org"],
                ["name": "Linus", "email": "linus@example.com"],
            ],
            "body_preview": "Agenda: tokens and spacing",
            "is_recurring": true,
            "web_link": "https://outlook.example.com/owa/?itemid=AAMk-event-1",
        ]
    }

    private static var attendeeObject: [String: Any] {
        ["name": "Grace Hopper", "email": "grace@other.org"]
    }

    /// Parses a JSON fragment such as `42` or `"false"` so wrong-type cases
    /// can be listed as plain strings.
    private static func fragment(_ json: String) throws -> Any {
        try JSONSerialization.jsonObject(
            with: Data(json.utf8), options: .fragmentsAllowed
        )
    }

    private static func data(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }

    private static func response(events: [[String: Any]]) -> [String: Any] {
        [
            "date": "2026-06-02",
            "rsvp_filter": ["accepted", "tentative", "organizer"],
            "events": events,
        ]
    }

    private static func removing(_ key: String, from object: [String: Any]) -> [String: Any] {
        var copy = object
        copy[key] = nil
        return copy
    }

    private static func replacing(
        _ key: String, with value: Any, in object: [String: Any]
    ) -> [String: Any] {
        var copy = object
        copy[key] = value
        return copy
    }

    private static func decodingError<T: Decodable>(
        _ type: T.Type, from object: [String: Any]
    ) throws -> DecodingError? {
        do {
            _ = try JSONDecoder().decode(type, from: data(object))
            return nil
        } catch let error as DecodingError {
            return error
        }
    }

    private static func isKeyNotFound(_ error: DecodingError?, _ key: String) -> Bool {
        if case .keyNotFound(let missing, _)? = error { return missing.stringValue == key }
        return false
    }

    private static func isTypeMismatch(_ error: DecodingError?, _ key: String) -> Bool {
        if case .typeMismatch(_, let context)? = error {
            return context.codingPath.last?.stringValue == key
        }
        return false
    }

    // MARK: - ServerAttendee

    @Test("attendee decodes name and email")
    func attendeeDecodes() throws {
        let attendee = try JSONDecoder().decode(
            ServerAttendee.self, from: Self.data(Self.attendeeObject)
        )

        #expect(attendee == ServerAttendee(name: "Grace Hopper", email: "grace@other.org"))
    }

    @Test("attendee ignores unknown fields")
    func attendeeIgnoresUnknownFields() throws {
        let object = Self.replacing("response", with: "accepted", in: Self.attendeeObject)

        let attendee = try JSONDecoder().decode(ServerAttendee.self, from: Self.data(object))

        #expect(attendee == ServerAttendee(name: "Grace Hopper", email: "grace@other.org"))
    }

    @Test("attendee without a required field fails with keyNotFound",
          arguments: ["name", "email"])
    func attendeeMissingField(key: String) throws {
        let error = try Self.decodingError(
            ServerAttendee.self, from: Self.removing(key, from: Self.attendeeObject)
        )

        #expect(Self.isKeyNotFound(error, key))
    }

    @Test("attendee with a non-string field fails with typeMismatch",
          arguments: ["name", "email"])
    func attendeeWrongType(key: String) throws {
        let error = try Self.decodingError(
            ServerAttendee.self, from: Self.replacing(key, with: 42, in: Self.attendeeObject)
        )

        #expect(Self.isTypeMismatch(error, key))
    }

    // MARK: - ServerCalendarEvent

    @Test("event decodes every field from snake_case keys")
    func eventDecodesAllFields() throws {
        let event = try JSONDecoder().decode(
            ServerCalendarEvent.self, from: Self.data(Self.eventObject)
        )

        #expect(event.graph_event_id == "AAMk-event-1")
        #expect(event.subject == "Design review")
        #expect(event.start == "2026-06-02T09:00:00+02:00")
        #expect(event.end == "2026-06-02T09:45:00+02:00")
        #expect(event.is_all_day == false)
        #expect(event.show_as == "busy")
        #expect(event.rsvp_status == "tentative")
        #expect(event.organizer == ServerAttendee(name: "Ada Lovelace", email: "ada@example.com"))
        #expect(event.attendees == [
            ServerAttendee(name: "Grace Hopper", email: "grace@other.org"),
            ServerAttendee(name: "Linus", email: "linus@example.com"),
        ])
        #expect(event.body_preview == "Agenda: tokens and spacing")
        #expect(event.is_recurring == true)
        #expect(event.web_link == "https://outlook.example.com/owa/?itemid=AAMk-event-1")
    }

    @Test("event identity comes from graph_event_id")
    func eventIdentity() throws {
        let object = Self.replacing("graph_event_id", with: "AAMk-other", in: Self.eventObject)

        let event = try JSONDecoder().decode(ServerCalendarEvent.self, from: Self.data(object))

        #expect(event.id == "AAMk-other")
    }

    @Test("event decodes with an empty attendee list")
    func eventEmptyAttendees() throws {
        let object = Self.replacing("attendees", with: [Any](), in: Self.eventObject)

        let event = try JSONDecoder().decode(ServerCalendarEvent.self, from: Self.data(object))

        #expect(event.attendees.isEmpty)
        #expect(event.attendeeCount == 0)
    }

    @Test("event ignores unknown fields, top level and nested")
    func eventIgnoresUnknownFields() throws {
        var object = Self.replacing("location", with: "Room 4", in: Self.eventObject)
        object["organizer"] = [
            "name": "Ada Lovelace", "email": "ada@example.com", "response": "organizer",
        ]
        object["attendees"] = [
            ["name": "Grace Hopper", "email": "grace@other.org", "response": "accepted"],
        ]

        let event = try JSONDecoder().decode(ServerCalendarEvent.self, from: Self.data(object))

        #expect(event.graph_event_id == "AAMk-event-1")
        #expect(event.organizer == ServerAttendee(name: "Ada Lovelace", email: "ada@example.com"))
        #expect(event.attendees == [ServerAttendee(name: "Grace Hopper", email: "grace@other.org")])
    }

    @Test("event does not read camelCase keys")
    func eventRejectsCamelCaseKeys() throws {
        var object = Self.removing("graph_event_id", from: Self.eventObject)
        object["graphEventId"] = "AAMk-event-1"

        let error = try Self.decodingError(ServerCalendarEvent.self, from: object)

        #expect(Self.isKeyNotFound(error, "graph_event_id"))
    }

    @Test("event without a required field fails with keyNotFound",
          arguments: [
            "graph_event_id", "subject", "start", "end", "is_all_day", "show_as",
            "rsvp_status", "organizer", "attendees", "body_preview", "is_recurring", "web_link",
          ])
    func eventMissingField(key: String) throws {
        let error = try Self.decodingError(
            ServerCalendarEvent.self, from: Self.removing(key, from: Self.eventObject)
        )

        #expect(Self.isKeyNotFound(error, key))
    }

    @Test("event with a wrong field type fails with typeMismatch",
          arguments: [
            ("graph_event_id", "7"),
            ("subject", "7"),
            ("start", "7"),
            ("end", "7"),
            ("is_all_day", "\"false\""),
            ("show_as", "7"),
            ("rsvp_status", "7"),
            ("organizer", "\"Ada\""),
            ("attendees", "\"Grace\""),
            ("body_preview", "7"),
            ("is_recurring", "\"true\""),
            ("web_link", "7"),
          ])
    func eventWrongType(key: String, json: String) throws {
        let value = try Self.fragment(json)

        let error = try Self.decodingError(
            ServerCalendarEvent.self, from: Self.replacing(key, with: value, in: Self.eventObject)
        )

        #expect(Self.isTypeMismatch(error, key))
    }

    @Test("event with a malformed attendee element fails with keyNotFound")
    func eventMalformedAttendeeElement() throws {
        let object = Self.replacing(
            "attendees", with: [["name": "Grace Hopper"]], in: Self.eventObject
        )

        let error = try Self.decodingError(ServerCalendarEvent.self, from: object)

        #expect(Self.isKeyNotFound(error, "email"))
    }

    @Test("event with a null required field fails with valueNotFound")
    func eventNullField() throws {
        let object = Self.replacing("subject", with: NSNull(), in: Self.eventObject)

        let error = try Self.decodingError(ServerCalendarEvent.self, from: object)

        guard case .valueNotFound(_, let context)? = error else {
            Issue.record("expected valueNotFound, got \(String(describing: error))")
            return
        }
        #expect(context.codingPath.last?.stringValue == "subject")
    }

    @Test("event survives an encode/decode round trip with every field")
    func eventRoundTrip() throws {
        let original = try JSONDecoder().decode(
            ServerCalendarEvent.self, from: Self.data(Self.eventObject)
        )

        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ServerCalendarEvent.self, from: encoded)

        #expect(decoded.graph_event_id == original.graph_event_id)
        #expect(decoded.subject == original.subject)
        #expect(decoded.start == original.start)
        #expect(decoded.end == original.end)
        #expect(decoded.is_all_day == original.is_all_day)
        #expect(decoded.show_as == original.show_as)
        #expect(decoded.rsvp_status == original.rsvp_status)
        #expect(decoded.organizer == original.organizer)
        #expect(decoded.attendees == original.attendees)
        #expect(decoded.body_preview == original.body_preview)
        #expect(decoded.is_recurring == original.is_recurring)
        #expect(decoded.web_link == original.web_link)
    }

    @Test("event encodes the same snake_case keys the server sends")
    func eventEncodedKeys() throws {
        let event = try JSONDecoder().decode(
            ServerCalendarEvent.self, from: Self.data(Self.eventObject)
        )

        let encoded = try JSONEncoder().encode(event)
        let keys = try #require(
            try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        ).keys

        #expect(Set(keys) == Set(Self.eventObject.keys))
    }

    // MARK: - TodayCalendarResponse

    @Test("response decodes date, rsvp filter and events")
    func responseDecodes() throws {
        let object = Self.response(events: [
            Self.eventObject,
            Self.replacing("graph_event_id", with: "AAMk-event-2", in: Self.eventObject),
        ])

        let response = try JSONDecoder().decode(
            TodayCalendarResponse.self, from: Self.data(object)
        )

        #expect(response.date == "2026-06-02")
        #expect(response.rsvp_filter == ["accepted", "tentative", "organizer"])
        #expect(response.events.map(\.id) == ["AAMk-event-1", "AAMk-event-2"])
        #expect(response.events.first?.attendees.count == 2)
    }

    @Test("response decodes with empty events and an empty rsvp filter")
    func responseEmptyArrays() throws {
        let object = Self.replacing(
            "rsvp_filter", with: [String](), in: Self.response(events: [])
        )

        let response = try JSONDecoder().decode(
            TodayCalendarResponse.self, from: Self.data(object)
        )

        #expect(response.date == "2026-06-02")
        #expect(response.rsvp_filter.isEmpty)
        #expect(response.events.isEmpty)
    }

    @Test("response ignores unknown fields")
    func responseIgnoresUnknownFields() throws {
        let object = Self.replacing(
            "generated_at", with: "2026-06-02T07:00:00Z", in: Self.response(events: [])
        )

        let response = try JSONDecoder().decode(
            TodayCalendarResponse.self, from: Self.data(object)
        )

        #expect(response.date == "2026-06-02")
        #expect(response.events.isEmpty)
    }

    @Test("response without a required field fails with keyNotFound",
          arguments: ["date", "rsvp_filter", "events"])
    func responseMissingField(key: String) throws {
        let error = try Self.decodingError(
            TodayCalendarResponse.self,
            from: Self.removing(key, from: Self.response(events: [Self.eventObject]))
        )

        #expect(Self.isKeyNotFound(error, key))
    }

    @Test("response with a wrong field type fails with typeMismatch",
          arguments: [
            ("date", "20260602"),
            ("rsvp_filter", "\"accepted\""),
            ("events", "\"none\""),
          ])
    func responseWrongType(key: String, json: String) throws {
        let value = try Self.fragment(json)

        let error = try Self.decodingError(
            TodayCalendarResponse.self,
            from: Self.replacing(key, with: value, in: Self.response(events: []))
        )

        #expect(Self.isTypeMismatch(error, key))
    }

    @Test("response fails when one event is missing a required field")
    func responseInvalidEvent() throws {
        let error = try Self.decodingError(
            TodayCalendarResponse.self,
            from: Self.response(events: [
                Self.eventObject, Self.removing("start", from: Self.eventObject),
            ])
        )

        #expect(Self.isKeyNotFound(error, "start"))
    }
}
