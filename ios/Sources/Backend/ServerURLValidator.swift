import Foundation

/// Format check for the server URL typed in Mehr → Server or the
/// first-run setup. Pure and offline: it only tells a malformed entry
/// apart from a well-formed one, never whether the server answers.
public enum ServerURLValidator {
    public enum Issue: Error, Sendable, Equatable {
        case empty
        /// Only a scheme, e.g. the `http://` the field starts with.
        case missingHost
        case unsupportedScheme
        case malformed

        public var message: String {
            switch self {
            case .empty:
                return String(localized: "Enter your server URL, e.g. http://my-server.tailnet.ts.net:8000.")
            case .missingHost:
                return String(localized: "The server URL needs a host, e.g. http://my-server.tailnet.ts.net:8000.")
            case .unsupportedScheme:
                return String(localized: "The server URL must start with http:// or https://.")
            case .malformed:
                return String(localized: "That doesn’t look like a valid server URL. Check for typos or spaces, e.g. http://my-server.tailnet.ts.net:8000.")
            }
        }
    }

    /// Returns the trimmed URL string to store, or the first problem found.
    public static func validate(_ raw: String) -> Result<String, Issue> {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .failure(.empty) }

        let lower = trimmed.lowercased()
        if lower == "http://" || lower == "https://" { return .failure(.missingHost) }
        guard lower.hasPrefix("http://") || lower.hasPrefix("https://") else {
            return .failure(.unsupportedScheme)
        }

        guard trimmed.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              let components = URLComponents(string: trimmed),
              let host = components.host, !host.isEmpty else {
            return .failure(.malformed)
        }
        return .success(trimmed)
    }
}
