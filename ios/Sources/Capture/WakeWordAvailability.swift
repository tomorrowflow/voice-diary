import Foundation

// Whether wake-word recognition can be switched on. Pure over the two
// live per-language flags and the state of the settings page's "Test"
// probe so the combinations can be tested without a speech task;
// `WakeWordSettingsView` owns gathering the inputs.

enum WakeWordAvailability {
    /// What the empirical recognition probe found for one language.
    enum ProbeOutcome: Equatable {
        case installed
        case notInstalled(reason: String)
        case unauthorized
        case unavailable
        case timeout
    }

    enum Language {
        case german
        case english
    }

    /// State of the "Test" button's probe: both languages are probed
    /// together, so there is one outcome pair.
    enum Probe: Equatable {
        case idle
        case running
        case done(de: ProbeOutcome, en: ProbeOutcome)

        /// The outcome for `language`, or nil until the probe is done.
        func outcome(for language: Language) -> ProbeOutcome? {
            guard case .done(let de, let en) = self else { return nil }
            switch language {
            case .german:  return de
            case .english: return en
            }
        }

        fileprivate var showsAnyInstalled: Bool {
            guard case .done(let de, let en) = self else { return false }
            return de == .installed || en == .installed
        }
    }

    /// True when either live flag is set or a completed probe found
    /// either language installed. A probe that found nothing never
    /// negates a live flag — `supportsOnDeviceRecognition` can be
    /// stale in both directions, and the probe only ever adds evidence
    /// for support. Idle and running probes contribute nothing.
    static func isAvailable(deLive: Bool, enLive: Bool, probe: Probe) -> Bool {
        deLive || enLive || probe.showsAnyInstalled
    }
}
