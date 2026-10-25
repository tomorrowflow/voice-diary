import Foundation
import Testing
@testable import VoiceDiary

@Suite("StorageUsageSummary")
struct StorageUsageSummaryTests {

    private func stats(_ label: String, _ count: Int, _ bytes: Int64) -> SessionHistoryStore.CategoryStats {
        SessionHistoryStore.CategoryStats(label: label, count: count, totalBytes: bytes)
    }

    private func snapshot(
        sessions: (Int, Int64) = (0, 0),
        notes: (Int, Int64) = (0, 0),
        queue: (Int, Int64) = (0, 0),
        stale: (Int, Int64) = (0, 0)
    ) -> SessionHistoryStore.StorageSnapshot {
        SessionHistoryStore.StorageSnapshot(
            walkthroughs: stats("walkthroughs", sessions.0, sessions.1),
            voiceNotes: stats("voiceNotes", notes.0, notes.1),
            queueBytes: queue.1,
            queueCount: queue.0,
            olderThanCutoff: stats("olderThanCutoff", stale.0, stale.1)
        )
    }

    @Test("nil snapshot reads as zero everywhere")
    func nilSnapshotDefaults() {
        let summary = StorageUsageSummary(snapshot: nil)
        #expect(summary.sessions == .zero)
        #expect(summary.notes == .zero)
        #expect(summary.queue == .zero)
        #expect(summary.totalBytes == 0)
    }

    @Test("empty categories read as zero")
    func emptyCategories() {
        let summary = StorageUsageSummary(snapshot: snapshot())
        #expect(summary.sessions == .zero)
        #expect(summary.notes == .zero)
        #expect(summary.queue == .zero)
        #expect(summary.totalBytes == 0)
    }

    @Test("each category keeps its own count and bytes")
    func distinctSentinelsPerCategory() {
        let summary = StorageUsageSummary(snapshot: snapshot(
            sessions: (3, 3_000),
            notes: (5, 50_000),
            queue: (7, 700_000),
            stale: (11, 11_000_000)
        ))
        #expect(summary.sessions == StorageUsageSummary.Usage(count: 3, bytes: 3_000))
        #expect(summary.notes == StorageUsageSummary.Usage(count: 5, bytes: 50_000))
        #expect(summary.queue == StorageUsageSummary.Usage(count: 7, bytes: 700_000))
    }

    @Test("total is the snapshot's own total, not recomputed")
    func totalComesFromSnapshot() {
        let snap = snapshot(sessions: (1, 100), notes: (2, 20), queue: (3, 3))
        #expect(StorageUsageSummary(snapshot: snap).totalBytes == snap.totalBytes)
        #expect(snap.totalBytes == 123)
    }

    @Test("scalar init keeps a supplied total that differs from the category sum")
    func suppliedTotalIsUnchanged() {
        let summary = StorageUsageSummary(
            sessionCount: 1, sessionBytes: 10,
            noteCount: 2, noteBytes: 20,
            queueCount: 3, queueBytes: 30,
            totalBytes: 999
        )
        #expect(summary.totalBytes == 999)
        #expect(summary.sessions == StorageUsageSummary.Usage(count: 1, bytes: 10))
        #expect(summary.notes == StorageUsageSummary.Usage(count: 2, bytes: 20))
        #expect(summary.queue == StorageUsageSummary.Usage(count: 3, bytes: 30))
    }

    @Test("byte values above the Int32 range survive")
    func largeByteValues() {
        let big = Int64(Int32.max) + 1
        let summary = StorageUsageSummary(snapshot: snapshot(
            sessions: (1, big),
            notes: (1, big * 2),
            queue: (1, big * 3)
        ))
        #expect(summary.sessions.bytes == big)
        #expect(summary.notes.bytes == big * 2)
        #expect(summary.queue.bytes == big * 3)
        #expect(summary.totalBytes == big * 6)
    }
}
