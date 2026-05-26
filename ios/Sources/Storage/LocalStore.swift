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
