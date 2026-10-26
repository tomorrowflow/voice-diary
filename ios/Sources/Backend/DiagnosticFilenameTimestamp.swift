import Foundation

// Filename stem for a stored diagnostic report, e.g.
// "2026-06-02T09-14-22Z". Pure over `Date` / `String` so it can be tested
// without files; `DiagnosticsCollector` owns naming and grouping the
// `.json` / `.log` pair and the fallback when a stem doesn't parse.

enum DiagnosticFilenameTimestamp {
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        // Colons are illegal in filenames on some FS; use dashes.
        f.dateFormat = "yyyy-MM-dd'T'HH-mm-ss'Z'"
        return f
    }()

    /// UTC stem for `date`, truncated to whole seconds.
    static func stem(from date: Date) -> String {
        formatter.string(from: date)
    }

    /// The instant a stem names, or nil when `DateFormatter` rejects it.
    static func date(fromStem stem: String) -> Date? {
        formatter.date(from: stem)
    }
}
