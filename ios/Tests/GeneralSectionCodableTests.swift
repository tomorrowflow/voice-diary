import Foundation
import Testing
@testable import VoiceDiary

// `GeneralSection` is persisted as JSON (`WalkthroughSettingsStore.generals`),
// so sections saved by older builds must keep decoding. The decoder is custom:
// `id`, `title` and `introText` are required, while `followUpEnabled` (added
// later) is optional and falls back to false so an old section keeps its
// quieter behaviour. A malformed value must throw rather than silently enable
// the follow-up or drop the section.
//
// Decoding tests read fixed literal JSON so the persisted shape is pinned
// independently of the type under test. No UserDefaults access.

@Suite("GeneralSectionCodable")
struct GeneralSectionCodableTests {
    private static let requiredKeys = ["id", "title", "introText"]

    private static func decode(_ json: String) throws -> GeneralSection {
        try JSONDecoder().decode(GeneralSection.self, from: Data(json.utf8))
    }

    private static func roundTrip(_ section: GeneralSection) throws -> GeneralSection {
        let data = try JSONEncoder().encode(section)
        return try JSONDecoder().decode(GeneralSection.self, from: data)
    }

    /// A section object with valid required fields; `fields` overrides or adds
    /// raw JSON values by key, and a nil value drops the key.
    private static func sectionJSON(_ fields: [String: String?] = [:]) -> String {
        var members: [String: String?] = ["id": #""g1""#, "title": #""Morning""#, "introText": #""Hi""#]
        members.merge(fields) { _, override in override }
        return "{" + members.compactMap { key, value in value.map { #""\#(key)":\#($0)"# } }.sorted().joined(separator: ",") + "}"
    }

    // MARK: followUpEnabled fallback

    @Test("a legacy section without followUpEnabled decodes with it off")
    func missingFollowUpDefaultsToFalse() throws {
        let section = try Self.decode(Self.sectionJSON())
        #expect(section == GeneralSection(id: "g1", title: "Morning", introText: "Hi", followUpEnabled: false))
    }

    @Test("a null followUpEnabled decodes as off")
    func nullFollowUpDefaultsToFalse() throws {
        let section = try Self.decode(Self.sectionJSON(["followUpEnabled": "null"]))
        #expect(section.followUpEnabled == false)
    }

    @Test("an explicit followUpEnabled survives decode and encode/decode", arguments: [true, false])
    func explicitFollowUpSurvives(enabled: Bool) throws {
        let section = try Self.decode(Self.sectionJSON(["followUpEnabled": "\(enabled)"]))
        #expect(section.followUpEnabled == enabled)
        #expect(try Self.roundTrip(section).followUpEnabled == enabled)
    }

    @Test("a wrong-typed followUpEnabled throws", arguments: [
        #""true""#, "1", "0", "[]", "{}", "\"\""
    ])
    func wrongTypedFollowUpThrows(value: String) {
        let json = Self.sectionJSON(["followUpEnabled": value])
        #expect(throws: DecodingError.self) { try Self.decode(json) }
    }

    // MARK: verbatim text

    @Test("id, title and introText round-trip verbatim, including Unicode and whitespace")
    func textFieldsSurviveVerbatim() throws {
        let section = GeneralSection(
            id: " 0F8A-ü ",
            title: "  Dankbarkeit 🙏\tund Ruhe  ",
            introText: "Wie ist dein Morgen heute angekommen?\n\n  日本語 — «naïve» \u{200B}\n",
            followUpEnabled: true
        )
        #expect(try Self.roundTrip(section) == section)
    }

    @Test("literal JSON with escapes decodes to the exact stored strings")
    func literalJSONDecodesVerbatim() throws {
        let section = try Self.decode(
            #"{"id":" a ","title":"ü 🙏","introText":"line1\n  line2 ","followUpEnabled":true}"#
        )
        #expect(section.id == " a ")
        #expect(section.title == "ü 🙏")
        #expect(section.introText == "line1\n  line2 ")
    }

    // MARK: required fields

    @Test("a missing required field throws", arguments: requiredKeys)
    func missingRequiredFieldThrows(key: String) {
        let json = Self.sectionJSON([key: nil])
        #expect(throws: DecodingError.self) { try Self.decode(json) }
    }

    @Test("a null or wrong-typed required field throws", arguments: requiredKeys, ["null", "1", "true", "[]"])
    func wrongTypedRequiredFieldThrows(key: String, value: String) {
        let json = Self.sectionJSON([key: value])
        #expect(throws: DecodingError.self) { try Self.decode(json) }
    }

    // MARK: additive fields and encoding

    @Test("unknown additive fields are ignored")
    func unknownFieldsAreIgnored() throws {
        let section = try Self.decode(
            Self.sectionJSON(["followUpEnabled": "true", "color": #""red""#, "order": "3", "nested": #"{"a":[1,2]}"#])
        )
        #expect(section == GeneralSection(id: "g1", title: "Morning", introText: "Hi", followUpEnabled: true))
    }

    @Test("encoding writes exactly the four persisted keys")
    func encodingWritesPersistedKeys() throws {
        let data = try JSONEncoder().encode(
            GeneralSection(id: "g1", title: "Morning", introText: "Hi", followUpEnabled: true)
        )
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == ["id", "title", "introText", "followUpEnabled"])
        #expect(object["id"] as? String == "g1")
        #expect(object["title"] as? String == "Morning")
        #expect(object["introText"] as? String == "Hi")
        #expect(object["followUpEnabled"] as? Bool == true)
    }
}
