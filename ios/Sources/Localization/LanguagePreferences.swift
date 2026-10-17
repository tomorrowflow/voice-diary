import Foundation

// Per-session overrides that sit next to the app-language toggle
// (`AppLanguage`): which language the wake-word listener and transcripts
// assume, and which language the AI speaks back in. Both default to
// "follow the session", so a device that never opens the pickers behaves
// exactly as before.

/// Language the app listens for while recording (SPEC §9.2).
public enum RecordingLanguage: String, Sendable, CaseIterable, Identifiable {
    /// Follow the session language (the app language).
    case auto
    case de
    case en

    public var id: String { rawValue }

    public static let storageKey = "voiceDiary.recordingLanguage.v1"

    public static var current: RecordingLanguage {
        UserDefaults.standard.string(forKey: storageKey).flatMap(Self.init(rawValue:)) ?? .auto
    }

    /// Language for the wake-word listener; `sessionLanguage` is what
    /// `.auto` falls back to.
    public func resolve(auto sessionLanguage: OpenerLanguage) -> OpenerLanguage {
        switch self {
        case .auto: return sessionLanguage
        case .de:   return .de
        case .en:   return .en
        }
    }

    /// Language tag stamped on a transcribed segment. Parakeet reports no
    /// language of its own, so `.auto` keeps the historical "de" default.
    public var transcriptLanguage: String {
        resolve(auto: .de).rawValue
    }
}

/// Language the AI speaks and summarises in (SPEC §9.2).
public enum ResponseLanguage: String, Sendable, CaseIterable, Identifiable {
    /// Follow the session language (the app language).
    case match
    case de
    case en

    public var id: String { rawValue }

    public static let storageKey = "voiceDiary.responseLanguage.v1"

    public static var current: ResponseLanguage {
        UserDefaults.standard.string(forKey: storageKey).flatMap(Self.init(rawValue:)) ?? .match
    }

    public func resolve(match sessionLanguage: OpenerLanguage) -> OpenerLanguage {
        switch self {
        case .match: return sessionLanguage
        case .de:    return .de
        case .en:    return .en
        }
    }

    /// Value of the manifest's `response_language_setting` (SPEC §10).
    public var manifestValue: String {
        self == .match ? "match_input" : rawValue
    }
}
