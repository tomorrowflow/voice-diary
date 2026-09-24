import Foundation

// Resolves Application Support paths used across the app. Created lazily
// so the directory exists by the time it's first written.

public enum LocalStore {

    /// File protection class applied to every file the app creates.
    /// `completeUntilFirstUserAuthentication` keeps files encrypted at
    /// rest but accessible once the user has unlocked the device since
    /// boot — which is what background-audio capture needs. The
    /// stronger `complete` class makes files unreadable any time the
    /// screen is locked, which broke background recording: writes
    /// failed with -40 and re-opens with -54 (kAudioFilePermissionsError)
    /// the moment the user pocketed the phone mid-walkthrough.
    public static let protectionClass: URLFileProtection = .completeUntilFirstUserAuthentication

    /// `Data.write(to:options:)` equivalent of `protectionClass` — keep
    /// the two in sync so JSON sidecars get the same treatment as the
    /// audio files they describe.
    public static let dataProtectionWriteOption: Data.WritingOptions =
        .completeFileProtectionUntilFirstUserAuthentication

    /// Tag a directory or file with the app-wide protection class so
    /// children created via APIs that respect the parent's hint inherit
    /// the same class, and so the file itself is reachable while the
    /// device is locked. Best-effort — protection is a hint, never an
    /// error path.
    public static func applyProtection(to url: URL) {
        try? (url as NSURL).setResourceValue(
            protectionClass,
            forKey: .fileProtectionKey
        )
    }

    /// Read the current `URLFileProtection` resource value of `url`, or
    /// `nil` when it can't be queried (URL doesn't exist, key not set,
    /// volume doesn't support per-file protection). Used by the audio
    /// pipeline's `-54` diagnostic so we can see at fault time whether
    /// a parent directory or stale temp file is still tagged with the
    /// old `.complete` class.
    public static func currentProtection(of url: URL) -> URLFileProtection? {
        do {
            let values = try url.resourceValues(forKeys: [.fileProtectionKey])
            return values.fileProtection
        } catch {
            return nil
        }
    }

    /// One-time migration that walks every file and directory under the
    /// app's Application Support root and re-applies the current
    /// `protectionClass` to each node. Idempotent — running it on every
    /// launch is cheap (a few hundred items, each `setResourceValue`
    /// call is microseconds). Returns the number of nodes touched.
    ///
    /// **Why this exists:** the protection class for audio paths used
    /// to be `URLFileProtection.complete`. CoreAudio's `ExtAudioFile`
    /// path returns `-54` (`kAudioFilePermissionsError`) on files /
    /// directories tagged that way even when the device is unlocked.
    /// Switching `protectionClass` to
    /// `completeUntilFirstUserAuthentication` only affects newly
    /// created nodes; pre-existing nodes from earlier testing keep
    /// their original `.complete` class until something explicitly
    /// re-tags them. This sweep does that on every launch.
    @discardableResult
    public static func migrateProtectionClass() -> Int {
        guard let root = try? appSupport() else { return 0 }
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.fileProtectionKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }
        var retagged = 0
        // Tag the root itself too — the enumerator yields only
        // children, not the root URL.
        applyProtection(to: root)
        retagged += 1
        for case let url as URL in enumerator {
            let before = currentProtection(of: url)
            if before != protectionClass {
                applyProtection(to: url)
                retagged += 1
            }
        }
        return retagged
    }

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
        }
        applyProtection(to: dir)
        return dir
    }

    public static func voiceNotesDir() throws -> URL {
        let dir = try appSupport().appending(path: "driveby_seeds", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        applyProtection(to: dir)
        return dir
    }

    public static func sessionsStagingDir() throws -> URL {
        let dir = try appSupport().appending(path: "sessions", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        applyProtection(to: dir)
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
        try data.write(to: url, options: [.atomic, dataProtectionWriteOption])
    }

    // MARK: - Surfaced note index ---------------------------

    /// Filename for the JSON sidecar listing every seed_id that's been
    /// surfaced in a walkthrough session. Used to filter out notes that
    /// have already been folded into a diary entry so the note
    /// section never re-surfaces them.
    public static let surfacedSeedsFilename = "surfaced_seed_ids.json"

    private static func surfacedSeedsURL() throws -> URL {
        try appSupport().appending(path: surfacedSeedsFilename)
    }

    public static func surfacedNoteIDs() -> Set<String> {
        guard let url = try? surfacedSeedsURL(),
              let data = try? Data(contentsOf: url),
              let ids = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return Set(ids)
    }

    public static func markSeedsSurfaced(ids: [String]) {
        guard !ids.isEmpty else { return }
        var current = surfacedNoteIDs()
        current.formUnion(ids)
        guard let url = try? surfacedSeedsURL() else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(Array(current).sorted()) else { return }
        try? data.write(to: url, options: [.atomic, dataProtectionWriteOption])
    }
}
