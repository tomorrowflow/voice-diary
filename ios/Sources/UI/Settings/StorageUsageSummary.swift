import Foundation

/// Read-only projection of `SessionHistoryStore.StorageSnapshot` onto the
/// three storage rows and the total row of `DangerZoneView`. Pure: it
/// never scans disk and never decides what gets deleted. A missing
/// snapshot (screen not scanned yet) reads as zero everywhere.
struct StorageUsageSummary: Equatable, Sendable {

    struct Usage: Equatable, Sendable {
        let count: Int
        let bytes: Int64

        static let zero = Usage(count: 0, bytes: 0)
    }

    let sessions: Usage
    let notes: Usage
    let queue: Usage
    /// Taken as supplied — never re-summed from the categories.
    let totalBytes: Int64

    init(
        sessionCount: Int, sessionBytes: Int64,
        noteCount: Int, noteBytes: Int64,
        queueCount: Int, queueBytes: Int64,
        totalBytes: Int64
    ) {
        self.sessions = Usage(count: sessionCount, bytes: sessionBytes)
        self.notes = Usage(count: noteCount, bytes: noteBytes)
        self.queue = Usage(count: queueCount, bytes: queueBytes)
        self.totalBytes = totalBytes
    }

    init(snapshot: SessionHistoryStore.StorageSnapshot?) {
        guard let snapshot else {
            self.init(
                sessionCount: 0, sessionBytes: 0,
                noteCount: 0, noteBytes: 0,
                queueCount: 0, queueBytes: 0,
                totalBytes: 0
            )
            return
        }
        self.init(
            sessionCount: snapshot.walkthroughs.count,
            sessionBytes: snapshot.walkthroughs.totalBytes,
            noteCount: snapshot.voiceNotes.count,
            noteBytes: snapshot.voiceNotes.totalBytes,
            queueCount: snapshot.queueCount,
            queueBytes: snapshot.queueBytes,
            totalBytes: snapshot.totalBytes
        )
    }
}
