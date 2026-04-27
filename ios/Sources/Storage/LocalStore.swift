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
}
