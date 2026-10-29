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
    private static func decode(_ json: String) throws -> GeneralSection {
        try JSONDecoder().decode(GeneralSection.self, from: Data(json.utf8))
    }

    private static func roundTrip(_ section: GeneralSection) throws -> GeneralSection {
        let data = try JSONEncoder().encode(section)
        return try JSONDecoder().decode(GeneralSection.self, from: data)
    }

    // MARK: followUpEnabled fallback

    @Test("a legacy section without followUpEnabled decodes with it off")
    func missingFollowUpDefaultsToFalse() throws {
        let section = try Self.decode(#"{"id":"g1","title":"Morning","introText":"How was it?"}"#)
        #expect(section == GeneralSection(id: "g1", title: "Morning", introText: "How was it?", followUpEnabled: false))
    }

    @Test("a null followUpEnabled decodes as off")
    func nullFollowUpDefaultsToFalse() throws {
        let section = try Self.decode(
            #"{"id":"g1","title":"Morning","introText":"How was it?","followUpEnabled":null}"#
        )
        #expect(section.followUpEnabled == false)
    }

    @Test("an explicit followUpEnabled survives decode and encode/decode", arguments: [true, false])
    func explicitFollowUpSurvives(enabled: Bool) throws {
        let section = try Self.decode(
            #"{"id":"g1","title":"Morning","introText":"How was it?","followUpEnabled":\#(enabled)}"#
        )
        #expect(section.followUpEnabled == enabled)
        #expect(try Self.roundTrip(section).followUpEnabled == enabled)
    }

    @Test("a wrong-typed followUpEnabled throws", arguments: [
        #""true""#, "1", "0", "[]", "{}", #""""#
    ])
    func wrongTypedFollowUpThrows(value: String) {
        let json = #"{"id":"g1","title":"Morning","introText":"How was it?","followUpEnabled":\#(value)}"#
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
        let decoded = try Self.roundTrip(section)
        #expect(decoded.id == section.id)
        #expect(decoded.title == section.title)
        #expect(decoded.introText == section.introText)
        #expect(decoded == section)
    }

    @Test("empty text fields are kept, not rejected")
    func emptyTextFieldsAreKept() throws {
        let section = try Self.decode(#"{"id":"","title":"","introText":""}"#)
        #expect(section == GeneralSection(id: "", title: "", introText: ""))
    }

    @Test("literal JSON decodes to the exact stored strings")
    func literalJSONDecodesVerbatim() throws {
        let section = try Self.decode(
            #"{"id":" a ","title":"ü 🙏","introText":"line1\n  line2 ","followUpEnabled":true}"#
        )
        #expect(section.id == " a ")
        #expect(section.title == "ü 🙏")
        #expect(section.introText == "line1\n  line2 ")
    }

    // MARK: required fields

    @Test("a missing required field throws", arguments: ["id", "title", "introText"])
    func missingRequiredFieldThrows(key: String) {
        var fields = ["id": "g1", "title": "Morning", "introText": "Hi"]
        fields[key] = nil
        let json = Self.json(fields.map { #""\#($0.key)":"\#($0.value)""# })
        #expect(throws: DecodingError.self) { try Self.decode(json) }
    }

    @Test("a null or wrong-typed required field throws", arguments: ["id", "title", "introText"], ["null", "1", "true", "[]"])
    func wrongTypedRequiredFieldThrows(key: String, value: String) {
        var fields = ["id": #""g1""#, "title": #""Morning""#, "introText": #""Hi""#]
        fields[key] = value
        let json = Self.json(fields.map { #""\#($0.key)":\#($0.value)"# })
        #expect(throws: DecodingError.self) { try Self.decode(json) }
    }

    @Test("a non-object payload throws", arguments: ["[]", #""g1""#, "null", "42"])
    func nonObjectPayloadThrows(json: String) {
        #expect(throws: DecodingError.self) { try Self.decode(json) }
    }

    // MARK: additive fields and encoding

    @Test("unknown additive fields are ignored")
    func unknownFieldsAreIgnored() throws {
        let section = try Self.decode(
            #"{"id":"g1","title":"Morning","introText":"Hi","followUpEnabled":true,"color":"red","order":3,"nested":{"a":[1,2]}}"#
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

    @Test("a persisted array of mixed legacy and current sections decodes in order")
    func mixedArrayDecodes() throws {
        let json = """
        [
          {"id":"old","title":"Old","introText":"Legacy"},
          {"id":"new","title":"New","introText":"Current","followUpEnabled":true}
        ]
        """
        let sections = try JSONDecoder().decode([GeneralSection].self, from: Data(json.utf8))
        #expect(sections == [
            GeneralSection(id: "old", title: "Old", introText: "Legacy", followUpEnabled: false),
            GeneralSection(id: "new", title: "New", introText: "Current", followUpEnabled: true)
        ])
    }

    private static func json(_ members: [String]) -> String {
        "{" + members.sorted().joined(separator: ",") + "}"
    }
}
