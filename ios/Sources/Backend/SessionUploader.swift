import Foundation

// Persistent FIFO upload queue with exponential backoff. Survives app
// restart by serialising itself to `upload_queue.json` in Application
// Support. Each entry references the staged session bundle on disk;
// `flush()` walks the queue, uploads each, removes it on success, and
// reschedules with backoff on failure.

public actor SessionUploader {
    public static let shared = SessionUploader()

    public struct QueueEntry: Codable, Sendable, Identifiable {
        public var id: String                    // session_id
        public var manifest: Manifest
        public var audio_file_paths: [String: String]  // multipart name → absolute path
        public var attempts: Int
        public var next_attempt_at: Date

        public var nextBackoff: TimeInterval {
            // 1s, 2s, 4s, 8s, 30s, 60s, 600s max
            let curve: [TimeInterval] = [1, 2, 4, 8, 30, 60, 600]
            return curve[min(attempts, curve.count - 1)]
        }
    }

    private var queue: [QueueEntry] = []
    private var isFlushing = false

    public init() {
        Task { await loadFromDisk() }
    }

    // --- public API ----------------------------------------------------

    public func enqueue(
        manifest: Manifest,
        audioFiles: [String: URL]
    ) async {
        let pathStrings = audioFiles.mapValues { $0.path }
        let entry = QueueEntry(
            id: manifest.session_id,
            manifest: manifest,
            audio_file_paths: pathStrings,
            attempts: 0,
            next_attempt_at: Date()
        )
        queue.removeAll { $0.id == entry.id }
        queue.append(entry)
        persist()
        Task { await flush() }
    }

    public func pending() -> [QueueEntry] { queue }

    public func flush() async {
        if isFlushing { return }
        isFlushing = true
        defer { isFlushing = false }

        while let entry = nextDue() {
            do {
                _ = try await ServerClient.shared.uploadSession(
                    manifest: entry.manifest,
                    audioFiles: entry.audio_file_paths.mapValues { URL(fileURLWithPath: $0) }
                )
                queue.removeAll { $0.id == entry.id }
                persist()
            } catch {
                rescheduleAfterFailure(entry: entry, error: error)
                return  // give up the loop until the next trigger
            }
        }
    }

    // --- queue mechanics ----------------------------------------------

    private func nextDue() -> QueueEntry? {
        let now = Date()
        for entry in queue where entry.next_attempt_at <= now {
            return entry
        }
        return nil
    }

    private func rescheduleAfterFailure(entry: QueueEntry, error: Error) {
        guard let idx = queue.firstIndex(where: { $0.id == entry.id }) else { return }
        var updated = queue[idx]
        updated.attempts += 1
        updated.next_attempt_at = Date().addingTimeInterval(updated.nextBackoff)
        queue[idx] = updated
        persist()
        print("upload_queue: reschedule \(entry.id) attempt=\(updated.attempts) " +
              "wait=\(Int(updated.nextBackoff))s err=\(error)")
    }

    // --- persistence --------------------------------------------------

    private func persist() {
        do {
            let url = try LocalStore.uploadQueueFile()
            let data = try JSONEncoder().encode(queue)
            try data.write(to: url, options: [.atomic])
        } catch {
            print("upload_queue: persist failed: \(error)")
        }
    }

    private func loadFromDisk() async {
        do {
            let url = try LocalStore.uploadQueueFile()
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            let data = try Data(contentsOf: url)
            queue = try JSONDecoder().decode([QueueEntry].self, from: data)
        } catch {
            print("upload_queue: load failed: \(error)")
            queue = []
        }
    }
}
