import Foundation

// Read-only view of the bundles on disk: the Verlauf list and the pickup
// lookup both go through here, so the staging layout (directory per session,
// `segments/*.m4a`, `manifest.json` once finalized, `journal.json` while
// recording) is read in one place.

extension SessionBundle {

    /// What the staging directory knows about one bundle without opening it.
    struct Summary: Sendable {
        let sessionID: String
        /// The diary day: the manifest's date, else the capture day.
        let date: String
        let capturedAt: Date
        /// Nil when the manifest snapshot is missing (older sessions).
        let manifest: Manifest?
        /// True once `finalize` wrote the manifest snapshot, readable or not.
        let isFinalized: Bool
        /// Recorded audio, ordered by file name. Orphan temp files are left out.
        let audioFiles: [URL]
        let directory: URL
    }

    /// Every bundle under `root` that has audio, newest capture first.
    /// `root` defaults to the app's staging directory.
    nonisolated static func list(in root: URL? = nil) -> [Summary] {
        guard let root = root ?? (try? LocalStore.sessionsStagingDir()),
              let names = try? FileManager.default.contentsOfDirectory(atPath: root.path)
        else { return [] }
        return names
            .compactMap { summary(of: root.appending(path: $0, directoryHint: .isDirectory)) }
            .sorted { $0.capturedAt > $1.capturedAt }
    }

    /// The latest started bundle for the calendar `day` that was never
    /// finalized, has audio and can be reopened, nil when there is none. A
    /// session started at 23:50 belongs to that day, whenever it is picked up.
    nonisolated static func unfinished(
        on day: Date,
        in root: URL? = nil,
        calendar: Calendar = .current
    ) -> Summary? {
        list(in: root).first { summary in
            !summary.isFinalized
                && FileManager.default.fileExists(
                    atPath: summary.directory.appending(path: journalFilename).path
                )
                && calendar.isDate(summary.capturedAt, inSameDayAs: day)
        }
    }

    private nonisolated static func summary(of directory: URL) -> Summary? {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: directory.path, isDirectory: &isDir), isDir.boolValue else { return nil }

        let manifestURL = directory.appending(path: LocalStore.manifestFilename)
        let manifest = (try? Data(contentsOf: manifestURL))
            .flatMap { try? JSONDecoder().decode(Manifest.self, from: $0) }

        // Enumerate the segments directory itself: it works with or without
        // the manifest. `M4AWriter.isOrphanTempURL` is the single rule for
        // in-progress and abandoned temp files.
        let segmentsDir = directory.appending(path: "segments", directoryHint: .isDirectory)
        let audioFiles = ((try? fm.contentsOfDirectory(
            at: segmentsDir,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        )) ?? [])
            .filter { $0.pathExtension.lowercased() == "m4a" && !M4AWriter.isOrphanTempURL($0) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        // An interrupted session with nothing recorded has nothing to show or resume.
        guard !audioFiles.isEmpty else { return nil }

        let name = directory.lastPathComponent
        let capturedAt = manifest.flatMap { ISO8601DateFormatter().date(from: $0.session_id) }
            ?? capturedAt(fromDirectoryName: name)
            ?? (try? directory.resourceValues(forKeys: [.creationDateKey]).creationDate)
            ?? .distantPast

        return Summary(
            sessionID: manifest?.session_id ?? name,
            date: manifest?.date ?? dayFormatter.string(from: capturedAt),
            capturedAt: capturedAt,
            manifest: manifest,
            isFinalized: fm.fileExists(atPath: manifestURL.path),
            audioFiles: audioFiles,
            directory: directory
        )
    }

    /// Undo `sanitize` on a session directory name (`2026-10-18T18-15-00Z`,
    /// `2026-10-18T20-15-00_02-00`) and parse the ISO timestamp, nil when the
    /// name is something else.
    private nonisolated static func capturedAt(fromDirectoryName name: String) -> Date? {
        guard let split = name.firstIndex(of: "T") else { return nil }
        let clock = name[name.index(after: split)...]
        let time = clock.prefix(8).replacingOccurrences(of: "-", with: ":")
        let rest = clock.dropFirst(8)
        let offset: String
        switch rest.first {
        case "_": offset = "+" + rest.dropFirst().replacingOccurrences(of: "-", with: ":")
        case "-": offset = "-" + rest.dropFirst().replacingOccurrences(of: "-", with: ":")
        default: offset = String(rest)
        }
        return ISO8601DateFormatter().date(from: "\(name[..<split])T\(time)\(offset)")
    }

    private nonisolated static var dayFormatter: DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }
}
