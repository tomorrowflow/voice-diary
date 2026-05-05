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

    private static func loadDriveBys() -> [DriveByEntry] {
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
}
