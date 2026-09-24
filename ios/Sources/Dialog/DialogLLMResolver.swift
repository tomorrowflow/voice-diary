import Foundation

// Decides which `DialogLLM` backend serves a given walkthrough.
//
// Behaviour: when the user opts in to Gemma, the resolver returns a
// `ChainDialogLLM` that tries Gemma first and falls back to Apple FM
// on any `LLMError`. When the user sticks with the default, Apple FM
// is returned directly. The walkthrough caller never inspects which
// backend it's talking to.
//
// The setting lives in `UserDefaults`; flipping it takes effect on the
// next opener (no app restart needed).

public enum DialogLLMPreference: String, Sendable, CaseIterable {
    case appleFoundation = "apple_fm"
    case gemmaE4B        = "gemma_e4b"

    public var displayName: String {
        switch self {
        case .appleFoundation: return "Apple"
        case .gemmaE4B:        return "Gemma"
        }
    }

    private static let key = "dialog.llm.preferred"

    public static var current: DialogLLMPreference {
        UserDefaults.standard.string(forKey: key)
            .flatMap(DialogLLMPreference.init(rawValue:)) ?? .appleFoundation
    }

    public static func set(_ p: DialogLLMPreference) {
        UserDefaults.standard.set(p.rawValue, forKey: key)
    }
}

public enum DialogLLMResolver {
    /// The `DialogLLM` the walkthrough should use for this session.
    /// Apple FM is always the last-resort fallback because it's
    /// effectively always available on iOS 26.
    public static func current() -> any DialogLLM {
        switch DialogLLMPreference.current {
        case .gemmaE4B:
            return ChainDialogLLM(
                primary: GemmaDialogLLM.shared,
                fallback: AppleFoundationLLM.shared
            )
        case .appleFoundation:
            return AppleFoundationLLM.shared
        }
    }
}

/// Tries `primary` first; on any `LLMError` falls back to `fallback`.
/// The fallback chain is one-deep — that's enough for the only chain
/// we ship (Gemma → Apple FM); a deterministic template still sits
/// behind any FM call in the caller, so a hard failure is fine.
public struct ChainDialogLLM: DialogLLM {

    public let primary: any DialogLLM
    public let fallback: any DialogLLM

    public init(primary: any DialogLLM, fallback: any DialogLLM) {
        self.primary = primary
        self.fallback = fallback
    }

    public var isAvailable: Bool {
        get async {
            // Can't use `||` short-circuit: its second operand is an
            // `@autoclosure () -> Bool` that doesn't support `await`.
            if await primary.isAvailable { return true }
            return await fallback.isAvailable
        }
    }

    public func generateFollowUp(
        eventTitle: String,
        attendees: [String],
        userTranscript: String,
        language: String
    ) async throws -> String {
        do {
            return try await primary.generateFollowUp(
                eventTitle: eventTitle,
                attendees: attendees,
                userTranscript: userTranscript,
                language: language
            )
        } catch is LLMError {
            return try await fallback.generateFollowUp(
                eventTitle: eventTitle,
                attendees: attendees,
                userTranscript: userTranscript,
                language: language
            )
        }
    }

    public func generateGeneralFollowUp(
        sectionTitle: String,
        sectionIntro: String,
        userTranscript: String,
        language: String
    ) async throws -> String {
        do {
            return try await primary.generateGeneralFollowUp(
                sectionTitle: sectionTitle,
                sectionIntro: sectionIntro,
                userTranscript: userTranscript,
                language: language
            )
        } catch is LLMError {
            return try await fallback.generateGeneralFollowUp(
                sectionTitle: sectionTitle,
                sectionIntro: sectionIntro,
                userTranscript: userTranscript,
                language: language
            )
        }
    }

    public func generateEventOpener(
        context ctx: EventOpenerContext,
        language: String
    ) async throws -> String {
        do {
            return try await primary.generateEventOpener(context: ctx, language: language)
        } catch is LLMError {
            return try await fallback.generateEventOpener(context: ctx, language: language)
        }
    }

    public func summarizeNote(
        transcript: String,
        language: String
    ) async throws -> String {
        do {
            return try await primary.summarizeNote(transcript: transcript, language: language)
        } catch is LLMError {
            return try await fallback.summarizeNote(transcript: transcript, language: language)
        }
    }

    public func extractImplicit(
        transcript: String,
        language: String
    ) async throws -> [ImplicitCandidate] {
        do {
            return try await primary.extractImplicit(transcript: transcript, language: language)
        } catch is LLMError {
            return try await fallback.extractImplicit(transcript: transcript, language: language)
        }
    }
}
