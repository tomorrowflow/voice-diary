import XCTest
@testable import VoiceDiary

// Round-trip a manifest through JSON to confirm the discriminated-union
// encoding matches the server's Pydantic schema (`server/webapp/models.py`).

final class ManifestTests: XCTestCase {
    func testFreeReflectionRoundTrip() throws {
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
        XCTAssertEqual(decoded.session_id, manifest.session_id)
        XCTAssertEqual(decoded.segments.count, 1)
        switch decoded.segments[0] {
        case .freeReflection(let seg):
            XCTAssertEqual(seg.audio_file, "segments/s01.m4a")
        default:
            XCTFail("expected free_reflection segment")
        }
    }

    func testCalendarEventEncoding() throws {
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
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(json.contains("\"segment_type\":\"calendar_event\""))
        XCTAssertTrue(json.contains("AAMkAD-test"))
    }
}
