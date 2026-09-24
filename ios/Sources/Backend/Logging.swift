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

    /// Stamp the message with a short session correlation tag so the
    /// Diagnostics view can pull every event from one recording with a
    /// single substring filter. Pass `nil` (or skip) when the call site
    /// has no associated session.
    public static func log(session: UUID?, _ message: String) {
        if let session {
            let short = session.uuidString.prefix(8)
            Log.app.notice("[sid=\(String(short), privacy: .public)] \(message, privacy: .public)")
        } else {
            log(message)
        }
    }
}

/// Lightweight resident-memory reader so cardinal-event Diag lines can
/// piggy-back a snapshot of what jetsam is actually seeing. The number
/// comes from `mach_task_basic_info.resident_size` — the same field the
/// kernel weighs against the per-app memory cap. Reads are syscall-cheap
/// (<1 µs) so it's safe to fire on every state-machine transition.
///
/// Used to diagnose slow-growth leaks across a long walkthrough (several
/// events in one process lifetime) where the visible failure mode is a
/// SIGKILL with no proximate cause line in the log.
public enum MemoryReport {
    public static func residentBytes() -> UInt64? {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size
        )
        let kerr: kern_return_t = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(
                    mach_task_self_,
                    task_flavor_t(MACH_TASK_BASIC_INFO),
                    $0,
                    &count
                )
            }
        }
        guard kerr == KERN_SUCCESS else { return nil }
        return info.resident_size
    }

    /// "412 MB" — terse enough to inline in a Diag line without
    /// blowing past the console column wrap on Xcode's debug area.
    public static func formatted() -> String {
        guard let bytes = residentBytes() else { return "?" }
        let mb = Double(bytes) / (1024.0 * 1024.0)
        return String(format: "%.0f MB", mb)
    }
}
