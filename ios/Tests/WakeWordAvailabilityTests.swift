import Testing
@testable import VoiceDiary

// Whether wake-word recognition can be switched on. The settings page
// feeds in the two live per-language flags and the state of the last
// "Test" probe; these tests pin how they combine. Synthetic inputs only
// — no speech task or permission prompt.

@Suite("WakeWordAvailability")
struct WakeWordAvailabilityTests {
    typealias Outcome = WakeWordAvailability.ProbeOutcome

    private static let nonInstalled: [Outcome] = [
        .notInstalled(reason: "SFSpeechErrorDomain:7"),
        .unauthorized,
        .unavailable,
        .timeout,
    ]

    private func isAvailable(
        de: Bool,
        en: Bool,
        _ probe: WakeWordAvailability.Probe
    ) -> Bool {
        WakeWordAvailability.isAvailable(deLive: de, enLive: en, probe: probe)
    }

    // MARK: - Live flags

    @Test("with no probe override, either live flag enables support",
          arguments: [
            (false, false, false),
            (true, false, true),
            (false, true, true),
            (true, true, true),
          ])
    func liveFlagsOnIdle(de: Bool, en: Bool, expected: Bool) {
        #expect(isAvailable(de: de, en: en, .idle) == expected)
    }

    @Test("a running probe provides no override either way",
          arguments: [
            (false, false, false),
            (true, false, true),
            (false, true, true),
            (true, true, true),
          ])
    func liveFlagsWhileRunning(de: Bool, en: Bool, expected: Bool) {
        #expect(isAvailable(de: de, en: en, .running) == expected)
    }

    // MARK: - Completed probe

    @Test("a completed probe with either language installed enables support despite false live flags",
          arguments: [
            (Outcome.installed, Outcome.installed),
            (Outcome.installed, Outcome.timeout),
            (Outcome.unavailable, Outcome.installed),
            (Outcome.installed, Outcome.notInstalled(reason: "kAFAssistantErrorDomain:203")),
            (Outcome.unauthorized, Outcome.installed),
          ])
    func eitherInstalled(de: Outcome, en: Outcome) {
        #expect(isAvailable(de: false, en: false, .done(de: de, en: en)))
    }

    @Test("a completed probe with neither language installed and false live flags is unsupported",
          arguments: nonInstalled)
    func neitherInstalled(outcome: Outcome) {
        #expect(!isAvailable(de: false, en: false, .done(de: outcome, en: outcome)))
    }

    @Test("mixed non-installed outcomes with false live flags are unsupported")
    func mixedNonInstalled() {
        let probe = WakeWordAvailability.Probe.done(
            de: .unauthorized,
            en: .notInstalled(reason: "SFSpeechErrorDomain:7")
        )
        #expect(!isAvailable(de: false, en: false, probe))
    }

    // MARK: - Stale negative probes

    @Test("a failed probe never negates a true live flag",
          arguments: nonInstalled)
    func staleNegativeProbe(outcome: Outcome) {
        let probe = WakeWordAvailability.Probe.done(de: outcome, en: outcome)
        #expect(isAvailable(de: true, en: false, probe))
        #expect(isAvailable(de: false, en: true, probe))
        #expect(isAvailable(de: true, en: true, probe))
    }

    @Test("every live pair, probe state and outcome pair equals the OR of all signals")
    func exhaustiveOr() {
        let outcomes: [Outcome] = [.installed] + Self.nonInstalled
        var probes: [WakeWordAvailability.Probe] = [.idle, .running]
        for de in outcomes {
            for en in outcomes {
                probes.append(.done(de: de, en: en))
            }
        }
        for probe in probes {
            let probeInstalled: Bool
            if case .done(let de, let en) = probe {
                probeInstalled = de == .installed || en == .installed
            } else {
                probeInstalled = false
            }
            for liveDe in [false, true] {
                for liveEn in [false, true] {
                    #expect(isAvailable(de: liveDe, en: liveEn, probe) == (liveDe || liveEn || probeInstalled))
                }
            }
        }
    }

    // MARK: - Probe pair

    @Test("the per-language outcomes are only exposed once the probe is done")
    func outcomes() {
        #expect(WakeWordAvailability.Probe.idle.outcome(for: .german) == nil)
        #expect(WakeWordAvailability.Probe.running.outcome(for: .english) == nil)

        let probe = WakeWordAvailability.Probe.done(
            de: .notInstalled(reason: "SFSpeechErrorDomain:7"),
            en: .installed
        )
        #expect(probe.outcome(for: .german) == .notInstalled(reason: "SFSpeechErrorDomain:7"))
        #expect(probe.outcome(for: .english) == .installed)
    }
}
