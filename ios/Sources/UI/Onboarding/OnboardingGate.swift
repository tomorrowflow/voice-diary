import Foundation

/// Decides which first-run steps are shown. A device that already has a
/// valid server URL in Keychain (any working install) never sees server
/// setup; otherwise it appears until the user finishes or skips it once.
/// Permission priming follows the same rule: it appears until the user
/// has advanced past it once, and never to someone whose permissions the
/// system has all answered already.
public enum OnboardingGate {
    public static let serverSetupDoneKey = "onboarding.serverSetup.done.v1"
    public static let permissionPrimingDoneKey = "onboarding.permissionPriming.done.v1"

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

    public static func needsPermissionPriming(snapshot: Permissions.Snapshot, done: Bool) -> Bool {
        !done && !snapshot.allDecided
    }

    @MainActor
    public static func needsPermissionPriming(defaults: UserDefaults = .standard) async -> Bool {
        needsPermissionPriming(snapshot: await Permissions.snapshot(),
                               done: permissionPrimingDone(defaults: defaults))
    }

    public static func permissionPrimingDone(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: permissionPrimingDoneKey)
    }

    public static func markPermissionPrimingDone(defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: permissionPrimingDoneKey)
    }
}
