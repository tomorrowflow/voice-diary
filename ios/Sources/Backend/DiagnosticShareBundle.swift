import Foundation

// Text bundle shared from the Diagnostics detail view. Pure over the
// report fields and the already-read file contents so it can be tested
// without files; `DiagnosticsCollector` owns reading the payload and log.

enum DiagnosticShareBundle {
    /// Shown in place of a payload that could not be read.
    static let payloadUnavailable = "(unavailable)"
    /// Shown in place of a log window that was never captured or read.
    static let logUnavailable = "(no log snapshot)"

    /// Header, then the payload and log sections, each text followed by a
    /// newline. A nil section text takes its fallback; an empty string is
    /// kept as is.
    static func text(
        id: String,
        timestamp: Date,
        summary: String,
        payloadText: String?,
        logText: String?
    ) -> String {
        var out = "Voice Diary diagnostic report\n"
        out += "id: \(id)\n"
        out += "captured: \(ISO8601DateFormatter().string(from: timestamp))\n"
        out += "summary: \(summary)\n"
        out += "----- MetricKit payload -----\n"
        out += (payloadText ?? payloadUnavailable) + "\n"
        out += "----- Log window -----\n"
        out += (logText ?? logUnavailable) + "\n"
        return out
    }
}
