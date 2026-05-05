import Foundation

// Resolves Application Support paths used across the app. Created lazily
// so the directory exists by the time it's first written.

public enum LocalStore {
    public static func appSupport() throws -> URL {
        let fm = FileManager.default
        let dir = try fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appending(path: "VoiceDiary", directoryHint: .isDirectory)
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try? (dir as NSURL).setResourceValue(
                URLFileProtection.complete,
                forKey: .fileProtectionKey
            )
        }
        return dir
    }

    public static func driveBySeedsDir() throws -> URL {
        let dir = try appSupport().appending(path: "driveby_seeds", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    public static func sessionsStagingDir() throws -> URL {
        let dir = try appSupport().appending(path: "sessions", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    public static func uploadQueueFile() throws -> URL {
        try appSupport().appending(path: "upload_queue.json")
    }

    /// Filename used for the per-session manifest snapshot inside each
    /// staged session directory. Read by the Verlauf list to render
    /// history rows without having to fall back on the upload queue.
    public static let manifestFilename = "manifest.json"

    public static func writeManifest(_ manifest: Manifest, to sessionDir: URL) throws {
        let url = sessionDir.appending(path: manifestFilename)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(manifest)
        try data.write(to: url, options: [.atomic, .completeFileProtection])
    }

    // MARK: - Surfaced drive-by seed index ---------------------------

    /// Filename for the JSON sidecar listing every seed_id that's been
    /// surfaced in a walkthrough session. Used to filter out seeds that
    /// have already been folded into a diary entry so the drive-by
    /// section never re-surfaces them.
    public static let surfacedSeedsFilename = "surfaced_seed_ids.json"

    private static func surfacedSeedsURL() throws -> URL {
        try appSupport().appending(path: surfacedSeedsFilename)
    }

    public static func surfacedSeedIDs() -> Set<String> {
        guard let url = try? surfacedSeedsURL(),
              let data = try? Data(contentsOf: url),
              let ids = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return Set(ids)
    }

    public static func markSeedsSurfaced(ids: [String]) {
        guard !ids.isEmpty else { return }
        var current = surfacedSeedIDs()
        current.formUnion(ids)
        guard let url = try? surfacedSeedsURL() else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(Array(current).sorted()) else { return }
        try? data.write(to: url, options: [.atomic, .completeFileProtection])
    }
}
