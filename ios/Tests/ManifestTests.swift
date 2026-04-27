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
            attendees: ["monica@example.com"],
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
