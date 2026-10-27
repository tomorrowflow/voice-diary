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

// `AudioCodec` is the manifest's `audio_codec` object. These tests pin its
// initializer defaults and its wire keys and numbers. Fixtures are literal JSON
// with sorted keys, so a renamed key or a changed value fails here instead of
// being mirrored by the encoder under test. The custom configuration shares no
// value with the defaults, so a field that is dropped or swapped cannot pass.

@Suite("AudioCodec")
struct AudioCodecTests {
    private static let defaultJSON = #"{"bitrate":64000,"channels":1,"codec":"aac-lc","sample_rate":16000}"#
    private static let customJSON = #"{"bitrate":128000,"channels":2,"codec":"opus","sample_rate":48000}"#

    private static func encode(_ codec: AudioCodec) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try #require(String(data: encoder.encode(codec), encoding: .utf8))
    }

    private static func decode(_ json: String) throws -> AudioCodec {
        try JSONDecoder().decode(AudioCodec.self, from: Data(json.utf8))
    }

    @Test("initializer defaults are aac-lc, 16000 Hz, mono, 64000 bps")
    func initializerDefaults() {
        let codec = AudioCodec()

        #expect(codec.codec == "aac-lc")
        #expect(codec.sample_rate == 16_000)
        #expect(codec.channels == 1)
        #expect(codec.bitrate == 64_000)
    }

    @Test("default codec encodes the four wire keys with their numbers")
    func defaultEncoding() throws {
        #expect(try Self.encode(AudioCodec()) == Self.defaultJSON)
    }

    @Test("custom codec encodes each field under its own wire key")
    func customEncoding() throws {
        let codec = AudioCodec(codec: "opus", sample_rate: 48_000, channels: 2, bitrate: 128_000)

        #expect(try Self.encode(codec) == Self.customJSON)
    }

    @Test("fixed JSON decodes into every field")
    func decodesFixedJSON() throws {
        let decoded = try Self.decode(Self.customJSON)

        #expect(decoded.codec == "opus")
        #expect(decoded.sample_rate == 48_000)
        #expect(decoded.channels == 2)
        #expect(decoded.bitrate == 128_000)
    }

    @Test("default JSON decodes to the initializer defaults")
    func decodesDefaultJSON() throws {
        let decoded = try Self.decode(Self.defaultJSON)

        #expect(decoded.codec == "aac-lc")
        #expect(decoded.sample_rate == 16_000)
        #expect(decoded.channels == 1)
        #expect(decoded.bitrate == 64_000)
    }

    @Test("a missing field is rejected, not filled from the initializer default")
    func missingFieldRejected() throws {
        let fields: [(key: String, json: String)] = [
            ("codec", #"{"bitrate":128000,"channels":2,"sample_rate":48000}"#),
            ("sample_rate", #"{"bitrate":128000,"channels":2,"codec":"opus"}"#),
            ("channels", #"{"bitrate":128000,"codec":"opus","sample_rate":48000}"#),
            ("bitrate", #"{"channels":2,"codec":"opus","sample_rate":48000}"#),
        ]

        for (key, json) in fields {
            do {
                _ = try Self.decode(json)
                Issue.record("expected decoding to fail without \(key)")
            } catch DecodingError.keyNotFound(let missing, _) {
                #expect(missing.stringValue == key)
            } catch {
                Issue.record("expected keyNotFound for \(key), got \(error)")
            }
        }
    }
}
