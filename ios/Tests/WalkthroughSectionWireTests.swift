import Foundation
import Testing
@testable import VoiceDiary

// `WalkthroughSection` is persisted as JSON in `UserDefaults`
// (`walkthrough.sectionOrder.v1`) by `WalkthroughSettingsStore.saveOrder`, so a
// plan saved by one build must stay readable by the next. The wire shape is a
// hand-written codec: `{ "kind": "general", "id": "<uuid>" }`,
// `{ "kind": "calendar_events" }` and `{ "kind": "drive_by" }`. `drive_by` is the
// historical spelling of the `voiceNote` case and must not be renamed.
//
// Decoding tests read fixed literal JSON and encoding tests read the keys back
// with `JSONSerialization`, so the wire shape is pinned independently of the
// type under test. Stable identities (`general:<id>`, `system:calendarEvents`,
// `system:voiceNote`) are what the plan builder and manifest key on.

@Suite("WalkthroughSectionWire")
struct WalkthroughSectionWireTests {
    private static let generalJSON = #"{"kind":"general","id":"g-1"}"#
    private static let calendarJSON = #"{"kind":"calendar_events"}"#
    private static let voiceNoteJSON = #"{"kind":"drive_by"}"#

    private static func decode(_ json: String) throws -> WalkthroughSection {
        try JSONDecoder().decode(WalkthroughSection.self, from: Data(json.utf8))
    }

    private static func decodeError(_ json: String) -> DecodingError? {
        do {
            _ = try decode(json)
            return nil
        } catch let error as DecodingError {
            return error
        } catch {
            return nil
        }
    }

    private static func wireObject(_ section: WalkthroughSection) throws -> [String: Any] {
        let data = try JSONEncoder().encode(section)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// The coding key named by the error, or nil if it carries none.
    private static func failingKey(_ error: DecodingError?) -> String? {
        switch error {
        case .keyNotFound(let key, _): key.stringValue
        case .typeMismatch(_, let context), .valueNotFound(_, let context),
             .dataCorrupted(let context): context.codingPath.last?.stringValue
        default: nil
        }
    }

    // MARK: - Decoding fixtures

    @Test("Decodes each persisted kind to its case",
          arguments: [
            (WalkthroughSectionWireTests.generalJSON, WalkthroughSection.general(id: "g-1")),
            (WalkthroughSectionWireTests.calendarJSON, WalkthroughSection.calendarEvents),
            (WalkthroughSectionWireTests.voiceNoteJSON, WalkthroughSection.voiceNote),
          ])
    func decodesFixture(json: String, expected: WalkthroughSection) throws {
        #expect(try Self.decode(json) == expected)
    }

    // MARK: - Encoding

    @Test("General encodes kind and id only")
    func encodesGeneral() throws {
        let object = try Self.wireObject(.general(id: "g-1"))
        #expect(object["kind"] as? String == "general")
        #expect(object["id"] as? String == "g-1")
        #expect(Set(object.keys) == ["kind", "id"])
    }

    @Test("calendarEvents encodes calendar_events and no id")
    func encodesCalendarEvents() throws {
        let object = try Self.wireObject(.calendarEvents)
        #expect(object["kind"] as? String == "calendar_events")
        #expect(Set(object.keys) == ["kind"])
    }

    @Test("voiceNote encodes the historical drive_by kind and no id")
    func encodesVoiceNote() throws {
        let object = try Self.wireObject(.voiceNote)
        #expect(object["kind"] as? String == "drive_by")
        #expect(Set(object.keys) == ["kind"])
    }

    // MARK: - Stable identity

    @Test("Identities are stable strings per case",
          arguments: [
            (WalkthroughSection.general(id: "g-1"), "general:g-1"),
            (WalkthroughSection.calendarEvents, "system:calendarEvents"),
            (WalkthroughSection.voiceNote, "system:voiceNote"),
          ])
    func identity(section: WalkthroughSection, expected: String) {
        #expect(section.id == expected)
    }

    @Test("Decoded sections keep their identities")
    func decodedIdentities() throws {
        #expect(try Self.decode(Self.generalJSON).id == "general:g-1")
        #expect(try Self.decode(Self.calendarJSON).id == "system:calendarEvents")
        #expect(try Self.decode(Self.voiceNoteJSON).id == "system:voiceNote")
    }

    // MARK: - Array order

    @Test("A persisted array decodes in stored order")
    func decodesArrayInOrder() throws {
        let json = "[\(Self.voiceNoteJSON),\(Self.generalJSON),\(Self.calendarJSON)]"
        let decoded = try JSONDecoder().decode([WalkthroughSection].self, from: Data(json.utf8))
        #expect(decoded == [.voiceNote, .general(id: "g-1"), .calendarEvents])
        #expect(decoded.map(\.id) == ["system:voiceNote", "general:g-1", "system:calendarEvents"])
    }

    @Test("Array order survives an encode/decode round trip")
    func roundTripKeepsOrder() throws {
        let plan: [WalkthroughSection] = [
            .general(id: "b"), .voiceNote, .general(id: "a"), .calendarEvents,
        ]
        let data = try JSONEncoder().encode(plan)
        let decoded = try JSONDecoder().decode([WalkthroughSection].self, from: data)
        #expect(decoded == plan)
        #expect(decoded.map(\.id) == ["general:b", "system:voiceNote", "general:a", "system:calendarEvents"])
    }

    @Test("Encoded array holds one object per section in plan order")
    func encodedArrayShape() throws {
        let plan: [WalkthroughSection] = [.calendarEvents, .general(id: "g-1"), .voiceNote]
        let data = try JSONEncoder().encode(plan)
        let objects = try #require(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        #expect(objects.compactMap { $0["kind"] as? String } == ["calendar_events", "general", "drive_by"])
        #expect(objects.map { $0["id"] as? String } == [nil, "g-1", nil])
    }

    // MARK: - Malformed input

    @Test("A missing kind throws keyNotFound")
    func missingKind() {
        let error = Self.decodeError(#"{"id":"g-1"}"#)
        guard case .keyNotFound = error else {
            Issue.record("expected keyNotFound, got \(String(describing: error))")
            return
        }
        #expect(Self.failingKey(error) == "kind")
    }

    @Test("A wrong-typed kind throws typeMismatch")
    func wrongTypedKind() {
        let error = Self.decodeError(#"{"kind":5}"#)
        guard case .typeMismatch = error else {
            Issue.record("expected typeMismatch, got \(String(describing: error))")
            return
        }
        #expect(Self.failingKey(error) == "kind")
    }

    @Test("An unknown kind throws dataCorrupted")
    func unknownKind() {
        let error = Self.decodeError(#"{"kind":"mystery"}"#)
        guard case .dataCorrupted = error else {
            Issue.record("expected dataCorrupted, got \(String(describing: error))")
            return
        }
        #expect(Self.failingKey(error) == "kind")
    }

    @Test("A general section without an id throws keyNotFound")
    func generalMissingID() {
        let error = Self.decodeError(#"{"kind":"general"}"#)
        guard case .keyNotFound = error else {
            Issue.record("expected keyNotFound, got \(String(describing: error))")
            return
        }
        #expect(Self.failingKey(error) == "id")
    }

    @Test("A general section with a wrong-typed id throws typeMismatch")
    func generalWrongTypedID() {
        let error = Self.decodeError(#"{"kind":"general","id":7}"#)
        guard case .typeMismatch = error else {
            Issue.record("expected typeMismatch, got \(String(describing: error))")
            return
        }
        #expect(Self.failingKey(error) == "id")
    }

    @Test("A null general id throws valueNotFound")
    func generalNullID() {
        let error = Self.decodeError(#"{"kind":"general","id":null}"#)
        guard case .valueNotFound = error else {
            Issue.record("expected valueNotFound, got \(String(describing: error))")
            return
        }
        #expect(Self.failingKey(error) == "id")
    }

    @Test("One unreadable entry fails the whole array")
    func unreadableEntryFailsArray() {
        let json = "[\(Self.calendarJSON),{\"kind\":\"mystery\"}]"
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode([WalkthroughSection].self, from: Data(json.utf8))
        }
    }

    // MARK: - Additive fields

    @Test("Unknown additive fields do not change the decoded case",
          arguments: [
            (#"{"kind":"general","id":"g-1","label":"Morning","weight":2}"#, WalkthroughSection.general(id: "g-1")),
            (#"{"kind":"calendar_events","collapsed":true}"#, WalkthroughSection.calendarEvents),
            (#"{"kind":"drive_by","futureField":{"nested":[1,2]}}"#, WalkthroughSection.voiceNote),
          ])
    func ignoresUnknownFields(json: String, expected: WalkthroughSection) throws {
        let decoded = try Self.decode(json)
        #expect(decoded == expected)
        #expect(decoded.id == expected.id)
    }
}
