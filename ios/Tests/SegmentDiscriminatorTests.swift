import Foundation
import Testing
@testable import VoiceDiary

// `Segment` is a discriminated union on the wire: `segment_type` picks the
// payload type. These tests pin that dispatch for all five variants, in both
// directions, plus the inputs that must be rejected. Every variant uses its own
// ids, audio filename and payload so a mis-routed case cannot pass by accident.
// JSON is compared structurally (parsed objects), never by key order.

@Suite("SegmentDiscriminator")
struct SegmentDiscriminatorTests {
    private static let calendarEvent = Segment.calendarEvent(.init(
        segment_id: "seg-cal",
        calendar_ref: CalendarRef(
            graph_event_id: "graph-42",
            title: "Planning",
            start: "2026-04-27T10:00:00+02:00",
            end: "2026-04-27T11:00:00+02:00",
            attendees: ["a@example.com", "b@example.com"],
            rsvp_status: "tentative"
        ),
        audio_file: "segments/cal.m4a",
        transcript: "calendar words",
        language: "en-US",
        todos_detected: [Todo(text: "send notes")],
        linked_seed_ids: ["seed-1", "seed-2"]
    ))

    private static let voiceNote = Segment.voiceNote(.init(
        segment_id: "seg-note",
        captured_at: "2026-04-27T12:15:00+02:00",
        audio_file: "segments/note.m4a",
        transcript: "note words",
        language: "de-DE",
        linked_calendar_event_id: "graph-7",
        seed_id: "seed-note"
    ))

    private static let freeReflection = Segment.freeReflection(.init(
        segment_id: "seg-free",
        audio_file: "segments/free.m4a",
        transcript: "free words",
        language: "en-GB",
        captured_at: "2026-04-27T19:30:00+02:00"
    ))

    private static let emptyBlock = Segment.emptyBlock(.init(
        segment_id: "seg-empty",
        time_range: TimeRange(start: "2026-04-27T13:00:00+02:00", end: "2026-04-27T14:30:00+02:00"),
        audio_file: "segments/empty.m4a",
        transcript: "empty words",
        language: "de-AT"
    ))

    private static let generalSection = Segment.generalSection(.init(
        segment_id: "seg-general",
        section_id: "section-9",
        title: "Health",
        prompt_text: "How did you sleep?",
        audio_file: "segments/general.m4a",
        transcript: "general words",
        language: "fr-FR"
    ))

    /// Wire discriminator, expected id and audio file, and one payload
    /// key/value that only that variant carries.
    struct Expectation: CustomTestStringConvertible {
        let segment: Segment
        let discriminator: String
        let segmentID: String
        let audioFile: String
        let payloadKey: String
        let payloadValue: String

        var testDescription: String { discriminator }
    }

    static let expectations = [
        Expectation(
            segment: calendarEvent, discriminator: "calendar_event", segmentID: "seg-cal",
            audioFile: "segments/cal.m4a", payloadKey: "transcript", payloadValue: "calendar words"
        ),
        Expectation(
            segment: voiceNote, discriminator: "drive_by", segmentID: "seg-note",
            audioFile: "segments/note.m4a", payloadKey: "seed_id", payloadValue: "seed-note"
        ),
        Expectation(
            segment: freeReflection, discriminator: "free_reflection", segmentID: "seg-free",
            audioFile: "segments/free.m4a", payloadKey: "captured_at",
            payloadValue: "2026-04-27T19:30:00+02:00"
        ),
        Expectation(
            segment: emptyBlock, discriminator: "empty_block", segmentID: "seg-empty",
            audioFile: "segments/empty.m4a", payloadKey: "language", payloadValue: "de-AT"
        ),
        Expectation(
            segment: generalSection, discriminator: "general_section", segmentID: "seg-general",
            audioFile: "segments/general.m4a", payloadKey: "section_id", payloadValue: "section-9"
        ),
    ]

    private static func jsonObject(_ segment: Segment) throws -> [String: Any] {
        let data = try JSONEncoder().encode(segment)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private static func decode(_ json: String) throws -> Segment {
        try JSONDecoder().decode(Segment.self, from: Data(json.utf8))
    }

    @Test("encoding writes the variant's wire discriminator and payload", arguments: expectations)
    func encodesDiscriminator(_ expected: Expectation) throws {
        let object = try Self.jsonObject(expected.segment)

        #expect(object["segment_type"] as? String == expected.discriminator)
        #expect(object["segment_id"] as? String == expected.segmentID)
        #expect(object["audio_file"] as? String == expected.audioFile)
        #expect(object[expected.payloadKey] as? String == expected.payloadValue)
    }

    @Test("decoding an encoded segment restores the same variant and wire form", arguments: expectations)
    func roundTripPreservesVariant(_ expected: Expectation) throws {
        let data = try JSONEncoder().encode(expected.segment)
        let decoded = try JSONDecoder().decode(Segment.self, from: data)

        let before = try Self.jsonObject(expected.segment) as NSDictionary
        let after = try Self.jsonObject(decoded) as NSDictionary

        #expect(decoded.segmentID == expected.segmentID)
        #expect(after == before)
    }

    @Test("accessors read the id and audio file of the active variant", arguments: expectations)
    func accessors(_ expected: Expectation) {
        #expect(expected.segment.segmentID == expected.segmentID)
        #expect(expected.segment.audioFile == expected.audioFile)
    }

    @Test("each wire discriminator decodes to its own case")
    func decodesEachDiscriminatorToItsCase() throws {
        let calendar = try Self.decode("""
        {"segment_type":"calendar_event","segment_id":"c1","audio_file":"c1.m4a","transcript":"",
         "language":"de-DE","todos_detected":[],"linked_seed_ids":["s9"],
         "calendar_ref":{"graph_event_id":"g1","title":"T","start":"a","end":"b",
                         "attendees":[],"rsvp_status":"organizer"}}
        """)
        guard case .calendarEvent(let calendarPayload) = calendar else {
            Issue.record("calendar_event should decode to .calendarEvent")
            return
        }
        #expect(calendarPayload.calendar_ref.graph_event_id == "g1")
        #expect(calendarPayload.linked_seed_ids == ["s9"])

        let note = try Self.decode("""
        {"segment_type":"drive_by","segment_id":"n1","audio_file":"n1.m4a","transcript":"hi",
         "language":"de-DE","captured_at":"2026-04-27T08:00:00+02:00","seed_id":"s1"}
        """)
        guard case .voiceNote(let notePayload) = note else {
            Issue.record("drive_by should decode to .voiceNote")
            return
        }
        #expect(notePayload.seed_id == "s1")
        #expect(notePayload.linked_calendar_event_id == nil)

        let reflection = try Self.decode("""
        {"segment_type":"free_reflection","segment_id":"f1","audio_file":"f1.m4a",
         "transcript":"","language":"de-DE"}
        """)
        guard case .freeReflection(let reflectionPayload) = reflection else {
            Issue.record("free_reflection should decode to .freeReflection")
            return
        }
        #expect(reflectionPayload.captured_at == nil)

        let empty = try Self.decode("""
        {"segment_type":"empty_block","segment_id":"e1","audio_file":"e1.m4a","transcript":"",
         "language":"de-DE","time_range":{"start":"09:00","end":"10:00"}}
        """)
        guard case .emptyBlock(let emptyPayload) = empty else {
            Issue.record("empty_block should decode to .emptyBlock")
            return
        }
        #expect(emptyPayload.time_range.end == "10:00")

        let general = try Self.decode("""
        {"segment_type":"general_section","segment_id":"g1","audio_file":"g1.m4a","transcript":"",
         "language":"de-DE","section_id":"sec","title":"Title","prompt_text":"Prompt"}
        """)
        guard case .generalSection(let generalPayload) = general else {
            Issue.record("general_section should decode to .generalSection")
            return
        }
        #expect(generalPayload.prompt_text == "Prompt")
    }

    @Test("voice notes keep the legacy drive_by spelling on the wire")
    func voiceNoteUsesLegacySpelling() throws {
        let object = try Self.jsonObject(Self.voiceNote)
        #expect(object["segment_type"] as? String == "drive_by")

        #expect(throws: DecodingError.self) {
            try Self.decode(#"{"segment_type":"voice_note","segment_id":"n","audio_file":"n.m4a","captured_at":"x"}"#)
        }
    }

    @Test("a missing segment_type is rejected")
    func missingDiscriminatorThrows() {
        #expect(throws: DecodingError.self) {
            try Self.decode(#"{"segment_id":"s1","audio_file":"s1.m4a"}"#)
        }
    }

    @Test(
        "an unknown segment_type is rejected",
        arguments: ["", "mystery", "Calendar_Event", "free-reflection", "voice_note"]
    )
    func unknownDiscriminatorThrows(_ kind: String) {
        let json = #"{"segment_type":"\#(kind)","segment_id":"s1","audio_file":"s1.m4a"}"#
        #expect(throws: DecodingError.self) { try Self.decode(json) }
    }

    @Test(
        "a non-string segment_type is rejected",
        arguments: ["null", "7", "true", #"["drive_by"]"#, #"{"value":"drive_by"}"#]
    )
    func nonStringDiscriminatorThrows(_ literal: String) {
        let json = #"{"segment_type":\#(literal),"segment_id":"s1","audio_file":"s1.m4a"}"#
        #expect(throws: DecodingError.self) { try Self.decode(json) }
    }

    @Test("a manifest keeps mixed variants in order")
    func manifestPreservesVariantOrder() throws {
        let manifest = Manifest(
            session_id: "2026-04-27T19:30:00+02:00",
            date: "2026-04-27",
            segments: Self.expectations.map(\.segment)
        )

        let data = try JSONEncoder().encode(manifest)
        let decoded = try JSONDecoder().decode(Manifest.self, from: data)

        #expect(decoded.segments.map(\.segmentID) == Self.expectations.map(\.segmentID))
        #expect(decoded.segments.map(\.audioFile) == Self.expectations.map(\.audioFile))
    }
}
