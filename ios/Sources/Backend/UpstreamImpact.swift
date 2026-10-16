import Foundation

/// One unhealthy upstream and what it means for the user.
public struct UpstreamImpactLine: Equatable, Identifiable, Sendable {
    /// Contract name from `/health`, e.g. `whisper`.
    public let upstream: String
    /// Display name, e.g. "Whisper". Product names are not translated.
    public let name: String
    /// The localized one-line impact from `FailureCatalog`.
    public let impact: String

    public var id: String { upstream }
}

/// Pure translation of the `/health` per-upstream probe results into the
/// impact sentences shown in Mehr → Server and in the walkthrough start
/// notice (PRD "Upstream Failure Handling"). Copy comes from
/// `FailureCatalog`, so a sentence is worded in exactly one place.
public enum UpstreamImpact {
    /// Impact lines for every contract upstream whose probe is not healthy,
    /// in a fixed order (Whisper, Ollama, LightRAG, Graph, Voxtral).
    ///
    /// `ok`, `skipped` (not configured) and `fixture` (dev mode) say nothing
    /// about health and yield no line, and neither do infrastructure probes
    /// (`postgres`, `qdrant`) that are not upstreams of the contract.
    /// `language: nil` follows the app's current language.
    public static func lines(
        health upstream: [String: String],
        language: OpenerLanguage? = nil
    ) -> [UpstreamImpactLine] {
        FailureCatalog.Upstream.allCases.compactMap { known in
            guard let result = upstream[known.rawValue], !healthyResults.contains(result) else { return nil }
            let code = result == "not_bootstrapped" && known == .msgraph
                ? "msgraph_not_bootstrapped"
                : "\(known.rawValue)_unavailable"
            let failure = UpstreamFailure(code: code, upstream: known.rawValue)
            guard let copy = FailureCatalog.copy(for: failure, language: language) else { return nil }
            return UpstreamImpactLine(upstream: known.rawValue, name: displayName(known), impact: copy.impact)
        }
    }

    /// The walkthrough start notice: each distinct impact sentence once, one
    /// per line (Ollama and LightRAG share a sentence). Nil when nothing is
    /// unhealthy. Voxtral only matters when a server voice is selected, so
    /// `includeVoxtral` is false otherwise.
    public static func startNotice(
        health upstream: [String: String],
        includeVoxtral: Bool,
        language: OpenerLanguage? = nil
    ) -> String? {
        var seen = Set<String>()
        let sentences = lines(health: upstream, language: language)
            .filter { includeVoxtral || $0.upstream != FailureCatalog.Upstream.voxtral.rawValue }
            .map(\.impact)
            .filter { seen.insert($0).inserted }
        return sentences.isEmpty ? nil : sentences.joined(separator: "\n")
    }

    private static let healthyResults: Set<String> = ["ok", "skipped", "fixture"]

    private static func displayName(_ upstream: FailureCatalog.Upstream) -> String {
        switch upstream {
        case .whisper: return "Whisper"
        case .ollama: return "Ollama"
        case .lightrag: return "LightRAG"
        case .msgraph: return "Microsoft Graph"
        case .voxtral: return "Voxtral"
        }
    }
}
