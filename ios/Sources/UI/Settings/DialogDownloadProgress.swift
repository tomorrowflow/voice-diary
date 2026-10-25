import Foundation

// Numeric rule behind the Gemma download bar in `DialogModelSettingsView`.
// Pure: the view keeps the raw completed/total byte counts, the timestamps
// and the stall handling, and only asks this type how to show a fraction and
// whether the completed bytes moved forward.

enum DialogDownloadProgress {
    /// The fraction the bar shows for a `Progress.fractionCompleted`. Finite
    /// values clamp to 0...1; NaN (which `Progress` reports until the total
    /// is known) and either infinity become 0.
    static func normalizedFraction(_ raw: Double) -> Double {
        raw.isFinite ? min(max(raw, 0), 1) : 0
    }

    /// Whether `completed` is strictly more than `previous`. Compares
    /// directly, so no Int64 pair can overflow.
    static func advanced(completed: Int64, previous: Int64) -> Bool {
        completed > previous
    }
}
