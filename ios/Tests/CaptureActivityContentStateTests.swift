import Foundation
import Testing
@testable import VoiceDiary

// `CaptureActivityAttributes.ContentState` crosses the ActivityKit boundary: a
// Live Activity started by an older build can be updated or rendered by a newer
// one. The decoder is custom: `startedAt`, `elapsedSeconds` and `kind` are
// required, while `isPaused` (added later) is optional and falls back to false
// so an in-flight activity keeps ticking instead of being orphaned. Malformed
// or unknown values must throw rather than invent state.
//
// Decoding tests read fixed literal JSON so the persisted shape is pinned
// independently of the type under test. Dates use the default
// `JSONDecoder` strategy (seconds since the 2001 reference date). No
// ActivityKit requests.

@Suite("CaptureActivityContentState")
struct CaptureActivityContentStateTests {
    typealias ContentState = CaptureActivityAttributes.ContentState

    private static let requiredKeys = ["startedAt", "elapsedSeconds", "kind"]
    private static let startedAt = Date(timeIntervalSinceReferenceDate: 700_000_000)

    private static func decode(_ json: String) throws -> ContentState {
        try JSONDecoder().decode(ContentState.self, from: Data(json.utf8))
    }

    private static func roundTrip(_ state: ContentState) throws -> ContentState {
        let data = try JSONEncoder().encode(state)
        return try JSONDecoder().decode(ContentState.self, from: data)
    }

    /// A state object with valid required fields; `fields` overrides or adds
    /// raw JSON values by key, and a nil value drops the key.
    private static func stateJSON(_ fields: [String: String?] = [:]) -> String {
        var members: [String: String?] = [
            "startedAt": "700000000",
            "elapsedSeconds": "42",
            "kind": #""recording""#,
        ]
        members.merge(fields) { _, override in override }
        return "{" + members.compactMap { key, value in value.map { #""\#(key)":\#($0)"# } }.sorted().joined(separator: ",") + "}"
    }

    // MARK: isPaused fallback

    @Test("a verbatim legacy payload without isPaused decodes as not paused")
    func legacyLiteralPayloadDecodes() throws {
        let state = try Self.decode(#"{"startedAt":700000000,"elapsedSeconds":42,"kind":"recording"}"#)
        #expect(state == ContentState(startedAt: Self.startedAt, elapsedSeconds: 42, kind: .recording, isPaused: false))
    }

    @Test("a verbatim payload with a null isPaused decodes as not paused")
    func nullLiteralPayloadDecodes() throws {
        let state = try Self.decode(#"{"startedAt":700000000,"elapsedSeconds":42,"kind":"speaking","isPaused":null}"#)
        #expect(state == ContentState(startedAt: Self.startedAt, elapsedSeconds: 42, kind: .speaking, isPaused: false))
    }

    @Test("an explicit isPaused keeps date, elapsedSeconds and kind intact through decode and encode/decode",
          arguments: [true, false])
    func explicitIsPausedSurvives(_ isPaused: Bool) throws {
        let decoded = try Self.decode(Self.stateJSON(["isPaused": "\(isPaused)", "kind": #""listening""#]))
        #expect(decoded == ContentState(startedAt: Self.startedAt, elapsedSeconds: 42, kind: .listening, isPaused: isPaused))

        let original = ContentState(startedAt: Date(timeIntervalSinceReferenceDate: 123_456_789.5),
                                    elapsedSeconds: 3_599,
                                    kind: .speaking,
                                    isPaused: isPaused)
        let object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any]
        )
        #expect(object["isPaused"] as? Bool == isPaused)

        let roundTripped = try Self.roundTrip(original)
        #expect(roundTripped.startedAt == original.startedAt)
        #expect(roundTripped.elapsedSeconds == 3_599)
        #expect(roundTripped.kind == .speaking)
        #expect(roundTripped.isPaused == isPaused)
    }

    // MARK: kind wire strings

    @Test("kind uses its documented wire string",
          arguments: [
              ("recording", CaptureActivityAttributes.Kind.recording),
              ("speaking", .speaking),
              ("listening", .listening),
          ])
    func kindWireStrings(_ wire: String, _ expected: CaptureActivityAttributes.Kind) throws {
        #expect(try Self.decode(Self.stateJSON(["kind": #""\#(wire)""#])).kind == expected)

        let encoded = try JSONEncoder().encode(ContentState(startedAt: Self.startedAt, elapsedSeconds: 0, kind: expected))
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(object["kind"] as? String == wire)
    }

    @Test("an unknown kind throws instead of falling back to recording",
          arguments: [#""paused""#, #""Recording""#, #""""#])
    func unknownKindThrows(_ wire: String) {
        #expect {
            try Self.decode(Self.stateJSON(["kind": wire]))
        } throws: { error in
            guard case DecodingError.dataCorrupted = error else { return false }
            return true
        }
    }

    // MARK: malformed required fields

    @Test("a missing required field throws", arguments: requiredKeys)
    func missingRequiredFieldThrows(_ key: String) {
        #expect {
            try Self.decode(Self.stateJSON([key: nil]))
        } throws: { error in
            guard case DecodingError.keyNotFound = error else { return false }
            return true
        }
    }

    @Test("a null required field throws", arguments: requiredKeys)
    func nullRequiredFieldThrows(_ key: String) {
        #expect(throws: DecodingError.self) {
            try Self.decode(Self.stateJSON([key: "null"]))
        }
    }

    @Test("wrongly typed required fields throw",
          arguments: [
              ("startedAt", #""yesterday""#),
              ("elapsedSeconds", #""42""#),
              ("elapsedSeconds", "4.5"),
              ("kind", "1"),
          ])
    func wronglyTypedRequiredFieldThrows(_ key: String, _ value: String) {
        #expect(throws: DecodingError.self) {
            try Self.decode(Self.stateJSON([key: value]))
        }
    }

    @Test("a wrongly typed isPaused throws instead of reading as not paused",
          arguments: [#""true""#, "1", #""""#])
    func malformedIsPausedThrows(_ value: String) {
        #expect(throws: DecodingError.self) {
            try Self.decode(Self.stateJSON(["isPaused": value]))
        }
    }
}
