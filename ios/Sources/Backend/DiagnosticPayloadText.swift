import Foundation

// Text shown for a persisted MetricKit payload in the Diagnostics detail
// view and share bundle. Pure over the payload's bytes so it can be
// tested without files; `DiagnosticsCollector` owns reading the file.

enum DiagnosticPayloadText {
    /// The payload as pretty-printed JSON with sorted keys. When the bytes
    /// don't parse as a JSON object or array (top-level fragments
    /// included) or can't be re-serialized, the raw UTF-8 text instead;
    /// nil when that isn't valid UTF-8 either.
    static func prettyPrinted(fromJSON data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(
                withJSONObject: obj,
                options: [.prettyPrinted, .sortedKeys]
              ) else {
            return String(data: data, encoding: .utf8)
        }
        return String(data: pretty, encoding: .utf8)
    }
}
