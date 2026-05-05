import Foundation

// User-tunable knobs for the evening walkthrough. Two layers:
//
//   1. Event filters — which calendar events flow into the per-event loop.
//      (Defaults: only accepted, timed events; matches SPEC §6.)
//   2. Section plan — the ordered list of walkthrough sections.
//      Three section kinds: user-defined `general` openers, the singleton
//      `calendarEvents` block (per-event loop), and the singleton `driveBy`
//      block (closing free reflection + surfaced drive-by seeds).
//      Default order = [calendarEvents, driveBy], i.e. the original
//      behaviour with no general sections defined.
//
// Both layers persist via `UserDefaults` and are read fresh on every
// `previewDay` / `begin` call.

// MARK: - Event filters --------------------------------------------------

public struct WalkthroughSettings: Sendable {
    public var includeAllDay: Bool
    public var includeTentative: Bool
    public var includeNotAccepted: Bool

    public static let `default` = WalkthroughSettings(
        includeAllDay: false,
        includeTentative: false,
        includeNotAccepted: false
    )
}

public extension Array where Element == ServerCalendarEvent {
    /// Drop events the user hasn't opted into. Default = accepted timed
    /// events only.
    func filtered(by settings: WalkthroughSettings) -> [ServerCalendarEvent] {
        filter { event in
            if event.is_all_day && !settings.includeAllDay { return false }
            switch event.rsvp_status {
            case "accepted", "organizer":
                return true
            case "tentative":
                return settings.includeTentative
            default:
                return settings.includeNotAccepted
            }
        }
    }
}

// MARK: - Section plan ---------------------------------------------------

/// One named opener the user adds (e.g. "Morgenroutine" with intro
/// "Wie ist dein Morgen heute angekommen?"). The id is stable across
/// reorders so the manifest can attribute transcripts back to the same
/// section across multiple sessions.
public struct GeneralSection: Codable, Sendable, Identifiable, Equatable {
    public var id: String                 // UUID string, stable
    public var title: String              // shown in the header during walkthrough
    public var introText: String          // spoken via TTS at section start

    public init(id: String = UUID().uuidString, title: String, introText: String) {
        self.id = id
        self.title = title
        self.introText = introText
    }
}

/// Ordered entry in the walkthrough plan. The `general` case carries the
/// section's id (the body is looked up in `WalkthroughSettingsStore.generals`)
/// so reorders never duplicate the title/intro payload.
public enum WalkthroughSection: Codable, Sendable, Equatable, Identifiable {
    case general(id: String)
    case calendarEvents
    case driveBy

    public var id: String {
        switch self {
        case .general(let id):  return "general:\(id)"
        case .calendarEvents:   return "system:calendarEvents"
        case .driveBy:          return "system:driveBy"
        }
    }

    /// JSON shape: `{ "kind": "general|calendar_events|drive_by", "id": "<uuid>"? }`.
    /// Custom encoding keeps the file readable and forward-compatible.
    private enum CodingKeys: String, CodingKey { case kind, id }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(String.self, forKey: .kind)
        switch kind {
        case "general":
            let id = try c.decode(String.self, forKey: .id)
            self = .general(id: id)
        case "calendar_events":
            self = .calendarEvents
        case "drive_by":
            self = .driveBy
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .kind, in: c,
                debugDescription: "unknown section kind \(kind)"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .general(let id):
            try c.encode("general", forKey: .kind)
            try c.encode(id, forKey: .id)
        case .calendarEvents:
            try c.encode("calendar_events", forKey: .kind)
        case .driveBy:
            try c.encode("drive_by", forKey: .kind)
        }
    }
}

// MARK: - Persistence ----------------------------------------------------

/// Thin `UserDefaults` shim. Read/written directly so the settings
/// surface in MehrView stays a few lines of toggles + two list views.
public enum WalkthroughSettingsStore {
    private static let allDayKey      = "walkthrough.includeAllDay"
    private static let tentativeKey   = "walkthrough.includeTentative"
    private static let notAcceptedKey = "walkthrough.includeNotAccepted"
    private static let generalsKey    = "walkthrough.generals.v1"
    private static let orderKey       = "walkthrough.sectionOrder.v1"

    // --- event filters ---------------------------------------------------

    public static var current: WalkthroughSettings {
        let d = UserDefaults.standard
        return WalkthroughSettings(
            includeAllDay:      d.bool(forKey: allDayKey),
            includeTentative:   d.bool(forKey: tentativeKey),
            includeNotAccepted: d.bool(forKey: notAcceptedKey)
        )
    }

    public static func setIncludeAllDay(_ value: Bool)      { UserDefaults.standard.set(value, forKey: allDayKey) }
    public static func setIncludeTentative(_ value: Bool)   { UserDefaults.standard.set(value, forKey: tentativeKey) }
    public static func setIncludeNotAccepted(_ value: Bool) { UserDefaults.standard.set(value, forKey: notAcceptedKey) }

    // --- general sections ------------------------------------------------

    public static var generals: [GeneralSection] {
        guard let data = UserDefaults.standard.data(forKey: generalsKey),
              let decoded = try? JSONDecoder().decode([GeneralSection].self, from: data)
        else { return [] }
        return decoded
    }

    public static func saveGenerals(_ generals: [GeneralSection]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(generals) else { return }
        UserDefaults.standard.set(data, forKey: generalsKey)
        // After a delete, prune any orphan section refs from the order.
        let validIDs = Set(generals.map(\.id))
        let pruned = order.filter { section in
            switch section {
            case .general(let id): return validIDs.contains(id)
            case .calendarEvents, .driveBy: return true
            }
        }
        saveOrder(pruned)
    }

    /// Convenience: insert/update a single general section. New ones land
    /// at the end of the order, just before driveBy if present.
    public static func upsertGeneral(_ section: GeneralSection) {
        var current = generals
        if let i = current.firstIndex(where: { $0.id == section.id }) {
            current[i] = section
            saveGenerals(current)
        } else {
            current.append(section)
            saveGenerals(current)
            insertGeneralIntoOrderBeforeDriveBy(section.id)
        }
    }

    public static func deleteGeneral(id: String) {
        saveGenerals(generals.filter { $0.id != id })
    }

    // --- section order ---------------------------------------------------

    /// The persisted plan, repaired against the current `generals` list:
    ///   * any `.general` whose body has been deleted is dropped;
    ///   * `.calendarEvents` / `.driveBy` are guaranteed to appear once
    ///     each (appended in default order if missing) so the user can
    ///     never lock themselves out of either system block.
    public static var order: [WalkthroughSection] {
        let stored = loadStoredOrder()
        let generalIDs = Set(generals.map(\.id))
        var out: [WalkthroughSection] = []
        var seenCalendar = false
        var seenDriveBy = false
        for s in stored {
            switch s {
            case .general(let id):
                guard generalIDs.contains(id) else { continue }
                out.append(s)
            case .calendarEvents:
                guard !seenCalendar else { continue }
                seenCalendar = true
                out.append(s)
            case .driveBy:
                guard !seenDriveBy else { continue }
                seenDriveBy = true
                out.append(s)
            }
        }
        if !seenCalendar { out.append(.calendarEvents) }
        if !seenDriveBy  { out.append(.driveBy) }
        return out
    }

    public static func saveOrder(_ order: [WalkthroughSection]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(order) else { return }
        UserDefaults.standard.set(data, forKey: orderKey)
    }

    private static func loadStoredOrder() -> [WalkthroughSection] {
        guard let data = UserDefaults.standard.data(forKey: orderKey),
              let decoded = try? JSONDecoder().decode([WalkthroughSection].self, from: data)
        else {
            // First launch / migration: existing behaviour is calendar
            // first, then closing free reflection.
            return [.calendarEvents, .driveBy]
        }
        return decoded
    }

    private static func insertGeneralIntoOrderBeforeDriveBy(_ id: String) {
        var current = order
        let entry: WalkthroughSection = .general(id: id)
        if let driveByIdx = current.firstIndex(of: .driveBy) {
            current.insert(entry, at: driveByIdx)
        } else {
            current.append(entry)
        }
        saveOrder(current)
    }
}
