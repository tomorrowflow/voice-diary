import Foundation

/// What went wrong with a dialog-model download, classified from the raw
/// `Error` string. Pure: the view owns the localized copy and styling.
enum DialogDownloadFailure: Equatable {
    case connectionLost
    case offline
    case timeout
    case other(String)

    /// Case-sensitive substring matching; the first match wins, in the
    /// order connection-lost → offline → timeout.
    static func classify(reason: String) -> DialogDownloadFailure {
        if reason.contains("-1005") || reason.contains("network connection was lost") {
            return .connectionLost
        }
        if reason.contains("-1009") || reason.contains("not connected to the Internet") {
            return .offline
        }
        if reason.contains("-1001") || reason.contains("timed out") {
            return .timeout
        }
        return .other(reason)
    }
}
