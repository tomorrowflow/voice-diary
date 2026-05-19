import Foundation

/// Read-only enumerator over the user's local session history.
///
/// Two sources, both already populated by the existing pipeline:
///   * walkthrough sessions — `Application Support/VoiceDiary/sessions/{id}/`
///     containing `manifest.json` (snapshot persisted by
///     `WalkthroughCoordinator.finishUpload`) plus per-segment `.m4a` files
///     under `segments/`.
///   * drive-by seeds — `Application Support/VoiceDiary/driveby_seeds/{iso}/`
///     containing `audio.m4a` + `metadata.json` written by
///     `CaptureCoordinator.stop`.
///
/// The store NEVER deletes, edits, or re-uploads — Verlauf is purely a
/// read surface. Mutations go through the existing coordinators.
public enum SessionHistoryStore {

    public enum Item: Identifiable, Sendable {
        case walkthrough(WalkthroughEntry)
        case driveBy(DriveByEntry)

        public var id: String {
            switch self {
            case .walkthrough(let w): return "wt:" + w.sessionID
            case .driveBy(let d):     return "db:" + d.seed.id
            }
        }

        /// Sort key — the moment the session was *captured*, not when
        /// the user reviewed it.
        public var sortDate: Date {
            switch self {
            case .walkthrough(let w): return w.capturedAt
            case .driveBy(let d):     return d.seed.captured_at
            }
        }
    }

    public struct WalkthroughEntry: Sendable {
        public let sessionID: String
        public let date: String
        public let capturedAt: Date
        public let manifest: Manifest?    // nil if snapshot was missing
        public let segmentURLs: [URL]     // ordered s01.m4a, s02.m4a, …
        public let directory: URL

        /// Sum of per-segment sizes — coarse but cheap; an exact
        /// duration would require AVAsset probes per file.
        public var totalBytes: Int64 {
            segmentURLs.reduce(0) { sum, url in
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                return sum + Int64(size)
            }
        }

        public var eventCount: Int {
            manifest?.segments.filter {
                if case .calendarEvent = $0 { return true } else { return false }
            }.count ?? max(segmentURLs.count - 1, 0)  // -1 for closing
        }

        /// The day the diary entry is *for* (manifest.date, "yyyy-MM-dd").
        /// Distinct from `capturedAt` which is when the recording happened —
        /// a session captured today *for* yesterday will have these differ.
        /// Falls back to `capturedAt` if the manifest is missing or the
        /// date string fails to parse.
        public var diaryDate: Date {
            if let str = manifest?.date,
               let parsed = Self.isoDayParser.date(from: str) {
                return parsed
            }
            return capturedAt
        }

        private static let isoDayParser: DateFormatter = {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy-MM-dd"
            return f
        }()
    }

    public struct DriveByEntry: Sendable {
        public let seed: DriveBySeed
        public let directory: URL
    }

    /// Build the unified history list, newest first. Cheap enough to
    /// run on every appear (a handful of directory reads, no audio decode).
    public static func load() -> [Item] {
        var items: [Item] = []
        items.append(contentsOf: loadWalkthroughs().map(Item.walkthrough))
        items.append(contentsOf: loadDriveBys().map(Item.driveBy))
        return items.sorted { $0.sortDate > $1.sortDate }
    }

    /// Drive-by seeds captured before `cutoff` (typically end-of-day for the
    /// walkthrough's target date) that haven't been surfaced in a prior
    /// session. Sorted oldest-first so the closing TTS lists them in the
    /// order they were captured.
    public static func unsurfacedDriveBys(
        before cutoff: Date,
        surfaced: Set<String>
    ) -> [DriveBySeed] {
        loadDriveBys()
            .map(\.seed)
            .filter { $0.captured_at < cutoff && !surfaced.contains($0.seed_id) }
            .sorted { $0.captured_at < $1.captured_at }
    }

    /// Permanently remove a session's on-disk artifacts. Walkthrough:
    /// the entire `sessions/{slug}/` directory (manifest + all
    /// segments). Drive-by: the entire `driveby_seeds/{ts}/` directory
    /// (audio + metadata). The matching upload-queue entry is purged
    /// in a follow-up since the queue actor lives elsewhere.
    public static func delete(_ item: Item) throws {
        let url: URL
        switch item {
        case .walkthrough(let w): url = w.directory
        case .driveBy(let d):     url = d.directory
        }
        try FileManager.default.removeItem(at: url)
    }

    // MARK: - Walkthrough enumeration

    private static func loadWalkthroughs() -> [WalkthroughEntry] {
        guard let root = try? LocalStore.sessionsStagingDir(),
              let names = try? FileManager.default.contentsOfDirectory(atPath: root.path)
        else { return [] }

        return names.compactMap { name -> WalkthroughEntry? in
            let dir = root.appending(path: name, directoryHint: .isDirectory)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir),
                  isDir.boolValue else { return nil }

            // Manifest snapshot is optional — older sessions predate it.
            let manifestURL = dir.appending(path: LocalStore.manifestFilename)
            let manifest: Manifest? = (try? Data(contentsOf: manifestURL))
                .flatMap { try? JSONDecoder().decode(Manifest.self, from: $0) }

            // Always enumerate the segments dir directly — works with or
            // without the manifest.
            let segmentsDir = dir.appending(path: "segments", directoryHint: .isDirectory)
            let segmentURLs = (try? FileManager.default.contentsOfDirectory(
                at: segmentsDir,
                includingPropertiesForKeys: [.fileSizeKey],
                options: [.skipsHiddenFiles]
            ))?
                .filter { $0.pathExtension.lowercased() == "m4a" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []

            // Skip empty session dirs (interrupted before any segment).
            guard !segmentURLs.isEmpty else { return nil }

            // captured-at: prefer the session_id (ISO timestamp) when we
            // have it; fall back to directory creation date.
            let capturedAt: Date = {
                if let manifest, let d = ISO8601DateFormatter().date(from: manifest.session_id) {
                    return d
                }
                if let d = ISO8601DateFormatter().date(from: name.replacingOccurrences(of: "_", with: "+")) {
                    return d
                }
                return (try? dir.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            }()

            return WalkthroughEntry(
                sessionID: manifest?.session_id ?? name,
                date: manifest?.date ?? Self.shortDateFormatter.string(from: capturedAt),
                capturedAt: capturedAt,
                manifest: manifest,
                segmentURLs: segmentURLs,
                directory: dir
            )
        }
    }

    // MARK: - Drive-by enumeration

    /// Public so the Verlauf detail screen can join a walkthrough's
    /// `manifest.drive_by_seeds_surfaced` against the on-disk seed
    /// directories without round-tripping through `load()`.
    public static func loadDriveBys() -> [DriveByEntry] {
        guard let root = try? LocalStore.driveBySeedsDir(),
              let names = try? FileManager.default.contentsOfDirectory(atPath: root.path)
        else { return [] }

        let decoder: JSONDecoder = {
            let d = JSONDecoder()
            d.dateDecodingStrategy = .iso8601
            return d
        }()

        return names.compactMap { name -> DriveByEntry? in
            let dir = root.appending(path: name, directoryHint: .isDirectory)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir),
                  isDir.boolValue else { return nil }

            let metaURL = dir.appending(path: "metadata.json")
            guard let data = try? Data(contentsOf: metaURL),
                  let seed = try? decoder.decode(DriveBySeed.self, from: data)
            else { return nil }

            return DriveByEntry(seed: seed, directory: dir)
        }
    }

    private static let shortDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    // MARK: - Storage stats (Danger Zone)

    /// Aggregate disk usage for one category of locally-stored audio.
    public struct CategoryStats: Sendable {
        public let label: String
        public let count: Int
        public let totalBytes: Int64
    }

    /// Pre-computed numbers for `DangerZoneView` so it can render the
    /// volume card and the "X items / Y MB will be removed" hint
    /// without scanning the file system on every redraw.
    public struct StorageSnapshot: Sendable {
        public let walkthroughs: CategoryStats
        public let driveBys: CategoryStats
        public let queueBytes: Int64
        public let queueCount: Int

        /// Sessions + seeds older than `cutoff`. Used to drive the
        /// "Älter als 30 Tage entfernen" button label so the user knows
        /// in advance how much will be removed.
        public let olderThanCutoff: CategoryStats

        public var totalBytes: Int64 {
            walkthroughs.totalBytes + driveBys.totalBytes + queueBytes
        }
    }

    /// Walk both audio directories + the upload-queue file and return
    /// total sizes / counts. Bytes are measured with `URLResourceKey
    /// .totalFileAllocatedSizeKey` so the numbers match what iOS
    /// Settings → Storage reports.
    public static func storageSnapshot(olderThan cutoff: Date) -> StorageSnapshot {
        let walkthroughs = scanWalkthroughs()
        let driveBys = scanDriveBys()
        let (queueCount, queueBytes) = scanUploadQueue()

        // "Older than cutoff" = sessions + seeds whose capture date is
        // before the cutoff. Queue entries are intentionally excluded —
        // they're still active uploads and shouldn't be wiped from
        // under the uploader actor.
        var staleCount = 0
        var staleBytes: Int64 = 0
        for w in loadWalkthroughs() where w.capturedAt < cutoff {
            staleCount += 1
            staleBytes += directorySize(at: w.directory)
        }
        for d in loadDriveBys() where d.seed.captured_at < cutoff {
            staleCount += 1
            staleBytes += directorySize(at: d.directory)
        }

        return StorageSnapshot(
            walkthroughs: walkthroughs,
            driveBys: driveBys,
            queueBytes: queueBytes,
            queueCount: queueCount,
            olderThanCutoff: CategoryStats(
                label: "olderThanCutoff",
                count: staleCount,
                totalBytes: staleBytes
            )
        )
    }

    /// Remove every locally-stored audio session, seed, the
    /// surfaced-seed index, and the upload-queue JSON. The Danger Zone
    /// caller is expected to call `SessionUploader.clear()` immediately
    /// before this so the actor's in-memory queue doesn't get
    /// re-persisted after we unlink the file. Returns bytes freed.
    @discardableResult
    public static func deleteAllLocalAudio() -> Int64 {
        var freed: Int64 = 0
        if let root = try? LocalStore.sessionsStagingDir() {
            freed += directorySize(at: root)
            try? FileManager.default.removeItem(at: root)
        }
        if let root = try? LocalStore.driveBySeedsDir() {
            freed += directorySize(at: root)
            try? FileManager.default.removeItem(at: root)
        }
        if let app = try? LocalStore.appSupport() {
            let surfaced = app.appending(path: LocalStore.surfacedSeedsFilename)
            try? FileManager.default.removeItem(at: surfaced)
        }
        if let queue = try? LocalStore.uploadQueueFile() {
            freed += fileSize(at: queue)
            try? FileManager.default.removeItem(at: queue)
        }
        return freed
    }

    /// Remove sessions + seeds older than `cutoff`. Queued sessions are
    /// skipped — deleting their audio would orphan the upload entry.
    /// Returns the number of bytes freed.
    @discardableResult
    public static func deleteOlderThan(
        _ cutoff: Date,
        queuedSessionIDs: Set<String>
    ) -> Int64 {
        var freed: Int64 = 0
        for w in loadWalkthroughs() where w.capturedAt < cutoff {
            if queuedSessionIDs.contains(w.sessionID) { continue }
            freed += directorySize(at: w.directory)
            try? FileManager.default.removeItem(at: w.directory)
        }
        for d in loadDriveBys() where d.seed.captured_at < cutoff {
            freed += directorySize(at: d.directory)
            try? FileManager.default.removeItem(at: d.directory)
        }
        return freed
    }

    // MARK: - Scan helpers

    private static func scanWalkthroughs() -> CategoryStats {
        let entries = loadWalkthroughs()
        let bytes = entries.reduce(Int64(0)) { $0 + directorySize(at: $1.directory) }
        return CategoryStats(label: "walkthroughs", count: entries.count, totalBytes: bytes)
    }

    private static func scanDriveBys() -> CategoryStats {
        let entries = loadDriveBys()
        let bytes = entries.reduce(Int64(0)) { $0 + directorySize(at: $1.directory) }
        return CategoryStats(label: "driveBys", count: entries.count, totalBytes: bytes)
    }

    private static func scanUploadQueue() -> (count: Int, bytes: Int64) {
        guard let url = try? LocalStore.uploadQueueFile(),
              FileManager.default.fileExists(atPath: url.path)
        else { return (0, 0) }
        let bytes = fileSize(at: url)
        // The queue is a single JSON file — count the entries inside
        // so the stat card reads "Upload-Queue · 2 Einträge · 1,4 KB"
        // instead of just "1,4 KB".
        guard let data = try? Data(contentsOf: url),
              let entries = try? JSONDecoder().decode([SessionUploader.QueueEntry].self, from: data)
        else { return (0, bytes) }
        return (entries.count, bytes)
    }

    private static func fileSize(at url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .fileSizeKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return 0 }
        let allocated = values.totalFileAllocatedSize.map(Int64.init) ?? 0
        let logical = values.fileSize.map(Int64.init) ?? 0
        return allocated > 0 ? allocated : logical
    }

    private static func directorySize(at url: URL) -> Int64 {
        var total: Int64 = 0
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        for case let fileURL as URL in enumerator {
            total += fileSize(at: fileURL)
        }
        return total
    }
}
