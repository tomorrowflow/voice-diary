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
        /// Machine-readable `code` of the most recent failed attempt
        /// (SPEC §10.6.1), e.g. `whisper_unavailable`. Nil before any
        /// failure, after a failure without a code (older server, network
        /// error) and for queue files written before this field existed.
        public var last_failure_code: String?

        public init(
            id: String,
            manifest: Manifest,
            audio_file_paths: [String: String],
            attempts: Int,
            next_attempt_at: Date,
            permanentlyFailed: Bool = false,
            last_failure_code: String? = nil
        ) {
            self.id = id
            self.manifest = manifest
            self.audio_file_paths = audio_file_paths
            self.attempts = attempts
            self.next_attempt_at = next_attempt_at
            self.permanentlyFailed = permanentlyFailed
            self.last_failure_code = last_failure_code
        }

        // Custom Decodable so queue files written before `permanentlyFailed`
        // or `last_failure_code` were added decode cleanly (the missing keys
        // default to false / nil).
        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            manifest = try c.decode(Manifest.self, forKey: .manifest)
            audio_file_paths = try c.decode([String: String].self, forKey: .audio_file_paths)
            attempts = try c.decode(Int.self, forKey: .attempts)
            next_attempt_at = try c.decode(Date.self, forKey: .next_attempt_at)
            permanentlyFailed = try c.decodeIfPresent(Bool.self, forKey: .permanentlyFailed) ?? false
            last_failure_code = try c.decodeIfPresent(String.self, forKey: .last_failure_code)
        }

        private enum CodingKeys: String, CodingKey {
            case id, manifest, audio_file_paths, attempts, next_attempt_at, permanentlyFailed
            case last_failure_code
        }

        public var nextBackoff: TimeInterval {
            // 1s, 2s, 4s, 8s, 30s, 60s, 600s max
            let curve: [TimeInterval] = [1, 2, 4, 8, 30, 60, 600]
            return curve[min(attempts, curve.count - 1)]
        }

        /// The entry after a failed attempt, as decided by `outcome`.
        /// Pure so the queue rules are testable without the network.
        /// Only the schedule, the permanent flag and the failure code
        /// change; the manifest and audio paths are never touched.
        func afterFailure(_ error: any Error, outcome: UploadOutcome, now: Date) -> QueueEntry {
            var updated = self
            updated.last_failure_code = UploadOutcome.failureCode(of: error)
            switch outcome {
            case .retry(let retryAfter):
                updated.attempts += 1
                // A longer `Retry-After` wins; a shorter one is ignored.
                updated.next_attempt_at = now.addingTimeInterval(max(updated.nextBackoff, retryAfter ?? 0))
            case .permanent:
                updated.permanentlyFailed = true
            case .uploaded, .paused:
                break
            }
            return updated
        }
    }

    private var queue: [QueueEntry] = []
    private var didLoad = false
    private var isFlushing = false
    /// Entries the server said not to retry on its own (`retryable: false`).
    /// Skipped by `flush()` until `kick()` (foreground or settings change)
    /// clears the set. In memory only: a relaunch is a foreground, and the
    /// persisted entry is already due, so it is tried again then.
    private var pausedIDs: Set<String> = []

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
    /// hops onto the actor for the actual flush. Also lifts the pause on
    /// `retryable: false` entries, so call it only for a foreground or a
    /// settings change.
    public nonisolated func kick() {
        Task {
            await self.resumePaused()
            await self.flush()
        }
    }

    private func resumePaused() {
        pausedIDs.removeAll()
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
                //   * everything else — see `UploadOutcome.classify`:
                //     already-ingested counts as success, permanent 4xx
                //     is marked failed-permanent so future flushes skip
                //     it, `retryable: false` pauses until the next kick,
                //     and the rest reschedule with exponential backoff
                //     (or the server's longer `Retry-After`).
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
                }
                let outcome = UploadOutcome.classify(error)
                switch outcome {
                case .uploaded:
                    queue.removeAll { $0.id == entry.id }
                    persist()
                    Log.upload.notice(
                        "upload.already_ingested sid=\(entry.id, privacy: .public)"
                    )
                case .permanent:
                    recordFailure(entry: entry, error: error, outcome: outcome)
                    Log.upload.error(
                        "upload.permanent_failure sid=\(entry.id, privacy: .public) err=\(String(describing: error), privacy: .public)"
                    )
                case .paused:
                    recordFailure(entry: entry, error: error, outcome: outcome)
                    pausedIDs.insert(entry.id)
                    Log.upload.warning(
                        "upload.paused sid=\(entry.id, privacy: .public) — not retryable; waiting for foreground or settings change err=\(String(describing: error), privacy: .public)"
                    )
                case .retry:
                    if let updated = recordFailure(entry: entry, error: error, outcome: outcome) {
                        let wait = Int(updated.next_attempt_at.timeIntervalSinceNow)
                        Log.upload.warning(
                            "reschedule \(entry.id, privacy: .public) attempt=\(updated.attempts) wait=\(wait)s err=\(String(describing: error), privacy: .public)"
                        )
                    }
                }
                // Continue the loop so subsequent due entries are tried.
                continue
            }
        }
    }

    /// Apply `outcome` to the queued entry and persist it. The audio files
    /// are never touched, whatever the outcome.
    @discardableResult
    private func recordFailure(entry: QueueEntry, error: any Error, outcome: UploadOutcome) -> QueueEntry? {
        guard let idx = queue.firstIndex(where: { $0.id == entry.id }) else { return nil }
        let updated = queue[idx].afterFailure(error, outcome: outcome, now: Date())
        queue[idx] = updated
        persist()
        return updated
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
        return queue.first {
            !$0.permanentlyFailed && !pausedIDs.contains($0.id) && $0.next_attempt_at <= now
        }
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

/// How a failed upload attempt should be treated by the queue.
enum UploadOutcome: Equatable {
    /// The server already holds the session — drop the entry like a 2xx.
    case uploaded
    /// The server will never accept this payload; keep for diagnostics.
    case permanent
    /// The server said retrying cannot succeed without a change
    /// (`retryable: false`). Not marked permanent: the entry waits until
    /// the next foreground or settings change, then is tried again.
    case paused
    /// Transient or fixable (5xx, network, auth, 408, 429); back off, and
    /// wait at least `after` seconds when the server sent `Retry-After`.
    case retry(after: TimeInterval?)

    /// HTTP 409 from `POST /api/sessions` means the session was already
    /// ingested (the original 2xx was lost in transit), so it is success.
    /// 400, 404, 422 are permanent. Auth errors (401, 403) and
    /// rate-limiting / timeout (408, 429) are NOT permanent — they may
    /// succeed once the server is accessible or credentials are refreshed;
    /// only an explicit `retryable: false` pauses them.
    static func classify(_ error: any Error) -> UploadOutcome {
        guard case ServerClientError.http(let status, _, let failure) = error else {
            return .retry(after: nil)
        }
        switch status {
        case 409: return .uploaded
        case 400, 404, 422: return .permanent
        default: return failure.retryable == false ? .paused : .retry(after: failure.retryAfter)
        }
    }

    /// The contract `code` of a failed attempt, if the server sent one.
    static func failureCode(of error: any Error) -> String? {
        guard case ServerClientError.http(_, _, let failure) = error else { return nil }
        return failure.code
    }
}
