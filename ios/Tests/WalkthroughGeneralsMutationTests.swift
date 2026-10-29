import Foundation
import Testing
@testable import VoiceDiary

/// These tests write the real `UserDefaults.standard` keys
/// `walkthrough.generals.v1` and `walkthrough.sectionOrder.v1`, so the suite is
/// serialized, touches only those two keys (never the filter or speech keys),
/// and restores their exact prior objects afterwards (removing a key when it
/// was originally absent). No defaults domain is ever reset.
///
/// The stored order is asserted as raw JSON as well as through the repaired
/// `order` read, so read-time repair cannot hide a missing persisted prune.
@Suite("WalkthroughSettingsStore general-section mutations", .serialized)
struct WalkthroughGeneralsMutationTests {

    /// Pinned independently of the implementation: renaming either key would
    /// silently drop every user's saved sections or their order.
    private static let generalsKey = "walkthrough.generals.v1"
    private static let orderKey = "walkthrough.sectionOrder.v1"

    private static let alpha = GeneralSection(id: "g-alpha", title: "Morning", introText: "How did you sleep?")
    private static let beta = GeneralSection(id: "g-beta", title: "Work", introText: "What is on today?", followUpEnabled: true)
    private static let gamma = GeneralSection(id: "g-gamma", title: "Evening", introText: "What went well?")

    private static let alphaEntry = #"{"id":"g-alpha","kind":"general"}"#
    private static let betaEntry = #"{"id":"g-beta","kind":"general"}"#
    private static let gammaEntry = #"{"id":"g-gamma","kind":"general"}"#
    private static let calendarEntry = #"{"kind":"calendar_events"}"#
    private static let voiceNoteEntry = #"{"kind":"drive_by"}"#

    private static func orderJSON(_ entries: String...) -> String {
        "[" + entries.joined(separator: ",") + "]"
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
        let keys = [Self.generalsKey, Self.orderKey]
        let previous = keys.map { defaults.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, previous) { Self.restore(value, forKey: key) }
        }
        for key in keys { defaults.removeObject(forKey: key) }
        try body()
    }

    /// Plants the saved sections and a literal stored order.
    private static func seed(_ generals: [GeneralSection], storedOrder: String) {
        WalkthroughSettingsStore.saveGenerals(generals)
        UserDefaults.standard.set(Data(storedOrder.utf8), forKey: orderKey)
    }

    private static func storedJSON(forKey key: String) -> String? {
        UserDefaults.standard.data(forKey: key).map { String(decoding: $0, as: UTF8.self) }
    }

    // MARK: saveGenerals round trip

    @Test("several sections round-trip through the pinned key with every field")
    func roundTripsMultipleSections() throws {
        try withIsolatedKeys {
            let sections = [Self.alpha, Self.beta, Self.gamma]
            WalkthroughSettingsStore.saveGenerals(sections)

            #expect(WalkthroughSettingsStore.generals == sections)

            let data = try #require(UserDefaults.standard.data(forKey: Self.generalsKey))
            let raw = try #require(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
            #expect(raw.count == 3)
            #expect(raw[1]["id"] as? String == "g-beta")
            #expect(raw[1]["title"] as? String == "Work")
            #expect(raw[1]["introText"] as? String == "What is on today?")
            #expect(raw[1]["followUpEnabled"] as? Bool == true)
            #expect(raw[0]["followUpEnabled"] as? Bool == false)
        }
    }

    @Test("saving a new list replaces the previous one")
    func saveReplacesPreviousList() {
        withIsolatedKeys {
            WalkthroughSettingsStore.saveGenerals([Self.alpha, Self.beta])
            WalkthroughSettingsStore.saveGenerals([Self.gamma, Self.alpha])

            #expect(WalkthroughSettingsStore.generals == [Self.gamma, Self.alpha])
        }
    }

    @Test("an empty saved list reads as empty")
    func emptyListReadsEmpty() {
        withIsolatedKeys {
            WalkthroughSettingsStore.saveGenerals([Self.alpha])
            WalkthroughSettingsStore.saveGenerals([])

            #expect(Self.storedJSON(forKey: Self.generalsKey) == "[]")
            #expect(WalkthroughSettingsStore.generals.isEmpty)
        }
    }

    // MARK: upsertGeneral

    @Test("a new id is appended and ordered immediately before the voice note")
    func upsertNewIDInsertsBeforeVoiceNote() {
        withIsolatedKeys {
            Self.seed(
                [Self.alpha, Self.beta],
                storedOrder: Self.orderJSON(Self.alphaEntry, Self.calendarEntry, Self.betaEntry, Self.voiceNoteEntry)
            )

            WalkthroughSettingsStore.upsertGeneral(Self.gamma)

            #expect(WalkthroughSettingsStore.generals == [Self.alpha, Self.beta, Self.gamma])
            #expect(Self.storedJSON(forKey: Self.orderKey) == Self.orderJSON(
                Self.alphaEntry, Self.calendarEntry, Self.betaEntry, Self.gammaEntry, Self.voiceNoteEntry
            ))
            #expect(WalkthroughSettingsStore.order == [
                .general(id: "g-alpha"), .calendarEvents, .general(id: "g-beta"),
                .general(id: "g-gamma"), .voiceNote,
            ])
        }
    }

    @Test("the first section lands before the voice note in the default plan")
    func upsertFirstSectionUsesDefaultPlan() {
        withIsolatedKeys {
            WalkthroughSettingsStore.upsertGeneral(Self.alpha)

            #expect(WalkthroughSettingsStore.generals == [Self.alpha])
            #expect(Self.storedJSON(forKey: Self.orderKey) == Self.orderJSON(
                Self.calendarEntry, Self.alphaEntry, Self.voiceNoteEntry
            ))
        }
    }

    @Test("an existing id is replaced in place without touching the order")
    func upsertExistingIDReplacesInPlace() {
        withIsolatedKeys {
            let storedOrder = Self.orderJSON(Self.betaEntry, Self.calendarEntry, Self.alphaEntry, Self.voiceNoteEntry)
            Self.seed([Self.alpha, Self.beta, Self.gamma], storedOrder: storedOrder)
            let edited = GeneralSection(id: "g-beta", title: "Work (edited)", introText: "New intro", followUpEnabled: false)

            WalkthroughSettingsStore.upsertGeneral(edited)

            #expect(WalkthroughSettingsStore.generals == [Self.alpha, edited, Self.gamma])
            #expect(WalkthroughSettingsStore.generals.count == 3)
            #expect(Self.storedJSON(forKey: Self.orderKey) == Self.orderJSON(
                Self.betaEntry, Self.calendarEntry, Self.alphaEntry, Self.voiceNoteEntry
            ))
            #expect(WalkthroughSettingsStore.order.filter { $0 == .general(id: "g-beta") }.count == 1)
        }
    }

    // MARK: deleteGeneral

    @Test("deleting one id removes its body and order entry and keeps the rest")
    func deleteRemovesOnlyTheNamedSection() {
        withIsolatedKeys {
            Self.seed(
                [Self.alpha, Self.beta, Self.gamma],
                storedOrder: Self.orderJSON(
                    Self.alphaEntry, Self.betaEntry, Self.calendarEntry, Self.gammaEntry, Self.voiceNoteEntry
                )
            )

            WalkthroughSettingsStore.deleteGeneral(id: "g-beta")

            #expect(WalkthroughSettingsStore.generals == [Self.alpha, Self.gamma])
            #expect(Self.storedJSON(forKey: Self.orderKey) == Self.orderJSON(
                Self.alphaEntry, Self.calendarEntry, Self.gammaEntry, Self.voiceNoteEntry
            ))
            #expect(WalkthroughSettingsStore.order == [
                .general(id: "g-alpha"), .calendarEvents, .general(id: "g-gamma"), .voiceNote,
            ])
        }
    }

    @Test("deleting the last section leaves only the system blocks")
    func deleteLastSectionKeepsSystemBlocks() {
        withIsolatedKeys {
            Self.seed(
                [Self.alpha],
                storedOrder: Self.orderJSON(Self.voiceNoteEntry, Self.alphaEntry, Self.calendarEntry)
            )

            WalkthroughSettingsStore.deleteGeneral(id: "g-alpha")

            #expect(WalkthroughSettingsStore.generals.isEmpty)
            #expect(Self.storedJSON(forKey: Self.generalsKey) == "[]")
            #expect(Self.storedJSON(forKey: Self.orderKey) == Self.orderJSON(Self.voiceNoteEntry, Self.calendarEntry))
            #expect(WalkthroughSettingsStore.order == [.voiceNote, .calendarEvents])
        }
    }

    @Test("deleting an unknown id leaves the logical plan unchanged")
    func deleteUnknownIDIsANoOp() {
        withIsolatedKeys {
            let storedOrder = Self.orderJSON(Self.alphaEntry, Self.calendarEntry, Self.betaEntry, Self.voiceNoteEntry)
            Self.seed([Self.alpha, Self.beta], storedOrder: storedOrder)
            let orderBefore = WalkthroughSettingsStore.order

            WalkthroughSettingsStore.deleteGeneral(id: "g-missing")

            #expect(WalkthroughSettingsStore.generals == [Self.alpha, Self.beta])
            #expect(WalkthroughSettingsStore.order == orderBefore)
            #expect(Self.storedJSON(forKey: Self.orderKey) == storedOrder)
        }
    }

    // MARK: exact restoration

    private struct Abort: Error {}

    /// Plants priors under both keys, runs a block that mutates them through
    /// the store, and checks each exact prior object (or its absence) is back.
    private func expectRestored(
        generalsPrior: Any?, orderPrior: Any?, throwing: Bool,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let defaults = UserDefaults.standard
        let keys = [Self.generalsKey, Self.orderKey]
        let outer = keys.map { defaults.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, outer) { Self.restore(value, forKey: key) }
        }
        Self.restore(generalsPrior, forKey: Self.generalsKey)
        Self.restore(orderPrior, forKey: Self.orderKey)

        do {
            try withIsolatedKeys {
                for key in keys { #expect(defaults.object(forKey: key) == nil, sourceLocation: sourceLocation) }
                WalkthroughSettingsStore.upsertGeneral(Self.alpha)
                WalkthroughSettingsStore.deleteGeneral(id: "g-alpha")
                WalkthroughSettingsStore.upsertGeneral(Self.beta)
                if throwing { throw Abort() }
            }
        } catch is Abort {
            #expect(throwing, sourceLocation: sourceLocation)
        } catch {
            Issue.record(error, sourceLocation: sourceLocation)
        }

        for (key, prior) in zip(keys, [generalsPrior, orderPrior]) {
            let restored = defaults.object(forKey: key)
            if let prior {
                #expect((restored as? NSObject)?.isEqual(prior) == true, "\(key) prior \(prior)", sourceLocation: sourceLocation)
            } else {
                #expect(restored == nil, "\(key) absent", sourceLocation: sourceLocation)
            }
        }
    }

    @Test("the exact prior objects are restored on the normal and throwing paths")
    func restoresPriorObjects() {
        // Real JSON data, absent keys and a non-Data object must all come back
        // untouched; a non-Data object is not normalised into Data.
        let priors: [Any?] = [Data(#"[{"id":"p","title":"T","introText":"I"}]"#.utf8), nil, "sentinel"]
        for generalsPrior in priors {
            for orderPrior in priors {
                expectRestored(generalsPrior: generalsPrior, orderPrior: orderPrior, throwing: false)
                expectRestored(generalsPrior: generalsPrior, orderPrior: orderPrior, throwing: true)
            }
        }
    }
}
