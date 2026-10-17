import Foundation
import UIKit

/// Stages diary audio in the temporary directory for the share sheet and
/// removes the staged copy once the share is over (SEC-3, #21).
///
/// Staged files carry the app-wide `LocalStore.protectionClass`
/// (`completeUntilFirstUserAuthentication`), never `.none`: the share
/// extension only runs while the device is unlocked, so the class still
/// lets it read the file, and the audio stays encrypted before first unlock.
public enum ShareStaging {

    /// Copy `sourceURL` into `directory` as `<baseName>.m4a` with the
    /// app-wide protection class. The source file is left untouched.
    public static func stage(
        sourceURL: URL,
        baseName: String,
        in directory: URL = FileManager.default.temporaryDirectory,
        protect: ProtectionSetter = ShareStaging.setProtection
    ) throws -> URL {
        let dest = directory.appending(path: "\(baseName).m4a")
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        // Copy, not read-into-memory: the source can be a long recording.
        try FileManager.default.copyItem(at: sourceURL, to: dest)
        // copyItem keeps the source's class; set the share-staging one
        // explicitly rather than relying on inheritance.
        protect(dest, LocalStore.protectionClass)
        return dest
    }

    /// Applies a protection class to a staged file. Injectable because the
    /// simulator ignores per-file protection, so tests assert on the class
    /// that was requested instead of reading it back.
    public typealias ProtectionSetter = @Sendable (URL, URLFileProtection) -> Void

    /// Best-effort — protection is a hint, never an error path.
    public static func setProtection(_ url: URL, _ protection: URLFileProtection) {
        try? (url as NSURL).setResourceValue(protection, forKey: .fileProtectionKey)
    }

    /// Delete a staged export. Best-effort and idempotent: a missing file is
    /// fine, and it must never surface as a user-facing error.
    public static func discard(_ url: URL?) {
        guard let url else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Completion handler for `UIActivityViewController` that removes
    /// `url` however the share ended — completed, cancelled, or failed.
    public static func discardingHandler(
        for url: URL
    ) -> UIActivityViewController.CompletionWithItemsHandler {
        { _, _, _, _ in discard(url) }
    }
}
