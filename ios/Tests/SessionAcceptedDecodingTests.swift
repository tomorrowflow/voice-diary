import Foundation
import Testing
@testable import VoiceDiary

// `SessionAccepted` and `SegmentUploadResult` are the `POST /api/sessions`
// response, decoded by `ServerClient.uploadSession` with a plain
// `JSONDecoder()`. They mirror the server's `SessionAccepted` and
// `SegmentResult` models (`server/webapp/models.py`) and SPEC §10.5. They use
// the synthesized Codable conformance, so the Swift property names are the
// wire keys; `transcript_id` and `error` are the only optional fields, and
// `status` is a free string. These tests decode fixed JSON shaped like the
// server's response to pin those keys and failure modes.

@Suite("SessionAcceptedDecoding")
struct SessionAcceptedDecodingTests {
    /// Mixed segment statuses, deliberately not in `segment_id` order. The
    /// first segment carries the extra `code` / `upstream` keys the server
    /// sends on failed segments; the iOS models ignore them.
    private static let mixedResponse = """
        {
          "status": "accepted",
          "session_id": "2026-04-24T19:30:00+02:00",
          "received_at": "2026-04-24T20:05:12+02:00",
          "processing_status_url": "/api/sessions/2026-04-24T19:30:00+02:00/status",
          "segments": [
            {"segment_id": "s03", "status": "failed", "transcript_id": null,
             "error": "whisper read timed out", "code": "whisper_timeout",
             "upstream": "whisper"},
            {"segment_id": "s01", "status": "processed", "transcript_id": 4021,
             "error": null},
            {"segment_id": "s02", "status": "pending_analysis", "transcript_id": 4022},
            {"segment_id": "s04", "status": "transcribing"}
          ]
        }
        """

    private static var envelopeObject: [String: Any] {
        [
            "status": "accepted",
            "session_id": "2026-04-24T19:30:00+02:00",
            "received_at": "2026-04-24T20:05:12+02:00",
            "processing_status_url": "/api/sessions/2026-04-24T19:30:00+02:00/status",
            "segments": [segmentObject],
        ]
    }

    private static var segmentObject: [String: Any] {
        ["segment_id": "s01", "status": "processed", "transcript_id": 4021, "error": NSNull()]
    }

    private static func decode(_ json: String) throws -> SessionAccepted {
        try JSONDecoder().decode(SessionAccepted.self, from: Data(json.utf8))
    }

    private static func data(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }

    /// Parses a JSON fragment such as `42` or `"false"` so wrong-type cases
    /// can be listed as plain strings.
    private static func fragment(_ json: String) throws -> Any {
        try JSONSerialization.jsonObject(
            with: Data(json.utf8), options: .fragmentsAllowed
        )
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

    private static func envelope(segment: [String: Any]) -> [String: Any] {
        replacing("segments", with: [segment], in: envelopeObject)
    }

    private static func decodingError(from object: [String: Any]) throws -> DecodingError? {
        do {
            _ = try JSONDecoder().decode(SessionAccepted.self, from: data(object))
            return nil
        } catch let error as DecodingError {
            return error
        }
    }

    private static func isKeyNotFound(_ error: DecodingError?, _ key: String) -> Bool {
        if case .keyNotFound(let missing, _)? = error { return missing.stringValue == key }
        return false
    }

    private static func isValueNotFound(_ error: DecodingError?, _ key: String) -> Bool {
        if case .valueNotFound(_, let context)? = error {
            return context.codingPath.last?.stringValue == key
        }
        return false
    }

    private static func isTypeMismatch(_ error: DecodingError?, _ key: String) -> Bool {
        if case .typeMismatch(_, let context)? = error {
            return context.codingPath.last?.stringValue == key
        }
        return false
    }

    // MARK: - Envelope

    @Test("envelope keeps every required field")
    func envelopeFields() throws {
        let accepted = try Self.decode(Self.mixedResponse)

        #expect(accepted.status == "accepted")
        #expect(accepted.session_id == "2026-04-24T19:30:00+02:00")
        #expect(accepted.received_at == "2026-04-24T20:05:12+02:00")
        #expect(
            accepted.processing_status_url == "/api/sessions/2026-04-24T19:30:00+02:00/status"
        )
    }

    @Test("empty segments decode to an empty list")
    func emptySegments() throws {
        let accepted = try JSONDecoder().decode(
            SessionAccepted.self,
            from: Self.data(Self.replacing("segments", with: [Any](), in: Self.envelopeObject))
        )

        #expect(accepted.segments.isEmpty)
        #expect(accepted.session_id == "2026-04-24T19:30:00+02:00")
    }

    // MARK: - Segments

    @Test("segments keep their wire order and statuses")
    func segmentOrderAndStatuses() throws {
        let accepted = try Self.decode(Self.mixedResponse)

        #expect(accepted.segments.map(\.segment_id) == ["s03", "s01", "s02", "s04"])
        #expect(
            accepted.segments.map(\.status)
                == ["failed", "processed", "pending_analysis", "transcribing"]
        )
    }

    @Test("segments keep integer transcript ids and error strings")
    func segmentTranscriptIdsAndErrors() throws {
        let segments = try Self.decode(Self.mixedResponse).segments

        #expect(segments.map(\.transcript_id) == [nil, 4021, 4022, nil])
        #expect(segments.map(\.error) == ["whisper read timed out", nil, nil, nil])
    }

    @Test("absent and null optionals both decode to nil")
    func absentAndNullOptionals() throws {
        let segments = try Self.decode(Self.mixedResponse).segments

        // s03 has a null transcript_id, s01 a null error, s02 no error key and
        // s04 neither optional key.
        #expect(segments[0].transcript_id == nil)
        #expect(segments[1].error == nil)
        #expect(segments[2].error == nil)
        #expect(segments[3].transcript_id == nil)
        #expect(segments[3].error == nil)
    }

    @Test("an unknown status stays a plain string")
    func unknownStatusStaysString() throws {
        let accepted = try JSONDecoder().decode(
            SessionAccepted.self,
            from: Self.data(Self.envelope(
                segment: ["segment_id": "s01", "status": "archived_by_a_newer_server"]
            ))
        )

        #expect(accepted.segments.first?.status == "archived_by_a_newer_server")
    }

    @Test("an unknown envelope status stays a plain string")
    func unknownEnvelopeStatusStaysString() throws {
        let accepted = try JSONDecoder().decode(
            SessionAccepted.self,
            from: Self.data(Self.replacing("status", with: "queued", in: Self.envelopeObject))
        )

        #expect(accepted.status == "queued")
    }

    // MARK: - Missing and mistyped required fields

    @Test("envelope without a required field fails with keyNotFound",
          arguments: ["status", "session_id", "received_at", "processing_status_url", "segments"])
    func envelopeMissingField(key: String) throws {
        let error = try Self.decodingError(from: Self.removing(key, from: Self.envelopeObject))

        #expect(Self.isKeyNotFound(error, key))
    }

    @Test("envelope with a null required field fails with valueNotFound",
          arguments: ["status", "session_id", "received_at", "processing_status_url", "segments"])
    func envelopeNullField(key: String) throws {
        let error = try Self.decodingError(
            from: Self.replacing(key, with: NSNull(), in: Self.envelopeObject)
        )

        #expect(Self.isValueNotFound(error, key))
    }

    @Test("envelope with a mistyped field fails with typeMismatch",
          arguments: [
            ("status", "7"),
            ("session_id", "42"),
            ("received_at", "true"),
            ("processing_status_url", "[]"),
            ("segments", "{}"),
            ("segments", "\"s01\""),
          ])
    func envelopeWrongType(key: String, json: String) throws {
        let error = try Self.decodingError(
            from: Self.replacing(key, with: Self.fragment(json), in: Self.envelopeObject)
        )

        #expect(Self.isTypeMismatch(error, key))
    }

    @Test("segment without a required field fails with keyNotFound",
          arguments: ["segment_id", "status"])
    func segmentMissingField(key: String) throws {
        let error = try Self.decodingError(
            from: Self.envelope(segment: Self.removing(key, from: Self.segmentObject))
        )

        #expect(Self.isKeyNotFound(error, key))
    }

    @Test("segment with a null required field fails with valueNotFound",
          arguments: ["segment_id", "status"])
    func segmentNullField(key: String) throws {
        let error = try Self.decodingError(
            from: Self.envelope(
                segment: Self.replacing(key, with: NSNull(), in: Self.segmentObject)
            )
        )

        #expect(Self.isValueNotFound(error, key))
    }

    @Test("segment with a mistyped field fails with typeMismatch",
          arguments: [
            ("segment_id", "1"),
            ("status", "false"),
            ("transcript_id", "\"4021\""),
            ("transcript_id", "[4021]"),
            ("error", "500"),
            ("error", "{}"),
          ])
    func segmentWrongType(key: String, json: String) throws {
        let error = try Self.decodingError(
            from: Self.envelope(
                segment: Self.replacing(key, with: Self.fragment(json), in: Self.segmentObject)
            )
        )

        #expect(Self.isTypeMismatch(error, key))
    }

    @Test("one bad segment fails the whole response")
    func badSegmentFailsResponse() throws {
        let object = Self.replacing(
            "segments",
            with: [Self.segmentObject, Self.removing("status", from: Self.segmentObject)],
            in: Self.envelopeObject
        )

        let error = try Self.decodingError(from: object)

        #expect(Self.isKeyNotFound(error, "status"))
    }
}
