import Foundation

/// The destructive edits the Verlauf screens make to a recorded session:
/// removing a whole entry, one walkthrough segment, one chunk of a
/// multi-chunk note, or a note surfaced into a walkthrough, plus the
/// metadata rewrite that keeps a note's surviving chunks playable.
///
/// Views keep the confirmation, player stop, dismiss, the displayed errors
/// and their own row state; they call in here after the user confirmed. File removal, the
/// metadata write and the upload-queue orphan purge are injected so a test
/// can run every path against a temporary directory and record the order.
@MainActor
struct SessionMutations {
    /// What the caller has to do after a mutation.
    enum Outcome: Equatable {
        /// The row is gone but the entry lives on; hide the row.
        case rowRemoved
        /// The whole entry is gone; leave the detail screen.
        case entryRemoved
    }

    private let removeItem: (URL) throws -> Void
    private let writeMetadata: (Data, URL) throws -> Void
    private let schedulePurge: () -> Void

    init(
        removeItem: @escaping (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) },
        writeMetadata: @escaping (Data, URL) throws -> Void = SessionMutations.writeVoiceNoteMetadata,
        schedulePurge: @escaping () -> Void = SessionMutations.purgeUploadQueueOrphans
    ) {
        self.removeItem = removeItem
        self.writeMetadata = writeMetadata
        self.schedulePurge = schedulePurge
    }

    /// Permanently remove a whole history entry. Throws when the removal
    /// fails (nothing is purged then) so the list can show the error.
    func deleteEntry(_ item: SessionHistoryStore.Item) throws {
        try SessionHistoryStore.delete(item, removing: removeItem)
        // Belt-and-braces: drop any matching upload-queue entry so we
        // don't keep retrying an upload whose source is gone.
        schedulePurge()
    }

    /// Delete one segment row of the detail screen. For a walkthrough
    /// that's the segment's audio file (the session and its other
    /// segments stay). For a single-chunk note the single row *is* the
    /// whole note, so the note goes. For a multi-chunk note (pause/resume)
    /// just the swiped chunk's m4a goes and metadata.json is rewritten so
    /// the remaining chunks stay playable. A removed source also drops
    /// any pending upload.
    ///
    /// Stopping playback stays with the view, which calls this after it
    /// has stopped the player (see `removesWholeEntry`).
    func deleteSegment(
        _ segment: SegmentDescriptor,
        in item: SessionHistoryStore.Item
    ) -> Outcome {
        switch item {
        case .voiceNote(let entry):
            if let url = Self.chunkURL(of: segment, in: entry) {
                try? removeItem(url)
                let outcome = rewriteVoiceNoteMetadata(removing: url.lastPathComponent, in: entry)
                schedulePurge()
                return outcome
            }
            try? SessionHistoryStore.delete(item, removing: removeItem)
            schedulePurge()
            return .entryRemoved
        case .walkthrough:
            if let url = segment.audioURL { try? removeItem(url) }
            schedulePurge()
            return .rowRemoved
        }
    }

    /// Whether deleting this row takes the whole note with it (a
    /// single-chunk note's only row), so the view stops whatever is playing
    /// rather than only a player on the row's own file.
    func removesWholeEntry(_ segment: SegmentDescriptor, in item: SessionHistoryStore.Item) -> Bool {
        guard case .voiceNote(let entry) = item else { return false }
        return Self.chunkURL(of: segment, in: entry) == nil
    }

    /// The row's file when it is one chunk of a multi-chunk note.
    private static func chunkURL(
        of segment: SegmentDescriptor,
        in entry: SessionHistoryStore.VoiceNoteEntry
    ) -> URL? {
        (entry.note.chunks?.count ?? 0) > 1 ? segment.audioURL : nil
    }

    /// Delete one surfaced note. A surfaced note is a standalone drive-by
    /// recording living under `driveby_seeds/`, so this removes its whole
    /// directory — it disappears from the Verlauf list too.
    func deleteSurfacedNote(_ note: SurfacedNoteEntry) {
        try? removeItem(note.audioURL.deletingLastPathComponent())
        schedulePurge()
    }

    /// Rewrite the drive-by recording's metadata.json after a single
    /// chunk was swiped out, keeping the surviving chunks intact. If the
    /// removal leaves zero chunks the directory is purged (`.entryRemoved`);
    /// if one survives we collapse `chunks` back to nil so the record
    /// looks like a normal single-shot capture again.
    private func rewriteVoiceNoteMetadata(
        removing filename: String,
        in entry: SessionHistoryStore.VoiceNoteEntry
    ) -> Outcome {
        var note = entry.note
        let surviving = (note.chunks ?? []).filter { $0.filename != filename }
        guard !surviving.isEmpty else {
            try? SessionHistoryStore.delete(.voiceNote(entry), removing: removeItem)
            return .entryRemoved
        }
        let total = surviving.reduce(0) { $0 + $1.duration_seconds }
        let first = surviving[0]
        note.duration_seconds = total
        note.language = first.language
        note.transcript = first.transcript
        note.audio_file_url = entry.directory.appending(path: first.filename)
        note.chunks = surviving.count > 1 ? surviving : nil

        let metaURL = entry.directory.appending(path: "metadata.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(note) {
            try? writeMetadata(data, metaURL)
        }
        return .rowRemoved
    }

    /// Atomic write with the app-wide protection class; the seam for the
    /// protection-class test.
    nonisolated static func writeVoiceNoteMetadata(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: [.atomic, LocalStore.dataProtectionWriteOption])
    }

    nonisolated private static func purgeUploadQueueOrphans() {
        Task { _ = await SessionUploader.shared.purgeOrphans() }
    }
}
