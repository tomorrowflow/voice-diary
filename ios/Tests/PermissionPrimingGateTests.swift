import Foundation
import Testing
@testable import VoiceDiary

// First-run permission priming gate — pure decision logic, no system dialogs.

@Suite("OnboardingGate permission priming")
struct PermissionPrimingGateTests {
    private let allOpen = Permissions.Snapshot(microphoneDecided: false, speechDecided: false,
                                               notificationsDecided: false)
    private let allDecided = Permissions.Snapshot(microphoneDecided: true, speechDecided: true,
                                                  notificationsDecided: true)

    @Test("shown on a fresh install, where nothing is answered yet")
    func freshInstall() {
        #expect(OnboardingGate.needsPermissionPriming(snapshot: allOpen, done: false))
    }

    @Test("shown while any one permission is still open")
    func partlyAnswered() {
        let noNotifications = Permissions.Snapshot(microphoneDecided: true, speechDecided: true,
                                                   notificationsDecided: false)
        let noSpeech = Permissions.Snapshot(microphoneDecided: true, speechDecided: false,
                                            notificationsDecided: true)
        #expect(OnboardingGate.needsPermissionPriming(snapshot: noNotifications, done: false))
        #expect(OnboardingGate.needsPermissionPriming(snapshot: noSpeech, done: false))
    }

    @Test("not shown to a returning user who answered everything")
    func returningUser() {
        #expect(!OnboardingGate.needsPermissionPriming(snapshot: allDecided, done: false))
    }

    @Test("not shown again once the user has advanced past it")
    func done() {
        #expect(!OnboardingGate.needsPermissionPriming(snapshot: allOpen, done: true))
    }

    @Test("marking it done persists")
    func markDone() throws {
        let suite = "PermissionPrimingGateTests"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(!OnboardingGate.permissionPrimingDone(defaults: defaults))
        OnboardingGate.markPermissionPrimingDone(defaults: defaults)
        #expect(OnboardingGate.permissionPrimingDone(defaults: defaults))
    }
}
