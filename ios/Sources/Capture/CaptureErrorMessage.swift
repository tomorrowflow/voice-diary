import AVFoundation
import Foundation

// Maps errors surfaced by `CaptureCoordinator` to user-facing copy.
//
// Out-of-space failures get localized, recovery-oriented text (SPEC §15.2:
// a capture never loses audio it already wrote — the user's next step is to
// free space). Everything else keeps the raw description so diagnosable
// errors stay visible.

enum CaptureErrorMessage {
    /// Where in the capture lifecycle the error happened. Decides whether
    /// the copy may promise that audio is safe.
    enum Context {
        /// `start()` — nothing has been recorded yet.
        case start
        /// `resume()` — earlier chunks were finalised on pause and are kept.
        case resume
        /// `stop()` — audio chunks are on disk, only `metadata.json` failed.
        case finishAudioSaved
        /// `stop()` — the engine failed to finalise; the file state is unknown.
        case finish
    }

    static func message(for error: any Error, context: Context) -> String {
        guard isOutOfSpace(error) else { return "\(error)" }
        switch context {
        case .start:
            return String(localized: "Not enough storage to start recording. Free up space in Settings › General › iPhone Storage, then try again.")
        case .resume:
            return String(localized: "Not enough storage to resume. Your earlier audio is saved. Free up space in Settings › General › iPhone Storage, then try again.")
        case .finishAudioSaved:
            return String(localized: "Not enough storage to finish saving. Your audio is saved on this iPhone. Free up space in Settings › General › iPhone Storage, then try again.")
        case .finish:
            return String(localized: "Not enough storage to finish the recording. Free up space in Settings › General › iPhone Storage, then try again.")
        }
    }

    /// True for "disk full" / quota errors in any of the shapes they
    /// arrive in: Cocoa file-write, POSIX `ENOSPC`/`EDQUOT`, AVFoundation
    /// `.diskFull`, or any of those wrapped as an underlying error.
    static func isOutOfSpace(_ error: any Error) -> Bool {
        isOutOfSpace(error as NSError, depth: 0)
    }

    private static func isOutOfSpace(_ error: NSError, depth: Int) -> Bool {
        switch (error.domain, error.code) {
        case (NSCocoaErrorDomain, NSFileWriteOutOfSpaceError),
             (NSPOSIXErrorDomain, Int(ENOSPC)),
             (NSPOSIXErrorDomain, Int(EDQUOT)),
             (AVFoundationErrorDomain, AVError.diskFull.rawValue):
            return true
        default:
            break
        }
        guard depth < 4, let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError else {
            return false
        }
        return isOutOfSpace(underlying, depth: depth + 1)
    }
}
