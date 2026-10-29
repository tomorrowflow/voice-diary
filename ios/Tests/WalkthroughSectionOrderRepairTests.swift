import Foundation
import Testing
@testable import VoiceDiary

/// These tests write the real `UserDefaults.standard` keys
/// `walkthrough.generals.v1` and `walkthrough.sectionOrder.v1`, so the suite
/// is serialized, touches only those two keys, and restores their exact prior
/// objects afterwards (removing a key when it was originally absent). No
/// defaults domain is ever reset. Generals are seeded as raw JSON and the
/// mutation workflows (`saveGenerals`, `upsertGeneral`, `deleteGeneral`) are
/// never called; only `saveOrder` and the `order` read are exercised.
@Suite("WalkthroughSettingsStore section-order repair", .serialized)
struct WalkthroughSectionOrderRepairTests {

    /// Pinned independently of the implementation: renaming either production
    /// key would silently drop every user's saved walkthrough plan.
    private static let generalsKey = "walkthrough.generals.v1"
    private static let orderKey = "walkthrough.sectionOrder.v1"
    private static let keys = [generalsKey, orderKey]

    private static let calendar = WalkthroughSection.calendarEvents
    private static let voice = WalkthroughSection.voiceNote
    private static let morning = WalkthroughSection.general(id: "general-morning")
    private static let evening = WalkthroughSection.general(id: "general-evening")

    private static func restore(_ value: Any?, forKey key: String) {
        if let value {
            UserDefaults.standard.set(value, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    /// Starts from both keys absent, so every case is a fresh install plus
    /// exactly the one fault it seeds.
    private func withIsolatedKeys(_ body: () throws -> Void) rethrows {
        let defaults = UserDefaults.standard
        let previous = Self.keys.map { defaults.object(forKey: $0) }
        defer {
            for (key, value) in zip(Self.keys, previous) { Self.restore(value, forKey: key) }
        }
        for key in Self.keys { defaults.removeObject(forKey: key) }
        try body()
    }

    /// Synthetic general sections written as raw JSON, never through
    /// `saveGenerals`.
    private static func seedGenerals(ids: [String]) {
        let json = "[" + ids.map {
            #"{"followUpEnabled":false,"id":"\#($0)","introText":"intro \#($0)","title":"title \#($0)"}"#
        }.joined(separator: ",") + "]"
        UserDefaults.standard.set(Data(json.utf8), forKey: generalsKey)
    }

    private static func rawBytes(_ key: String) -> Data? {
        UserDefaults.standard.data(forKey: key)
    }

    // MARK: first launch

    @Test("with nothing stored the plan is calendar events then voice note")
    func firstLaunchDefault() {
        withIsolatedKeys {
            #expect(UserDefaults.standard.object(forKey: Self.orderKey) == nil)
            #expect(UserDefaults.standard.object(forKey: Self.generalsKey) == nil)
            #expect(WalkthroughSettingsStore.order == [Self.calendar, Self.voice])
        }
    }

    @Test("stored generals without a stored order do not enter the default plan")
    func generalsWithoutOrderStayOut() {
        withIsolatedKeys {
            Self.seedGenerals(ids: ["general-morning"])

            #expect(WalkthroughSettingsStore.order == [Self.calendar, Self.voice])
        }
    }

    // MARK: repair

    @Test("a saved order round-trips unchanged when every reference is valid")
    func validOrderRoundTrips() {
        withIsolatedKeys {
            Self.seedGenerals(ids: ["general-morning", "general-evening"])
            let saved = [Self.morning, Self.voice, Self.evening, Self.calendar]
            WalkthroughSettingsStore.saveOrder(saved)

            #expect(WalkthroughSettingsStore.order == saved)
        }
    }

    @Test("general references without a stored body are dropped")
    func orphanGeneralsAreDropped() {
        withIsolatedKeys {
            Self.seedGenerals(ids: ["general-morning"])
            WalkthroughSettingsStore.saveOrder([Self.evening, Self.calendar, Self.morning, Self.voice])

            #expect(WalkthroughSettingsStore.order == [Self.calendar, Self.morning, Self.voice])
        }
    }

    @Test("valid general order and the first system-block order are preserved")
    func validOrderIsPreserved() {
        withIsolatedKeys {
            Self.seedGenerals(ids: ["general-morning", "general-evening"])
            let saved = [Self.voice, Self.evening, Self.calendar, Self.morning]
            WalkthroughSettingsStore.saveOrder(saved)

            #expect(WalkthroughSettingsStore.order == saved)
        }
    }

    @Test("a duplicate calendar block is collapsed to its first position")
    func duplicateCalendarCollapses() {
        withIsolatedKeys {
            Self.seedGenerals(ids: ["general-morning"])
            WalkthroughSettingsStore.saveOrder([Self.calendar, Self.morning, Self.calendar, Self.voice])

            #expect(WalkthroughSettingsStore.order == [Self.calendar, Self.morning, Self.voice])
        }
    }

    @Test("a duplicate voice note block is collapsed to its first position")
    func duplicateVoiceNoteCollapses() {
        withIsolatedKeys {
            Self.seedGenerals(ids: ["general-morning"])
            WalkthroughSettingsStore.saveOrder([Self.voice, Self.morning, Self.voice, Self.calendar])

            #expect(WalkthroughSettingsStore.order == [Self.voice, Self.morning, Self.calendar])
        }
    }

    @Test("both system blocks are deduplicated independently in one plan")
    func duplicatesOfBothBlocksCollapseIndependently() {
        withIsolatedKeys {
            Self.seedGenerals(ids: ["general-morning"])
            WalkthroughSettingsStore.saveOrder([
                Self.voice, Self.calendar, Self.voice, Self.morning, Self.calendar, Self.calendar, Self.voice
            ])

            #expect(WalkthroughSettingsStore.order == [Self.voice, Self.calendar, Self.morning])
        }
    }

    @Test("missing system blocks are appended in default order")
    func missingSystemBlocksAreAppended() {
        withIsolatedKeys {
            Self.seedGenerals(ids: ["general-morning"])

            WalkthroughSettingsStore.saveOrder([])
            #expect(WalkthroughSettingsStore.order == [Self.calendar, Self.voice])

            WalkthroughSettingsStore.saveOrder([Self.morning])
            #expect(WalkthroughSettingsStore.order == [Self.morning, Self.calendar, Self.voice])

            WalkthroughSettingsStore.saveOrder([Self.voice, Self.morning])
            #expect(WalkthroughSettingsStore.order == [Self.voice, Self.morning, Self.calendar])

            WalkthroughSettingsStore.saveOrder([Self.calendar, Self.morning])
            #expect(WalkthroughSettingsStore.order == [Self.calendar, Self.morning, Self.voice])
        }
    }

    // MARK: fresh reads and stored bytes

    @Test("repeated fresh reads of a repaired plan return the same sequence")
    func repeatedReadsAreStable() {
        withIsolatedKeys {
            Self.seedGenerals(ids: ["general-morning"])
            WalkthroughSettingsStore.saveOrder([Self.evening, Self.voice, Self.voice, Self.morning])
            let expected = [Self.voice, Self.morning, Self.calendar]

            for _ in 0..<3 {
                #expect(WalkthroughSettingsStore.order == expected)
            }
        }
    }

    @Test("saving stores the given order as-is without repairing it")
    func saveOrderStoresUnrepairedInput() throws {
        try withIsolatedKeys {
            let saved = [Self.evening, Self.calendar, Self.calendar]
            WalkthroughSettingsStore.saveOrder(saved)

            let stored = try #require(Self.rawBytes(Self.orderKey))
            #expect(try JSONDecoder().decode([WalkthroughSection].self, from: stored) == saved)
        }
    }

    @Test("repair on read leaves the raw stored bytes of both keys untouched")
    func readDoesNotRewriteStoredBytes() throws {
        try withIsolatedKeys {
            Self.seedGenerals(ids: ["general-morning"])
            WalkthroughSettingsStore.saveOrder([Self.evening, Self.voice, Self.voice, Self.morning])
            let orderBefore = try #require(Self.rawBytes(Self.orderKey))
            let generalsBefore = try #require(Self.rawBytes(Self.generalsKey))

            let repaired = WalkthroughSettingsStore.order
            _ = WalkthroughSettingsStore.order

            #expect(repaired == [Self.voice, Self.morning, Self.calendar])
            #expect(Self.rawBytes(Self.orderKey) == orderBefore)
            #expect(Self.rawBytes(Self.generalsKey) == generalsBefore)
        }
    }

    @Test("reading the first-launch default does not write either key")
    func defaultReadWritesNothing() {
        withIsolatedKeys {
            _ = WalkthroughSettingsStore.order

            #expect(UserDefaults.standard.object(forKey: Self.orderKey) == nil)
            #expect(UserDefaults.standard.object(forKey: Self.generalsKey) == nil)
        }
    }

    // MARK: unreadable data

    @Test("unreadable order data returns the current default plan")
    func unreadableOrderReturnsDefault() {
        withIsolatedKeys {
            Self.seedGenerals(ids: ["general-morning"])
            let unreadable: [Any] = [
                Data("not json".utf8),
                Data(#"{"kind":"calendar_events"}"#.utf8),
                Data(#"[{"kind":"calendar_events"},{"kind":"mystery"}]"#.utf8),
                Data(#"[{"kind":"general"}]"#.utf8),
                "not a data object"
            ]

            for value in unreadable {
                UserDefaults.standard.set(value, forKey: Self.orderKey)
                #expect(WalkthroughSettingsStore.order == [Self.calendar, Self.voice], "stored \(value)")
            }
        }
    }

    @Test("unreadable generals data leaves no valid general references")
    func unreadableGeneralsLeaveNoGeneralReferences() {
        withIsolatedKeys {
            WalkthroughSettingsStore.saveOrder([Self.morning, Self.voice, Self.evening, Self.calendar])
            let unreadable: [Any] = [
                Data("not json".utf8),
                Data(#"[{"id":"general-morning"}]"#.utf8),
                Data(#"{"id":"general-morning"}"#.utf8),
                "not a data object"
            ]

            for value in unreadable {
                UserDefaults.standard.set(value, forKey: Self.generalsKey)
                #expect(WalkthroughSettingsStore.generals.isEmpty, "stored \(value)")
                #expect(WalkthroughSettingsStore.order == [Self.voice, Self.calendar], "stored \(value)")
            }
        }
    }

    // MARK: isolation

    private struct Abort: Error {}

    /// Plants `prior` under both keys, runs a block that overwrites them, and
    /// checks the exact prior objects (or their absence) are back afterwards.
    private func expectRestored(prior: [Any?], throwing: Bool, sourceLocation: SourceLocation = #_sourceLocation) {
        let defaults = UserDefaults.standard
        let outer = Self.keys.map { defaults.object(forKey: $0) }
        defer {
            for (key, value) in zip(Self.keys, outer) { Self.restore(value, forKey: key) }
        }
        for (key, value) in zip(Self.keys, prior) { Self.restore(value, forKey: key) }

        do {
            try withIsolatedKeys {
                for key in Self.keys {
                    #expect(defaults.object(forKey: key) == nil, sourceLocation: sourceLocation)
                }
                Self.seedGenerals(ids: ["general-morning"])
                WalkthroughSettingsStore.saveOrder([Self.morning])
                if throwing { throw Abort() }
            }
        } catch is Abort {
            #expect(throwing, sourceLocation: sourceLocation)
        } catch {
            Issue.record(error, sourceLocation: sourceLocation)
        }

        for (key, value) in zip(Self.keys, prior) {
            let restored = defaults.object(forKey: key)
            if let value {
                #expect((restored as? NSObject)?.isEqual(value) == true, "prior \(value)", sourceLocation: sourceLocation)
            } else {
                #expect(restored == nil, sourceLocation: sourceLocation)
            }
        }
    }

    @Test("the exact prior objects are restored on the normal and throwing paths")
    func restoresPriorObjects() {
        // Absent stays absent, valid data stays byte-identical, and an object
        // that is not Data is not normalised into Data.
        let valid = Data(#"[{"kind":"drive_by"}]"#.utf8)
        let priors: [[Any?]] = [
            [nil, nil],
            [Data("[]".utf8), valid],
            [Data("garbage".utf8), "sentinel"],
            [nil, valid]
        ]
        for prior in priors {
            expectRestored(prior: prior, throwing: false)
            expectRestored(prior: prior, throwing: true)
        }
    }
}
