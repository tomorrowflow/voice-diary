import Foundation
import Testing
@testable import VoiceDiary

// Round-trip a manifest through JSON to confirm the discriminated-union
// encoding stays in lockstep with the server's Pydantic schema
// (`server/webapp/models.py`). Uses Apple's swift-testing macros.

@Suite("Manifest")
struct ManifestTests {
    @Test("free_reflection segment round-trips through JSON")
    func freeReflectionRoundTrip() throws {
        let manifest = Manifest(
            session_id: "2026-04-27T19:30:00+02:00",
            date: "2026-04-27",
            segments: [
                .freeReflection(.init(
                    segment_id: "s01",
                    audio_file: "segments/s01.m4a",
                    captured_at: "2026-04-27T19:30:00+02:00"
                )),
            ]
        )

        let data = try JSONEncoder().encode(manifest)
        let decoded = try JSONDecoder().decode(Manifest.self, from: data)

        #expect(decoded.session_id == manifest.session_id)
        #expect(decoded.segments.count == 1)
        guard case .freeReflection(let seg) = decoded.segments[0] else {
            Issue.record("expected .freeReflection")
            return
        }
        #expect(seg.audio_file == "segments/s01.m4a")
    }

    @Test("calendar_event encoding writes the discriminator and id")
    func calendarEventEncoding() throws {
        let cal = CalendarRef(
            graph_event_id: "AAMkAD-test",
            title: "BYOD Sync",
            start: "2026-04-27T10:00:00+02:00",
            end: "2026-04-27T11:00:00+02:00",
            attendees: ["sabine@example.com"],
            rsvp_status: "accepted"
        )
        let segment = CalendarEventSegment(
            segment_id: "s01",
            calendar_ref: cal,
            audio_file: "segments/s01.m4a"
        )

        let data = try JSONEncoder().encode(Segment.calendarEvent(segment))
        let json = try #require(String(data: data, encoding: .utf8))

        #expect(json.contains("\"segment_type\":\"calendar_event\""))
        #expect(json.contains("AAMkAD-test"))
    }

    @Test(
        "rsvp_status accepts each canonical value",
        arguments: ["accepted", "tentative", "declined", "not_responded", "organizer", "none"]
    )
    func rsvpStatusValues(value: String) throws {
        let cal = CalendarRef(
            graph_event_id: "id",
            title: "t",
            start: "2026-04-27T10:00:00+02:00",
            end: "2026-04-27T11:00:00+02:00",
            attendees: [],
            rsvp_status: value
        )
        let segment = CalendarEventSegment(
            segment_id: "s01",
            calendar_ref: cal,
            audio_file: "segments/s01.m4a"
        )
        let data = try JSONEncoder().encode(Segment.calendarEvent(segment))
        let decoded = try JSONDecoder().decode(Segment.self, from: data)
        guard case .calendarEvent(let seg) = decoded else {
            Issue.record("expected .calendarEvent")
            return
        }
        #expect(seg.calendar_ref.rsvp_status == value)
    }
}

// `CalendarRef` is the `calendar_ref` object of a calendar_event segment. These
// tests pin its initializer defaults, its six snake_case wire keys, and that
// attendees and rsvp_status stay required on the wire even though the
// initializer defaults them. Fixtures are literal JSON with sorted keys, so a
// renamed key or a swapped value fails here instead of being mirrored by the
// encoder under test. Dates and RSVP values are opaque strings: nothing is
// validated or normalized.

@Suite("CalendarRef")
struct CalendarRefTests {
    private static let populatedJSON =
        #"{"attendees":["sabine@example.com","jörg.müller@example.com","ana@example.org"],"#
        + #""end":"2026-04-27T11:30:00+02:00","graph_event_id":"AAMkAD-test=","#
        + #""rsvp_status":"tentative","start":"2026-04-27T10:00:00+02:00","title":"Büro-Sync ☕ 日本"}"#

    private static let minimalJSON =
        #"{"attendees":[],"end":"e","graph_event_id":"id","rsvp_status":"accepted","start":"s","title":"t"}"#

    private static let populated = CalendarRef(
        graph_event_id: "AAMkAD-test=",
        title: "Büro-Sync ☕ 日本",
        start: "2026-04-27T10:00:00+02:00",
        end: "2026-04-27T11:30:00+02:00",
        attendees: ["sabine@example.com", "jörg.müller@example.com", "ana@example.org"],
        rsvp_status: "tentative"
    )

    private static let defaulted = CalendarRef(graph_event_id: "id", title: "t", start: "s", end: "e")

    private static func encode(_ ref: CalendarRef) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try #require(String(data: encoder.encode(ref), encoding: .utf8))
    }

    private static func decode(_ json: String) throws -> CalendarRef {
        try JSONDecoder().decode(CalendarRef.self, from: Data(json.utf8))
    }

    /// `minimalJSON` with raw JSON fragments swapped in for the two fields under test.
    private static func json(attendees: String = "[]", rsvp: String = #""accepted""#) -> String {
        #"{"attendees":\#(attendees),"end":"e","graph_event_id":"id","rsvp_status":\#(rsvp),"start":"s","title":"t"}"#
    }

    /// The top-level wire key a failed decode of `json` points at. Records an issue
    /// and returns nil when decoding succeeds or fails with something else.
    private static func failingKey(of json: String) throws -> String? {
        do {
            _ = try decode(json)
            Issue.record("expected decoding to fail")
            return nil
        } catch DecodingError.keyNotFound(let key, _) {
            return key.stringValue
        } catch DecodingError.typeMismatch(_, let context) {
            return context.codingPath.first?.stringValue
        } catch DecodingError.valueNotFound(_, let context) {
            return context.codingPath.first?.stringValue
        } catch {
            Issue.record("expected a keyNotFound, typeMismatch or valueNotFound error, got \(error)")
            return nil
        }
    }

    @Test("initializer defaults to no attendees and an accepted RSVP")
    func initializerDefaults() {
        #expect(Self.defaulted.attendees.isEmpty)
        #expect(Self.defaulted.rsvp_status == "accepted")
    }

    @Test("defaulted reference encodes an empty attendees array and accepted")
    func defaultedEncoding() throws {
        #expect(try Self.encode(Self.defaulted) == Self.minimalJSON)
    }

    @Test("populated reference encodes all six fields under their wire keys")
    func populatedEncoding() throws {
        #expect(try Self.encode(Self.populated) == Self.populatedJSON)
    }

    @Test("fixed JSON decodes into every field, keeping attendee order and Unicode")
    func decodesFixedJSON() throws {
        let decoded = try Self.decode(Self.populatedJSON)

        #expect(decoded.graph_event_id == "AAMkAD-test=")
        #expect(Array(decoded.title.utf8) == Array("Büro-Sync ☕ 日本".utf8))
        #expect(decoded.start == "2026-04-27T10:00:00+02:00")
        #expect(decoded.end == "2026-04-27T11:30:00+02:00")
        #expect(decoded.attendees == ["sabine@example.com", "jörg.müller@example.com", "ana@example.org"])
        #expect(decoded.rsvp_status == "tentative")
    }

    @Test("explicit empty attendees and accepted decode as given")
    func decodesExplicitEmptyValues() throws {
        let decoded = try Self.decode(Self.minimalJSON)

        #expect(decoded.attendees.isEmpty)
        #expect(decoded.rsvp_status == "accepted")
    }

    @Test("populated reference survives a full round trip")
    func roundTrip() throws {
        let decoded = try Self.decode(Self.encode(Self.populated))

        #expect(try Self.encode(decoded) == Self.populatedJSON)
    }

    @Test("start, end and rsvp_status are opaque strings, kept verbatim")
    func opaqueStringsPreserved() throws {
        let json = #"{"attendees":[],"end":" later ","graph_event_id":"id","rsvp_status":"Maybe!","start":"","title":""}"#

        let decoded = try Self.decode(json)

        #expect(decoded.start.isEmpty)
        #expect(decoded.end == " later ")
        #expect(decoded.rsvp_status == "Maybe!")
        #expect(decoded.title.isEmpty)
        #expect(try Self.encode(decoded) == json)
    }

    @Test("attendees and rsvp_status are required, not filled from the initializer default")
    func missingFieldRejected() throws {
        let cases: [(key: String, json: String)] = [
            ("attendees", #"{"end":"e","graph_event_id":"id","rsvp_status":"accepted","start":"s","title":"t"}"#),
            ("rsvp_status", #"{"attendees":[],"end":"e","graph_event_id":"id","start":"s","title":"t"}"#),
        ]

        for (key, json) in cases {
            #expect(try Self.failingKey(of: json) == key, "decoding without \(key)")
        }
    }

    @Test("attendees and rsvp_status reject null and wrong-typed values")
    func wrongTypeRejected() throws {
        let cases: [(key: String, json: String)] = [
            ("attendees", Self.json(attendees: "null")),
            ("attendees", Self.json(attendees: #""a@example.com""#)),
            ("attendees", Self.json(attendees: #"["a@example.com",7]"#)),
            ("attendees", Self.json(attendees: #"["a@example.com",null]"#)),
            ("attendees", Self.json(attendees: #"{"0":"a@example.com"}"#)),
            ("rsvp_status", Self.json(rsvp: "null")),
            ("rsvp_status", Self.json(rsvp: "1")),
            ("rsvp_status", Self.json(rsvp: "true")),
            ("rsvp_status", Self.json(rsvp: #"["accepted"]"#)),
        ]

        for (key, json) in cases {
            #expect(try Self.failingKey(of: json) == key, "decoding \(json)")
        }
    }
}
