import Foundation

// One-line summary of a persisted MetricKit payload, shown in the
// Diagnostics list. Pure over the payload's JSON bytes so it can be
// tested without files; `DiagnosticsCollector` owns reading the file and
// the unreadable-file fallback.

enum DiagnosticPayloadSummary {
    /// Shown when the payload isn't a JSON object or has no non-empty
    /// diagnostic arrays.
    static let fallback = "Diagnostic"

    /// Payload keys in display order, each with its summary label.
    private static let kinds: [(key: String, label: String)] = [
        ("crashDiagnostics", "Crash"),
        ("hangDiagnostics", "Hang"),
        ("cpuExceptionDiagnostics", "CPU"),
        ("diskWriteExceptionDiagnostics", "Disk"),
    ]

    /// "Crash×2 · Hang×1" for the non-empty arrays present, in the fixed
    /// order above. Array elements are only counted, never inspected.
    static func summary(fromJSON data: Data) -> String {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return fallback
        }
        var parts: [String] = []
        for kind in kinds {
            if let entries = obj[kind.key] as? [Any], !entries.isEmpty {
                parts.append("\(kind.label)×\(entries.count)")
            }
        }
        return parts.isEmpty ? fallback : parts.joined(separator: " · ")
    }
}
