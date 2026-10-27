import Foundation
import Testing
@testable import VoiceDiary

// IOS-A42: `metadata.json` compatibility for `VoiceNote` and
// `VoiceNoteChunk`. Notes recorded before pause/resume chunks existed carry
// no `chunks` key (or a null one) and must keep decoding with `chunks == nil`;
// multi-chunk notes must keep their per-chunk order and content. The JSON
// fixtures are written by hand, independent of the models, and read and
// written with the date strategy `SessionHistoryStore.loadVoiceNotes` and
// `CaptureCoordinator` use (ISO 8601). No file system, no audio.

@Suite("VoiceNotePersistence")
struct VoiceNotePersistenceTests {
    /// 2026-05-20T08:00:00Z, the instant the fixtures spell as ISO 8601.
    private static let capturedAt = Date(timeIntervalSince1970: 1_779_264_000)

    private static let audioURL = URL(string: "file:///var/mobile/voice_notes/2026-05-20T08-00-00/audio.m4a")!

    private static let absentChunksJSON = """
        {
          "seed_id": "note-legacy",
          "captured_at": "2026-05-20T08:00:00Z",
          "duration_seconds": 5.5,
          "language": "de",
          "transcript": "Einkaufen nicht vergessen",
          "audio_file_url": "file:///var/mobile/voice_notes/2026-05-20T08-00-00/audio.m4a"
        }
        """

    private static let nullChunksJSON = """
        {
          "seed_id": "note-legacy",
          "captured_at": "2026-05-20T08:00:00Z",
          "duration_seconds": 5.5,
          "language": "de",
          "transcript": "Einkaufen nicht vergessen",
          "audio_file_url": "file:///var/mobile/voice_notes/2026-05-20T08-00-00/audio.m4a",
          "chunks": null
        }
        """

    private static let multiChunkJSON = """
        {
          "seed_id": "note-multi",
          "captured_at": "2026-05-20T08:00:00Z",
          "duration_seconds": 12.5,
          "language": "de",
          "transcript": "Erster Teil",
          "audio_file_url": "file:///var/mobile/voice_notes/2026-05-20T08-00-00/audio.m4a",
          "chunks": [
            {
              "filename": "audio.m4a",
              "duration_seconds": 12.5,
              "language": "de",
              "transcript": "Erster Teil"
            },
            {
              "filename": "audio_002.m4a",
              "duration_seconds": 30.25,
              "language": "en",
              "transcript": "Second part"
            },
            {
              "filename": "audio_003.m4a",
              "duration_seconds": 4,
              "language": "de",
              "transcript": "Dritter Teil"
            }
          ]
        }
        """

    private static func decode(_ json: String) throws -> VoiceNote {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(VoiceNote.self, from: Data(json.utf8))
    }

    private static func roundTrip(_ note: VoiceNote) throws -> VoiceNote {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(note)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(VoiceNote.self, from: data)
    }

    private func expectLegacyFields(_ note: VoiceNote) {
        #expect(note.seed_id == "note-legacy")
        #expect(note.captured_at == Self.capturedAt)
        #expect(note.duration_seconds == 5.5)
        #expect(note.language == "de")
        #expect(note.transcript == "Einkaufen nicht vergessen")
        #expect(note.audio_file_url == Self.audioURL)
    }

    private func expectMultiChunkContent(_ note: VoiceNote) {
        #expect(note.seed_id == "note-multi")
        #expect(note.captured_at == Self.capturedAt)
        #expect(note.audio_file_url == Self.audioURL)
        #expect(note.duration_seconds == 12.5)
        #expect(note.language == "de")
        #expect(note.transcript == "Erster Teil")
        #expect(note.chunks?.map(\.filename) == ["audio.m4a", "audio_002.m4a", "audio_003.m4a"])
        #expect(note.chunks?.map(\.duration_seconds) == [12.5, 30.25, 4])
        #expect(note.chunks?.map(\.language) == ["de", "en", "de"])
        #expect(note.chunks?.map(\.transcript) == ["Erster Teil", "Second part", "Dritter Teil"])
    }

    @Test("a legacy note without a chunks key decodes with nil chunks")
    func absentChunksKeyDecodesToNil() throws {
        let note = try Self.decode(Self.absentChunksJSON)
        expectLegacyFields(note)
        #expect(note.chunks == nil)
    }

    @Test("a legacy note with a null chunks value decodes with nil chunks")
    func nullChunksDecodesToNil() throws {
        let note = try Self.decode(Self.nullChunksJSON)
        expectLegacyFields(note)
        #expect(note.chunks == nil)
    }

    @Test("a legacy note round-trips without gaining chunks")
    func legacyRoundTripStaysNil() throws {
        let note = try Self.roundTrip(Self.decode(Self.absentChunksJSON))
        expectLegacyFields(note)
        #expect(note.chunks == nil)
    }

    @Test("a multi-chunk note decodes every chunk in file order")
    func multiChunkDecodes() throws {
        expectMultiChunkContent(try Self.decode(Self.multiChunkJSON))
    }

    @Test("a multi-chunk note round-trips with order and content intact")
    func multiChunkRoundTrips() throws {
        expectMultiChunkContent(try Self.roundTrip(Self.decode(Self.multiChunkJSON)))
    }

    @Test("a chunk is identified by its filename")
    func chunkIdentityIsFilename() throws {
        let chunks = try #require(Self.decode(Self.multiChunkJSON).chunks)
        #expect(chunks.map(\.id) == ["audio.m4a", "audio_002.m4a", "audio_003.m4a"])
    }
}
