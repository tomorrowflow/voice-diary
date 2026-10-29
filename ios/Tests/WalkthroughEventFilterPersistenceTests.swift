// Compiled for the simulator only: on a device these tests would overwrite
// the owner's real walkthrough preferences.
#if targetEnvironment(simulator)
import Foundation
import Testing
@testable import VoiceDiary

/// These tests write the real `UserDefaults.standard` keys behind the three
/// walkthrough event filters, so the suite is serialized, touches only those
/// three keys, and restores each key's exact prior object afterwards
/// (removing it when it was originally absent). No defaults domain is ever
/// reset, and the section-order, general-section and mixed-language keys are
/// never touched.
@Suite("WalkthroughSettingsStore event-filter persistence", .serialized)
struct WalkthroughEventFilterPersistenceTests {

    private enum Filter: CaseIterable {
        case allDay, tentative, notAccepted

        /// Pinned independently of the implementation: renaming a production
        /// key would silently drop every user's saved choice.
        var key: String {
            switch self {
            case .allDay: "walkthrough.includeAllDay"
            case .tentative: "walkthrough.includeTentative"
            case .notAccepted: "walkthrough.includeNotAccepted"
            }
        }

        func set(_ value: Bool) {
            switch self {
            case .allDay: WalkthroughSettingsStore.setIncludeAllDay(value)
            case .tentative: WalkthroughSettingsStore.setIncludeTentative(value)
            case .notAccepted: WalkthroughSettingsStore.setIncludeNotAccepted(value)
            }
        }

        func read(_ settings: WalkthroughSettings) -> Bool {
            switch self {
            case .allDay: settings.includeAllDay
            case .tentative: settings.includeTentative
            case .notAccepted: settings.includeNotAccepted
            }
        }
    }

    /// Every on/off assignment of the three filters, in a fixed order.
    private static let combinations: [[Filter: Bool]] = (0..<(1 << Filter.allCases.count)).map { bits in
        Dictionary(uniqueKeysWithValues: Filter.allCases.enumerated().map { index, filter in
            (filter, (bits >> index) & 1 == 1)
        })
    }

    /// Every non-empty subset of the filters, in a fixed order.
    private static let nonEmptySubsets: [[Filter]] = (1..<(1 << Filter.allCases.count)).map { bits in
        Filter.allCases.enumerated().filter { (bits >> $0.offset) & 1 == 1 }.map(\.element)
    }

    private static func restore(_ value: Any?, forKey key: String) {
        if let value {
            UserDefaults.standard.set(value, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    private func withIsolatedKeys(_ body: () throws -> Void) rethrows {
        let defaults = UserDefaults.standard
        let previous = Filter.allCases.map { defaults.object(forKey: $0.key) }
        defer {
            for (filter, value) in zip(Filter.allCases, previous) {
                Self.restore(value, forKey: filter.key)
            }
        }
        for filter in Filter.allCases { defaults.removeObject(forKey: filter.key) }
        try body()
    }

    private func store(_ combination: [Filter: Bool]) {
        for filter in Filter.allCases { filter.set(combination[filter] == true) }
    }

    private func stored(_ filter: Filter) -> Bool? {
        UserDefaults.standard.object(forKey: filter.key) as? Bool
    }

    @Test("absent keys read as all false")
    func absentKeysDefaultToFalse() {
        withIsolatedKeys {
            let settings = WalkthroughSettingsStore.current

            for filter in Filter.allCases {
                #expect(UserDefaults.standard.object(forKey: filter.key) == nil)
                #expect(filter.read(settings) == false)
            }
        }
    }

    @Test("each setter writes its own pinned key and no other")
    func settersWriteTheirOwnKey() {
        for target in Filter.allCases {
            withIsolatedKeys {
                target.set(true)

                for filter in Filter.allCases {
                    let expected: Bool? = filter == target ? true : nil
                    #expect(stored(filter) == expected, "\(target) wrote \(filter.key)")
                    #expect(filter.read(WalkthroughSettingsStore.current) == (expected == true))
                }
            }
        }
    }

    @Test("all eight combinations persist as explicit values and read back fresh")
    func everyCombinationRoundTrips() {
        for combination in Self.combinations {
            withIsolatedKeys {
                store(combination)

                let settings = WalkthroughSettingsStore.current
                for filter in Filter.allCases {
                    #expect(stored(filter) == combination[filter], "\(combination)")
                    #expect(filter.read(settings) == combination[filter], "\(combination)")
                }
            }
        }
    }

    @Test("flipping one setter leaves the other two choices unchanged")
    func settersAreIndependent() {
        for combination in Self.combinations {
            for target in Filter.allCases {
                withIsolatedKeys {
                    store(combination)

                    let flipped = combination[target] != true
                    target.set(flipped)

                    let settings = WalkthroughSettingsStore.current
                    for filter in Filter.allCases {
                        let expected = filter == target ? flipped : combination[filter]
                        #expect(stored(filter) == expected, "flip \(target) from \(combination)")
                        #expect(filter.read(settings) == expected, "flip \(target) from \(combination)")
                    }
                }
            }
        }
    }

    @Test("removing keys restores their false defaults and keeps the other choices")
    func removalRestoresDefaults() {
        for combination in Self.combinations {
            for removed in Self.nonEmptySubsets {
                withIsolatedKeys {
                    store(combination)
                    for filter in removed { UserDefaults.standard.removeObject(forKey: filter.key) }

                    let settings = WalkthroughSettingsStore.current
                    for filter in Filter.allCases {
                        let expected = removed.contains(filter) ? false : combination[filter]
                        #expect(filter.read(settings) == expected, "remove \(removed) from \(combination)")
                        #expect(stored(filter) == (removed.contains(filter) ? nil : combination[filter]))
                    }
                }
            }
        }
    }

    private struct Abort: Error {}

    /// Plants a prior object under each key, runs a block that overwrites
    /// them, and checks every exact prior object (or its absence) is back
    /// afterwards.
    private func expectRestored(priors: [Any?], throwing: Bool, sourceLocation: SourceLocation = #_sourceLocation) {
        let defaults = UserDefaults.standard
        let outer = Filter.allCases.map { defaults.object(forKey: $0.key) }
        defer {
            for (filter, value) in zip(Filter.allCases, outer) {
                Self.restore(value, forKey: filter.key)
            }
        }
        for (filter, prior) in zip(Filter.allCases, priors) {
            Self.restore(prior, forKey: filter.key)
        }

        do {
            try withIsolatedKeys {
                for filter in Filter.allCases {
                    #expect(defaults.object(forKey: filter.key) == nil, sourceLocation: sourceLocation)
                    filter.set(true)
                }
                if throwing { throw Abort() }
            }
        } catch is Abort {
            #expect(throwing, sourceLocation: sourceLocation)
        } catch {
            Issue.record(error, sourceLocation: sourceLocation)
        }

        for (filter, prior) in zip(Filter.allCases, priors) {
            let restored = defaults.object(forKey: filter.key)
            if let prior {
                #expect((restored as? NSObject)?.isEqual(prior) == true, "prior \(prior)", sourceLocation: sourceLocation)
            } else {
                #expect(restored == nil, sourceLocation: sourceLocation)
            }
        }
    }

    @Test("the exact prior objects are restored on the normal and throwing paths")
    func restoresPriorObjects() {
        // true and false stay explicit values, absent stays absent, and a
        // non-Bool object is not normalised into a Bool. Rotating the list
        // gives every key every kind of prior.
        let kinds: [Any?] = [true, false, nil, "sentinel"]
        for offset in kinds.indices {
            let priors = Filter.allCases.indices.map { kinds[($0 + offset) % kinds.count] }
            expectRestored(priors: priors, throwing: false)
            expectRestored(priors: priors, throwing: true)
        }
    }
}
#endif
