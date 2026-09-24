import Foundation
import os

// Persistent FIFO upload queue with exponential backoff. Survives app
// restart by serialising itself to `upload_queue.json` in Application
// Support. Each entry references the staged session bundle on disk;
// `flush()` walks the queue, uploads each, removes it on success, and
// reschedules with backoff on failure.

public actor SessionUploader {
    public static let shared = SessionUploader()

    public struct QueueEntry: Codable, Sendable, Identifiable {
        public var id: String                                // session_id
        public var manifest: Manifest
        // Paths are stored relative to the Application Support directory
        // so the queue survives app reinstalls (iOS rotates the sandbox
        // container UUID). Absolute paths are kept only as a fallback for
        // anything that landed outside Application Support.
        public var audio_file_paths: [String: String]
        public var attempts: Int
        public var next_attempt_at: Date
        /// Permanently failed entries are kept for diagnostics but
        /// skipped by `flush()`. They can be cleared via `clear()`.
        public var permanentlyFailed: Bool

        public init(
            id: String,
            manifest: Manifest,
            audio_file_paths: [String: String],
            attempts: Int,
            next_attempt_at: Date,
            permanentlyFailed: Bool = false
        ) {
            self.id = id
            self.manifest = manifest
            self.audio_file_paths = audio_file_paths
            self.attempts = attempts
            self.next_attempt_at = next_attempt_at
            self.permanentlyFailed = permanentlyFailed
        }

        // Custom Decodable so queue files written before `permanentlyFailed`
        // was added decode cleanly (the missing key defaults to false).
        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            manifest = try c.decode(Manifest.self, forKey: .manifest)
            audio_file_paths = try c.decode([String: String].self, forKey: .audio_file_paths)
            attempts = try c.decode(Int.self, forKey: .attempts)
            next_attempt_at = try c.decode(Date.self, forKey: .next_attempt_at)
            permanentlyFailed = try c.decodeIfPresent(Bool.self, forKey: .permanentlyFailed) ?? false
        }

        private enum CodingKeys: String, CodingKey {
            case id, manifest, audio_file_paths, attempts, next_attempt_at, permanentlyFailed
        }

        public var nextBackoff: TimeInterval {
            // 1s, 2s, 4s, 8s, 30s, 60s, 600s max
            let curve: [TimeInterval] = [1, 2, 4, 8, 30, 60, 600]
            return curve[min(attempts, curve.count - 1)]
        }
    }

    private var queue: [QueueEntry] = []
    private var didLoad = false
    private var isFlushing = false

    public init() {}

    // --- public API ----------------------------------------------------

    public func enqueue(
        manifest: Manifest,
        audioFiles: [String: URL]
    ) async {
        await ensureLoaded()
        let pathStrings = audioFiles.mapValues { Self.storedPath(for: $0) }
        let entry = QueueEntry(
            id: manifest.session_id,
            manifest: manifest,
            audio_file_paths: pathStrings,
            attempts: 0,
            next_attempt_at: Date(),
            permanentlyFailed: false
        )
        queue.removeAll { $0.id == entry.id }
        queue.append(entry)
        persist()
        Log.upload.notice(
            "upload.enqueue sid=\(entry.id, privacy: .public) files=\(audioFiles.count, privacy: .public)"
        )
        Task { await flush() }
    }

    /// Kick the upload queue from outside the actor — e.g. from
    /// `VoiceDiaryApp` on launch and on `scenePhase == .active`.
    /// `nonisolated` so call sites don't need `await`; the spawned Task
    /// hops onto the actor for the actual flush.
    public nonisolated func kick() {
        Task { await self.flush() }
    }

    public func clear() async {
        await ensureLoaded()
        queue.removeAll()
        persist()
        Log.upload.info("queue cleared")
    }

    /// How many entries are dropped because their on-disk audio is gone.
    /// Mostly diagnostic for the debug UI.
    @discardableResult
    public func purgeOrphans() async -> Int {
        await ensureLoaded()
        let before = queue.count
        queue.removeAll { entry in
            entry.audio_file_paths.values.contains { rel in
                !FileManager.default.fileExists(atPath: Self.resolved(rel).path)
            }
        }
        let removed = before - queue.count
        if removed > 0 {
            persist()
            Log.upload.warning("purged \(removed) orphaned queue entries")
        }
        return removed
    }

    public func pending() async -> [QueueEntry] {
        await ensureLoaded()
        return queue
    }

    public func flush() async {
        await ensureLoaded()
        if isFlushing { return }
        isFlushing = true
        defer { isFlushing = false }

        while let entry = nextDue() {
            // Drop orphaned entries up-front rather than burning retries.
            let resolved = entry.audio_file_paths.mapValues { Self.resolved($0) }
            let missing = resolved.filter { !FileManager.default.fileExists(atPath: $0.value.path) }
            if !missing.isEmpty {
                Log.upload.warning(
                    "drop orphaned entry \(entry.id, privacy: .public) — missing files: \(missing.keys.joined(separator: ", "), privacy: .public)"
                )
                queue.removeAll { $0.id == entry.id }
                persist()
                continue
            }
            Log.upload.notice(
                "upload.start sid=\(entry.id, privacy: .public) attempt=\(entry.attempts, privacy: .public)"
            )
            let started = Date()
            do {
                _ = try await ServerClient.shared.uploadSession(
                    manifest: entry.manifest,
                    audioFiles: resolved
                )
                queue.removeAll { $0.id == entry.id }
                persist()
                let elapsed = Int(Date().timeIntervalSince(started) * 1000)
                Log.upload.notice(
                    "upload.success sid=\(entry.id, privacy: .public) ms=\(elapsed, privacy: .public)"
                )
            } catch {
                let elapsed = Int(Date().timeIntervalSince(started) * 1000)
                Log.upload.warning(
                    "upload.failure sid=\(entry.id, privacy: .public) ms=\(elapsed, privacy: .public) err=\(String(describing: error), privacy: .public)"
                )
                // Classify the error:
                //   * notConfigured — no URL/token yet; skip but don't
                //     increment the attempt counter so the entry retries
                //     immediately once the server is configured.
                //   * permanent 4xx (400/404/409/422) — the server will
                //     never accept this payload; mark failed-permanent so
                //     future flushes skip it instead of looping forever.
                //   * everything else (5xx, network, timeout, auth) —
                //     reschedule with exponential backoff as before.
                // After classifying, `continue` to the next due entry
                // rather than returning — one bad entry must not block
                // the rest of the queue.
                if case ServerClientError.notConfigured = error {
                    Log.upload.notice(
                        "upload.skipped — not configured; stopping flush until configured"
                    )
                    // Every entry will fail the same way — no point
                    // continuing the loop. Break so we don't spin.
                    break
                } else if isPermanentClientError(error) {
                    markPermanentFailure(entry: entry, error: error)
                } else {
                    rescheduleAfterFailure(entry: entry, error: error)
                }
                // Continue the loop so subsequent due entries are tried.
                continue
            }
        }
    }

    /// Returns true for non-retryable client errors: HTTP 400, 404, 409,
    /// 422. Auth errors (401, 403) and rate-limiting / timeout (408, 429)
    /// are NOT permanent — they may succeed once the server is accessible
    /// or credentials are refreshed.
    private func isPermanentClientError(_ error: any Error) -> Bool {
        guard case ServerClientError.http(let status, _) = error else {
            return false
        }
        return [400, 404, 409, 422].contains(status)
    }

    private func markPermanentFailure(entry: QueueEntry, error: any Error) {
        guard let idx = queue.firstIndex(where: { $0.id == entry.id }) else { return }
        var updated = queue[idx]
        updated.permanentlyFailed = true
        queue[idx] = updated
        persist()
        Log.upload.error(
            "upload.permanent_failure sid=\(entry.id, privacy: .public) err=\(String(describing: error), privacy: .public)"
        )
    }

    // --- path persistence helpers ------------------------------------

    /// Convert a URL to the form we store. Paths inside Application Support
    /// become `~AppSupport/...`; everything else is kept absolute.
    private static func storedPath(for url: URL) -> String {
        let abs = url.standardizedFileURL.path
        if let support = try? LocalStore.appSupport() {
            let prefix = support.standardizedFileURL.path
            if abs.hasPrefix(prefix + "/") {
                return "~AppSupport" + abs.dropFirst(prefix.count)
            }
        }
        return abs
    }

    /// Inverse of `storedPath`. Re-resolves the marker against the current
    /// Application Support directory so reinstalls don't break the queue.
    private static func resolved(_ stored: String) -> URL {
        if stored.hasPrefix("~AppSupport") {
            let suffix = String(stored.dropFirst("~AppSupport".count))
            if let support = try? LocalStore.appSupport() {
                return URL(fileURLWithPath: support.path + suffix)
            }
        }
        return URL(fileURLWithPath: stored)
    }

    // --- queue mechanics ----------------------------------------------

    private func nextDue() -> QueueEntry? {
        let now = Date()
        for entry in queue where !entry.permanentlyFailed && entry.next_attempt_at <= now {
            return entry
        }
        return nil
    }

    private func rescheduleAfterFailure(entry: QueueEntry, error: any Error) {
        guard let idx = queue.firstIndex(where: { $0.id == entry.id }) else { return }
        var updated = queue[idx]
        updated.attempts += 1
        updated.next_attempt_at = Date().addingTimeInterval(updated.nextBackoff)
        queue[idx] = updated
        persist()
        Log.upload.warning(
            "reschedule \(entry.id, privacy: .public) attempt=\(updated.attempts) wait=\(Int(updated.nextBackoff))s err=\(String(describing: error), privacy: .public)"
        )
    }

    // --- persistence --------------------------------------------------

    private func persist() {
        do {
            let url = try LocalStore.uploadQueueFile()
            let data = try JSONEncoder().encode(queue)
            try data.write(to: url, options: [.atomic])
        } catch {
            Log.upload.error("persist failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func ensureLoaded() async {
        if didLoad { return }
        defer { didLoad = true }
        do {
            let url = try LocalStore.uploadQueueFile()
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            let data = try Data(contentsOf: url)
            queue = try JSONDecoder().decode([QueueEntry].self, from: data)
        } catch {
            Log.upload.error("load failed: \(String(describing: error), privacy: .public)")
            queue = []
        }
    }
}
