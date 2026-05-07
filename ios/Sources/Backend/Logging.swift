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

/// Cardinal-event log for the walkthrough state machine + wake-word
/// pipeline. Thin wrapper over `Log.app.notice` with `.public`
/// privacy so the lull-detector / coordinator / ASR sites all flow
/// through one symbol — keeps the call sites short and lets us
/// retarget (e.g. to a separate category) without touching every line.
///
/// Use for low-frequency, high-signal events (state transitions,
/// matches, skipped / failed paths). Per-buffer or per-partial logs
/// belong on `Log.audio.debug` or nowhere.
public enum Diag {
    public static func log(_ message: String) {
        Log.app.notice("\(message, privacy: .public)")
    }
}
