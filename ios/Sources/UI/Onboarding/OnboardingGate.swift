import Foundation

/// Decides whether the first-run server setup is shown. A device that
/// already has a valid server URL in Keychain (any working install) never
/// sees it; otherwise it appears until the user finishes or skips it once.
public enum OnboardingGate {
    public static let serverSetupDoneKey = "onboarding.serverSetup.done.v1"

    public static func needsServerSetup(storedURL: String?, done: Bool) -> Bool {
        if done { return false }
        guard let storedURL, case .success = ServerURLValidator.validate(storedURL) else { return true }
        return false
    }

    public static func needsServerSetup(
        defaults: UserDefaults = .standard
    ) -> Bool {
        needsServerSetup(storedURL: KeychainStore.read(.serverURL),
                         done: defaults.bool(forKey: serverSetupDoneKey))
    }

    public static func markServerSetupDone(defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: serverSetupDoneKey)
    }
}
