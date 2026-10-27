import Foundation
import Testing
@testable import VoiceDiary

// The top-level attribution fields of `Manifest` (`drive_by_seeds_surfaced`,
// `drive_by_seeds_unsurfaced`, `raw_session_audio`, `response_language_setting`)
// mirror the server's manifest model (`server/webapp/models.py`) and
// SPEC §10.3. `Manifest` uses the synthesized Codable conformance, so the Swift
// property names are the wire keys. `raw_session_audio` is the only optional
// field: nil is omitted on encode and decodes from an absent or null key.
// `response_language_setting` is a free string; the app does not validate it.
// These tests decode fixed JSON and inspect encoded JSON to pin those keys and
// values. Nested models and the segment discriminator are covered elsewhere.

@Suite("ManifestAttribution")
struct ManifestAttributionTests {
    /// Fixed manifest JSON with every required field. `attribution` is spliced in
    /// so each test controls only the four fields under test.
    private static func manifestJSON(attribution: String) -> String {
        """
        {
          "session_id": "2026-04-27T19:30:00+02:00",
          "date": "2026-04-27",
          "device": "iphone-17-pro",
          "app_version": "0.1.0",
          "locale_primary": "de-DE",
          "audio_codec": {"codec": "aac-lc", "sample_rate": 16000, "channels": 1, "bitrate": 64000},
          "segments": [],
          "todos_implicit_confirmed": [],
          "todos_implicit_rejected": [],
          "ai_prompts": [],
          \(attribution)
        }
        """
    }

    private static let populatedAttribution = """
        "drive_by_seeds_surfaced": ["seed-b", "seed-a", "seed-c"],
        "drive_by_seeds_unsurfaced": ["seed-z", "seed-y"],
        "raw_session_audio": "raw/session.m4a",
        "response_language_setting": "de"
        """

    private static func decode(_ json: String) throws -> Manifest {
        try JSONDecoder().decode(Manifest.self, from: Data(json.utf8))
    }

    private static func encodedObject(_ manifest: Manifest) throws -> [String: Any] {
        let data = try JSONEncoder().encode(manifest)
        return try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
    }

    private static func manifest(
        surfaced: [String] = [],
        unsurfaced: [String] = [],
        rawAudio: String? = nil,
        language: String = "match_input"
    ) -> Manifest {
        Manifest(
            session_id: "2026-04-27T19:30:00+02:00",
            date: "2026-04-27",
            drive_by_seeds_surfaced: surfaced,
            drive_by_seeds_unsurfaced: unsurfaced,
            raw_session_audio: rawAudio,
            response_language_setting: language
        )
    }

    // MARK: - Initializer defaults

    @Test("initializer defaults leave seed lists empty, raw audio nil, language match_input")
    func initializerDefaults() {
        let manifest = Manifest(session_id: "2026-04-27T19:30:00+02:00", date: "2026-04-27")

        #expect(manifest.drive_by_seeds_surfaced.isEmpty)
        #expect(manifest.drive_by_seeds_unsurfaced.isEmpty)
        #expect(manifest.raw_session_audio == nil)
        #expect(manifest.response_language_setting == "match_input")
    }

    // MARK: - Decoding fixed JSON

    @Test("populated attribution fields decode with seed order preserved")
    func decodesPopulatedAttribution() throws {
        let manifest = try Self.decode(Self.manifestJSON(attribution: Self.populatedAttribution))

        #expect(manifest.drive_by_seeds_surfaced == ["seed-b", "seed-a", "seed-c"])
        #expect(manifest.drive_by_seeds_unsurfaced == ["seed-z", "seed-y"])
        #expect(manifest.raw_session_audio == "raw/session.m4a")
        #expect(manifest.response_language_setting == "de")
    }

    @Test("surfaced and unsurfaced lists decode into their own fields")
    func decodesListsIndependently() throws {
        let manifest = try Self.decode(Self.manifestJSON(attribution: """
            "drive_by_seeds_surfaced": ["only-surfaced"],
            "drive_by_seeds_unsurfaced": [],
            "response_language_setting": "en"
            """))

        #expect(manifest.drive_by_seeds_surfaced == ["only-surfaced"])
        #expect(manifest.drive_by_seeds_unsurfaced.isEmpty)

        let swapped = try Self.decode(Self.manifestJSON(attribution: """
            "drive_by_seeds_surfaced": [],
            "drive_by_seeds_unsurfaced": ["only-unsurfaced"],
            "response_language_setting": "en"
            """))

        #expect(swapped.drive_by_seeds_surfaced.isEmpty)
        #expect(swapped.drive_by_seeds_unsurfaced == ["only-unsurfaced"])
    }

    @Test("raw_session_audio decodes to nil when the key is absent")
    func absentRawAudioDecodesToNil() throws {
        let manifest = try Self.decode(Self.manifestJSON(attribution: """
            "drive_by_seeds_surfaced": [],
            "drive_by_seeds_unsurfaced": [],
            "response_language_setting": "match_input"
            """))

        #expect(manifest.raw_session_audio == nil)
    }

    @Test("raw_session_audio decodes to nil when the value is null")
    func nullRawAudioDecodesToNil() throws {
        let manifest = try Self.decode(Self.manifestJSON(attribution: """
            "drive_by_seeds_surfaced": [],
            "drive_by_seeds_unsurfaced": [],
            "raw_session_audio": null,
            "response_language_setting": "match_input"
            """))

        #expect(manifest.raw_session_audio == nil)
    }

    @Test(
        "response_language_setting keeps any string verbatim",
        arguments: ["match_input", "de", "en", "fr-CA", "", " DE ", "Zürich-日本語"]
    )
    func decodesOpaqueResponseLanguage(value: String) throws {
        let literal = try Self.jsonString(value)
        let manifest = try Self.decode(Self.manifestJSON(attribution: """
            "drive_by_seeds_surfaced": [],
            "drive_by_seeds_unsurfaced": [],
            "response_language_setting": \(literal)
            """))

        #expect(manifest.response_language_setting == value)
    }

    // MARK: - Encoded JSON

    @Test("populated attribution fields encode under their wire keys")
    func encodesPopulatedAttribution() throws {
        let object = try Self.encodedObject(Self.manifest(
            surfaced: ["seed-b", "seed-a", "seed-c"],
            unsurfaced: ["seed-z", "seed-y"],
            rawAudio: "raw/session.m4a",
            language: "de"
        ))

        #expect(object["drive_by_seeds_surfaced"] as? [String] == ["seed-b", "seed-a", "seed-c"])
        #expect(object["drive_by_seeds_unsurfaced"] as? [String] == ["seed-z", "seed-y"])
        #expect(object["raw_session_audio"] as? String == "raw/session.m4a")
        #expect(object["response_language_setting"] as? String == "de")
    }

    @Test("default manifest encodes empty seed lists and match_input, omitting raw audio")
    func encodesDefaults() throws {
        let object = try Self.encodedObject(Self.manifest())

        #expect(object["drive_by_seeds_surfaced"] as? [String] == [])
        #expect(object["drive_by_seeds_unsurfaced"] as? [String] == [])
        #expect(object["response_language_setting"] as? String == "match_input")
        #expect(!object.keys.contains("raw_session_audio"))
    }

    @Test("surfaced and unsurfaced lists encode under their own keys")
    func encodesListsIndependently() throws {
        let object = try Self.encodedObject(Self.manifest(
            surfaced: ["only-surfaced"],
            unsurfaced: ["only-unsurfaced-1", "only-unsurfaced-2"]
        ))

        #expect(object["drive_by_seeds_surfaced"] as? [String] == ["only-surfaced"])
        #expect(
            object["drive_by_seeds_unsurfaced"] as? [String]
                == ["only-unsurfaced-1", "only-unsurfaced-2"]
        )
    }

    @Test("response_language_setting encodes an arbitrary string unchanged")
    func encodesOpaqueResponseLanguage() throws {
        let object = try Self.encodedObject(Self.manifest(language: "Zürich-日本語"))

        #expect(object["response_language_setting"] as? String == "Zürich-日本語")
    }

    // MARK: - Round trips

    @Test("populated attribution fields survive a round trip")
    func roundTripPopulated() throws {
        let original = Self.manifest(
            surfaced: ["seed-b", "seed-a", "seed-c"],
            unsurfaced: ["seed-z", "seed-y"],
            rawAudio: "raw/session.m4a",
            language: "en"
        )

        let decoded = try JSONDecoder().decode(
            Manifest.self, from: JSONEncoder().encode(original)
        )

        #expect(decoded.drive_by_seeds_surfaced == ["seed-b", "seed-a", "seed-c"])
        #expect(decoded.drive_by_seeds_unsurfaced == ["seed-z", "seed-y"])
        #expect(decoded.raw_session_audio == "raw/session.m4a")
        #expect(decoded.response_language_setting == "en")
    }

    @Test("nil raw audio and default attribution survive a round trip")
    func roundTripDefaults() throws {
        let decoded = try JSONDecoder().decode(
            Manifest.self, from: JSONEncoder().encode(Self.manifest())
        )

        #expect(decoded.drive_by_seeds_surfaced.isEmpty)
        #expect(decoded.drive_by_seeds_unsurfaced.isEmpty)
        #expect(decoded.raw_session_audio == nil)
        #expect(decoded.response_language_setting == "match_input")
    }

    /// JSON string literal for `value`, so fixtures can embed arbitrary text.
    private static func jsonString(_ value: String) throws -> String {
        let data = try JSONEncoder().encode(value)
        return try #require(String(data: data, encoding: .utf8))
    }
}
