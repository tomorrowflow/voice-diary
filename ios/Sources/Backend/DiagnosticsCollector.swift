import Foundation
import MetricKit
import OSLog

// On-device crash + log capture for after-the-fact diagnostics.
//
// Why this exists. The user records evening walkthroughs hands-off, often
// away from a Mac. When the app crashes mid-session, Console.app and
// Xcode are not in reach — and even back at the desk, the system log
// store has a size cap that may have rolled the relevant window out by
// the time Xcode is plugged in. This collector runs in-process, takes
// no network, and survives indefinitely until the user deletes a
// report. Aligns with SPEC §15.3 (errors log locally only, viewable in
// Settings → About → Diagnostics).
//
// What gets captured. On the next launch after a crash/hang/CPU/disk
// exception, `MXMetricManager` delivers an `MXDiagnosticPayload`. We
// persist:
//   1. `crashes/<timestamp>.json`   — the raw MetricKit payload
//   2. `crashes/<timestamp>.log`    — log entries from our subsystem
//                                     for the window around the crash,
//                                     pulled from `OSLogStore` *now*
//                                     (while it's still in the system
//                                     store) so it can't roll out from
//                                     under us later.
//
// What does not happen. No third-party SDK. No network. No symbolication
// — Xcode handles that when the user shares the bundle to a Mac.

public final class DiagnosticsCollector: NSObject, @unchecked Sendable {
    public static let shared = DiagnosticsCollector()

    /// Cap on how many crash bundles we keep on disk. Older entries are
    /// pruned on each new delivery. 20 covers months of real-world use
    /// at this app's crash rate without ever needing manual cleanup.
    private static let maxStoredReports = 20

    /// Window of log context to bundle with each crash. 10 minutes
    /// captures a typical walkthrough (5 events × ~90 s) without
    /// blowing past the system store's retention for our subsystem.
    private static let logWindowBeforeSeconds: TimeInterval = 600
    private static let logWindowAfterSeconds: TimeInterval = 60

    private override init() { super.init() }

    /// Idempotent. Safe to call from `VoiceDiaryApp.init`. Adds us as
    /// an `MXMetricManagerSubscriber` so the system delivers payloads
    /// the next time it has any (typically at the next launch after a
    /// crash, otherwise once per day).
    public func start() {
        MXMetricManager.shared.add(self)
        Log.app.info("DiagnosticsCollector started")
    }

    // --- public read API for the UI -----------------------------------

    public struct Report: Identifiable, Sendable {
        public let id: String              // filename stem, e.g. "2026-06-02T09-14-22Z"
        public let timestamp: Date
        public let summary: String         // "Crash · 3 frame(s)" etc.
        public let payloadURL: URL
        public let logURL: URL?
    }

    /// List of stored crash reports, newest first.
    public func listReports() -> [Report] {
        guard let dir = try? Self.crashesDir() else { return [] }
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var byStem: [String: (json: URL?, log: URL?)] = [:]
        for url in entries {
            let stem = url.deletingPathExtension().lastPathComponent
            var entry = byStem[stem] ?? (json: nil, log: nil)
            switch url.pathExtension {
            case "json": entry.json = url
            case "log":  entry.log = url
            default:     break
            }
            byStem[stem] = entry
        }

        var reports: [Report] = []
        for (stem, urls) in byStem {
            guard let payloadURL = urls.json else { continue }
            let timestamp = Self.timestamp(fromStem: stem)
                ?? (try? payloadURL.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate)
                ?? Date(timeIntervalSince1970: 0)
            let summary = Self.summarize(payloadAt: payloadURL)
            reports.append(Report(
                id: stem,
                timestamp: timestamp,
                summary: summary,
                payloadURL: payloadURL,
                logURL: urls.log
            ))
        }
        return reports.sorted { $0.timestamp > $1.timestamp }
    }

    /// Read the persisted log window for a report. Returns nil if the
    /// `.log` companion file was not produced (older payload, or the
    /// snapshot itself failed).
    public func readLog(for report: Report) -> String? {
        guard let url = report.logURL,
              let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return text
    }

    /// Pretty-print the JSON payload for the detail view.
    public func readPayloadJSON(for report: Report) -> String? {
        guard let data = try? Data(contentsOf: report.payloadURL),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(
                withJSONObject: obj,
                options: [.prettyPrinted, .sortedKeys]
              ) else {
            return (try? Data(contentsOf: report.payloadURL))
                .flatMap { String(data: $0, encoding: .utf8) }
        }
        return String(data: pretty, encoding: .utf8)
    }

    public func delete(_ report: Report) {
        try? FileManager.default.removeItem(at: report.payloadURL)
        if let logURL = report.logURL {
            try? FileManager.default.removeItem(at: logURL)
        }
    }

    public func deleteAll() {
        for report in listReports() { delete(report) }
    }

    /// Build a single shareable text bundle for AirDrop/Mail/Save to Files.
    /// Includes payload JSON + log window, prefixed with a small header.
    public func shareBundleText(for report: Report) -> String {
        var out = "Voice Diary diagnostic report\n"
        out += "id: \(report.id)\n"
        out += "captured: \(ISO8601DateFormatter().string(from: report.timestamp))\n"
        out += "summary: \(report.summary)\n"
        out += "----- MetricKit payload -----\n"
        out += (readPayloadJSON(for: report) ?? "(unavailable)") + "\n"
        out += "----- Log window -----\n"
        out += (readLog(for: report) ?? "(no log snapshot)") + "\n"
        return out
    }

    /// Live tail of the app's own subsystem entries for the last N hours,
    /// for the "recent logs" view. Pulled directly from OSLogStore at
    /// view time — no persistent mirror.
    public func recentLogLines(hours: Double = 1) -> [String] {
        let since = Date().addingTimeInterval(-hours * 3600)
        return (try? Self.fetchLogEntries(from: since, to: Date())) ?? []
    }

    // --- internal: snapshot + persistence -----------------------------

    /// Persist a MetricKit payload and a log window around its timeframe.
    /// Called from the subscriber callback.
    fileprivate func persist(payload: MXDiagnosticPayload) {
        let json = payload.jsonRepresentation()
        let begin = payload.timeStampBegin
        let end = payload.timeStampEnd
        let stem = Self.stem(from: end)

        guard let dir = try? Self.crashesDir() else {
            Log.app.error("DiagnosticsCollector: crashes dir unavailable")
            return
        }

        let payloadURL = dir.appending(path: "\(stem).json")
        do {
            try json.write(to: payloadURL, options: [.atomic])
        } catch {
            Log.app.error(
                "DiagnosticsCollector: payload write failed \(String(describing: error), privacy: .public)"
            )
            return
        }

        // Capture the log window *now*, while OSLogStore still has it.
        // Pad slightly on either side of the MetricKit-reported window.
        let logFrom = begin.addingTimeInterval(-Self.logWindowBeforeSeconds)
        let logTo   = end.addingTimeInterval(Self.logWindowAfterSeconds)
        if let lines = try? Self.fetchLogEntries(from: logFrom, to: logTo),
           !lines.isEmpty {
            let logURL = dir.appending(path: "\(stem).log")
            let text = lines.joined(separator: "\n") + "\n"
            try? text.data(using: .utf8)?.write(to: logURL, options: [.atomic])
        }

        Self.pruneOldReports(in: dir, keep: Self.maxStoredReports)

        let kinds = Self.kindsSummary(for: payload)
        Log.app.notice(
            "DiagnosticsCollector: persisted \(stem, privacy: .public) [\(kinds, privacy: .public)]"
        )
    }

    // --- helpers -------------------------------------------------------

    private static func crashesDir() throws -> URL {
        let root = try LocalStore.appSupport()
            .appending(path: "diagnostics", directoryHint: .isDirectory)
            .appending(path: "crashes", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        LocalStore.applyProtection(to: root)
        return root
    }

    private static let stemFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        // Colons are illegal in filenames on some FS; use dashes.
        f.dateFormat = "yyyy-MM-dd'T'HH-mm-ss'Z'"
        return f
    }()

    private static func stem(from date: Date) -> String {
        stemFormatter.string(from: date)
    }

    private static func timestamp(fromStem stem: String) -> Date? {
        stemFormatter.date(from: stem)
    }

    private static func summarize(payloadAt url: URL) -> String {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return "Diagnostic"
        }
        var parts: [String] = []
        if let crashes = obj["crashDiagnostics"] as? [Any], !crashes.isEmpty {
            parts.append("Crash×\(crashes.count)")
        }
        if let hangs = obj["hangDiagnostics"] as? [Any], !hangs.isEmpty {
            parts.append("Hang×\(hangs.count)")
        }
        if let cpu = obj["cpuExceptionDiagnostics"] as? [Any], !cpu.isEmpty {
            parts.append("CPU×\(cpu.count)")
        }
        if let disk = obj["diskWriteExceptionDiagnostics"] as? [Any], !disk.isEmpty {
            parts.append("Disk×\(disk.count)")
        }
        return parts.isEmpty ? "Diagnostic" : parts.joined(separator: " · ")
    }

    private static func kindsSummary(for payload: MXDiagnosticPayload) -> String {
        var parts: [String] = []
        if let c = payload.crashDiagnostics, !c.isEmpty { parts.append("crash×\(c.count)") }
        if let h = payload.hangDiagnostics, !h.isEmpty { parts.append("hang×\(h.count)") }
        if let cpu = payload.cpuExceptionDiagnostics, !cpu.isEmpty { parts.append("cpu×\(cpu.count)") }
        if let d = payload.diskWriteExceptionDiagnostics, !d.isEmpty { parts.append("disk×\(d.count)") }
        return parts.isEmpty ? "empty" : parts.joined(separator: ",")
    }

    private static func pruneOldReports(in dir: URL, keep: Int) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        // Group by stem so the JSON+log pair stays together.
        var byStem: [String: [URL]] = [:]
        for url in entries {
            let stem = url.deletingPathExtension().lastPathComponent
            byStem[stem, default: []].append(url)
        }
        guard byStem.count > keep else { return }
        // Sort stems by timestamp (parsed from stem, fall back to mtime).
        let sortedStems = byStem.keys.sorted { a, b in
            let ta = timestamp(fromStem: a) ?? Date.distantPast
            let tb = timestamp(fromStem: b) ?? Date.distantPast
            return ta > tb
        }
        for stem in sortedStems.dropFirst(keep) {
            for url in byStem[stem] ?? [] {
                try? fm.removeItem(at: url)
            }
        }
    }

    /// Fetch app log entries from `OSLogStore` for our subsystem in
    /// `[from, to]`. Returned as preformatted "HH:mm:ss.SSS [category]
    /// level message" lines.
    private static func fetchLogEntries(from: Date, to: Date) throws -> [String] {
        let store = try OSLogStore(scope: .currentProcessIdentifier)
        let position = store.position(date: from)
        let predicate = NSPredicate(
            format: "subsystem == %@", argumentArray: [Log.subsystem]
        )
        let entries = try store.getEntries(at: position, matching: predicate)

        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        f.timeZone = TimeZone.current

        var lines: [String] = []
        for entry in entries {
            if entry.date > to { break }
            guard let log = entry as? OSLogEntryLog else { continue }
            let level: String
            switch log.level {
            case .debug:  level = "D"
            case .info:   level = "I"
            case .notice: level = "N"
            case .error:  level = "E"
            case .fault:  level = "F"
            case .undefined: level = "?"
            @unknown default: level = "?"
            }
            lines.append("\(f.string(from: log.date)) [\(log.category)] \(level) \(log.composedMessage)")
        }
        return lines
    }
}

extension DiagnosticsCollector: MXMetricManagerSubscriber {
    public func didReceive(_ payloads: [MXMetricPayload]) {
        // Performance metrics: we don't persist these (battery, hangs
        // aggregate, etc.). They show up in Xcode Organizer if the
        // user opts into sharing with the developer — which they have
        // not, by design. Log a notice so the Diagnostics view can
        // confirm the subscription is alive.
        Log.app.info("MetricKit: received \(payloads.count, privacy: .public) metric payload(s)")
    }

    public func didReceive(_ payloads: [MXDiagnosticPayload]) {
        Log.app.notice(
            "MetricKit: received \(payloads.count, privacy: .public) diagnostic payload(s)"
        )
        for payload in payloads {
            persist(payload: payload)
        }
    }
}
