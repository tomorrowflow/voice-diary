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

    private static func decodeArray(_ json: String) throws -> [WalkthroughSection] {
        try JSONDecoder().decode([WalkthroughSection].self, from: Data(json.utf8))
    }

    /// `DecodingError`'s cases carry payloads and are not `Equatable`, so tests compare this.
    enum Failure: Equatable {
        case keyNotFound, typeMismatch, valueNotFound, dataCorrupted

        init(_ error: DecodingError) {
            switch error {
            case .keyNotFound: self = .keyNotFound
            case .typeMismatch: self = .typeMismatch
            case .valueNotFound: self = .valueNotFound
            default: self = .dataCorrupted
            }
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

    // MARK: - Array order

    @Test("A persisted array decodes in stored order")
    func decodesArrayInOrder() throws {
        let json = "[\(Self.voiceNoteJSON),\(Self.generalJSON),\(Self.calendarJSON)]"
        let decoded = try Self.decodeArray(json)
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

    @Test("Malformed sections throw the matching DecodingError on the offending key",
          arguments: [
            (#"{"id":"g-1"}"#, Failure.keyNotFound, "kind"),
            (#"{"kind":5}"#, Failure.typeMismatch, "kind"),
            (#"{"kind":"mystery"}"#, Failure.dataCorrupted, "kind"),
            (#"{"kind":"general"}"#, Failure.keyNotFound, "id"),
            (#"{"kind":"general","id":7}"#, Failure.typeMismatch, "id"),
            (#"{"kind":"general","id":null}"#, Failure.valueNotFound, "id"),
          ])
    func malformedSection(json: String, failure: Failure, key: String) {
        let error = Self.decodeError(json)
        #expect(error.map(Failure.init) == failure)
        #expect(Self.failingKey(error) == key)
    }

    // MARK: - Additive fields

    @Test("Unknown additive fields do not change the decoded case",
          arguments: [
            (#"{"kind":"general","id":"g-1","label":"Morning","weight":2}"#, WalkthroughSection.general(id: "g-1")),
            (#"{"kind":"calendar_events","collapsed":true}"#, WalkthroughSection.calendarEvents),
            (#"{"kind":"drive_by","futureField":{"nested":[1,2]}}"#, WalkthroughSection.voiceNote),
          ])
    func ignoresUnknownFields(json: String, expected: WalkthroughSection) throws {
        #expect(try Self.decode(json) == expected)
    }
}
