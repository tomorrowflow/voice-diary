import Foundation
import os

// Centralised `os.Logger` subsystems. Filter in Console.app or `log stream`
// with `subsystem == "com.tomorrowflow.voice-diary"` and the per-category tag.
//
// Usage:
//     Log.upload.info("queued session \(sessionID, privacy: .public)")
//     Log.audio.error("ffmpeg failed: \(error.localizedDescription, privacy: .public)")
//
// Default privacy on string interpolations is `.private` — that is what we
// want for transcripts and tokens. Mark identifiers `.public` only when
// the value is harmless to expose in logs (UUIDs, error codes, etc.).

public enum Log {
    public static let subsystem = "com.tomorrowflow.voice-diary"

    public static let app          = Logger(subsystem: subsystem, category: "app")
    public static let audio        = Logger(subsystem: subsystem, category: "audio")
    public static let backend      = Logger(subsystem: subsystem, category: "backend")
    public static let upload       = Logger(subsystem: subsystem, category: "upload")
    public static let reachability = Logger(subsystem: subsystem, category: "reachability")
    public static let storage      = Logger(subsystem: subsystem, category: "storage")
}
