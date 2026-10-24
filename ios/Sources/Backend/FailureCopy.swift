import Foundation

/// Title, hint and one-line impact for a coded upstream failure.
public struct FailureCopy: Equatable, Sendable {
    public let title: String
    public let hint: String
    /// What the failure means for the user's data and walkthrough.
    public let impact: String
    /// What a diagnosis shows under the title: the hint, then the impact.
    /// "Not set up" is the exception: its hint already says the server has
    /// to fix it, so the impact would only say it again.
    public let summary: String
}

/// Pure mapping from the server failure contract (`code`, `upstream`) to
/// user-facing copy in German and English (PRD "Upstream Failure
/// Handling"). Strings live in `Localizable.xcstrings` (English text is
/// the key); this file only chooses which key applies.
///
/// A known `code` wins. An unknown code from a newer server still gets a
/// sensible message when its `upstream` is known; with neither, every
/// lookup returns nil and callers keep their status-based behaviour.
public enum FailureCatalog {
    enum Upstream: String, CaseIterable {
        case whisper, ollama, lightrag, msgraph, voxtral, blindfold
    }

    enum Condition {
        case unavailable, timeout, engineError
        case notBootstrapped, rateLimited, unknownVoice
    }

    /// Copy for a failure, or nil when neither `code` nor `upstream` is
    /// recognised. `language: nil` follows the app's current language.
    public static func copy(for failure: UpstreamFailure, language: OpenerLanguage? = nil) -> FailureCopy? {
        guard let (upstream, condition) = resolve(failure) else { return nil }
        let hintText = text(hint(condition), language)
        let impactText = text(impact(upstream, condition), language)
        return FailureCopy(
            title: text(title(upstream, condition), language),
            hint: hintText,
            impact: impactText,
            summary: condition == .notBootstrapped ? hintText : "\(hintText) \(impactText)"
        )
    }

    /// Copy for a `failed` or `pending_analysis` session segment from its `code` / `upstream`
    /// (SPEC §10.5). Nil without a `code`, so a segment the server could not
    /// attribute keeps today's plain "Failed" pill, even if `upstream` is set.
    public static func copy(
        forSegmentCode code: String?,
        upstream: String?,
        language: OpenerLanguage? = nil
    ) -> FailureCopy? {
        guard let code, !code.isEmpty else { return nil }
        return copy(for: UpstreamFailure(code: code, upstream: upstream), language: language)
    }

    /// Title Verlauf shows under a segment's details. A `failed` segment and a
    /// `pending_analysis` one (the server keeps `code` / `upstream` on both
    /// while an upstream is down) get the copy of their `(code, upstream)`;
    /// every other status, and a segment without a `code`, gets none.
    public static func segmentExplanation(
        status: String?,
        code: String?,
        upstream: String?,
        language: OpenerLanguage? = nil
    ) -> String? {
        guard status == "failed" || status == "pending_analysis" else { return nil }
        return copy(forSegmentCode: code, upstream: upstream, language: language)?.title
    }

    /// Spoken line for a failed enrichment question, ending in
    /// "Anreicherung übersprungen" / "Enrichment skipped". Only the
    /// upstreams enrichment calls (Ollama, LightRAG, Graph) have one
    /// (Blindfold only carries the main analysis, never enrichment);
    /// nil for everything else so the caller keeps its generic split.
    public static func spokenEnrichmentLine(for failure: UpstreamFailure, language: OpenerLanguage? = nil) -> String? {
        guard let (upstream, condition) = resolve(failure) else { return nil }
        switch (upstream, condition) {
        case (.ollama, _):
            return text("The summary isn’t available right now. Enrichment skipped.", language)
        case (.lightrag, _):
            return text("The diary memory isn’t reachable right now. Enrichment skipped.", language)
        case (.msgraph, .notBootstrapped):
            return text("Calendar and mail aren’t set up on the server. Enrichment skipped.", language)
        case (.msgraph, _):
            return text("Calendar and mail aren’t reachable right now. Enrichment skipped.", language)
        case (.whisper, _), (.voxtral, _), (.blindfold, _):
            return nil
        }
    }

    // MARK: - Resolution

    static func resolve(_ failure: UpstreamFailure) -> (Upstream, Condition)? {
        if let code = failure.code, let known = knownCodes[code] { return known }
        guard let name = failure.upstream, let upstream = Upstream(rawValue: name) else { return nil }
        // Unknown code from a newer server: the upstream alone is enough
        // to say who answered badly.
        return (upstream, .engineError)
    }

    private static let knownCodes: [String: (Upstream, Condition)] = {
        var table: [String: (Upstream, Condition)] = [
            "msgraph_not_bootstrapped": (.msgraph, .notBootstrapped),
            "msgraph_rate_limited": (.msgraph, .rateLimited),
            "unknown_voice": (.voxtral, .unknownVoice),
        ]
        for upstream in Upstream.allCases {
            table["\(upstream.rawValue)_unavailable"] = (upstream, .unavailable)
            table["\(upstream.rawValue)_timeout"] = (upstream, .timeout)
            table["\(upstream.rawValue)_engine_error"] = (upstream, .engineError)
        }
        return table
    }()

    // MARK: - Catalog keys

    private static func title(_ upstream: Upstream, _ condition: Condition) -> String {
        switch (upstream, condition) {
        case (_, .notBootstrapped): return "Calendar and mail aren’t set up"
        case (_, .rateLimited): return "Calendar and mail are busy"
        case (_, .unknownVoice): return "Server voice not found"
        case (.whisper, .unavailable): return "Transcription isn’t available"
        case (.whisper, .timeout): return "Transcription is taking too long"
        case (.whisper, _): return "Transcription failed"
        case (.ollama, .unavailable): return "Analysis isn’t available"
        case (.ollama, .timeout): return "Analysis is taking too long"
        case (.ollama, _): return "Analysis failed"
        case (.lightrag, .unavailable): return "Diary memory isn’t available"
        case (.lightrag, .timeout): return "Diary memory is taking too long"
        case (.lightrag, _): return "Diary memory failed"
        case (.msgraph, .unavailable): return "Calendar and mail aren’t available"
        case (.msgraph, .timeout): return "Calendar and mail are taking too long"
        case (.msgraph, _): return "Calendar and mail failed"
        case (.voxtral, .unavailable): return "Server voice isn’t available"
        case (.voxtral, .timeout): return "Server voice is taking too long"
        case (.voxtral, _): return "Server voice failed"
        case (.blindfold, .unavailable): return "Private analysis isn’t available"
        case (.blindfold, .timeout): return "Private analysis is taking too long"
        case (.blindfold, _): return "Private analysis failed"
        }
    }

    private static func hint(_ condition: Condition) -> String {
        switch condition {
        case .unavailable, .timeout:
            return "This is usually temporary. Try again in a moment."
        case .engineError:
            return "The service answered with an error. Try again in a moment; if it keeps happening, check the server logs."
        case .notBootstrapped:
            return "Microsoft sign-in has to be completed on the server. This can’t be fixed on the phone."
        case .rateLimited:
            return "Microsoft is asking for a short pause. Try again in a moment."
        case .unknownVoice:
            return "Choose a different voice in the voice settings."
        }
    }

    private static func impact(_ upstream: Upstream, _ condition: Condition) -> String {
        switch (upstream, condition) {
        case (.msgraph, .notBootstrapped):
            return "Calendar isn’t set up on the server. This has to be fixed on the server."
        case (.whisper, _): return "Recordings stay on your phone and upload later."
        case (.ollama, _), (.lightrag, _), (.blindfold, _): return "Analysis is delayed; your texts are saved."
        case (.msgraph, _): return "Calendar and mail aren’t reachable right now."
        case (.voxtral, _): return "Server voices fall back to Piper."
        }
    }

    // MARK: - String catalog lookup

    /// Resolve `key` in `Localizable.xcstrings`. An explicit language
    /// reads that language's table regardless of the app setting (the
    /// walkthrough speaks in the language it is running in); nil follows
    /// the app's current language via `Bundle.main`. A missing entry
    /// falls back to the English key, never to an empty string.
    static func text(_ key: String, _ language: OpenerLanguage?) -> String {
        guard let language else {
            return Bundle.main.localizedString(forKey: key, value: key, table: nil)
        }
        guard let path = Bundle.main.path(forResource: language.rawValue, ofType: "lproj"),
              let bundle = Bundle(path: path)
        else { return key }
        return bundle.localizedString(forKey: key, value: key, table: nil)
    }
}
