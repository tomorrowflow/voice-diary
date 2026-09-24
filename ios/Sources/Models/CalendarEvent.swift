import Foundation

// Mirrors the server's `/today/calendar` response shape (see
// `server/webapp/routers/calendar.py::CalendarEvent`). The walkthrough
// reads these straight from the API; opener selection is computed
// locally on-device per SPEC §11.1.

public struct ServerAttendee: Codable, Sendable, Hashable {
    public var name: String
    public var email: String

    public init(name: String = "", email: String = "") {
        self.name = name
        self.email = email
    }
}

public struct ServerCalendarEvent: Codable, Sendable, Identifiable {
    public var graph_event_id: String
    public var subject: String
    public var start: String
    public var end: String
    public var is_all_day: Bool
    public var show_as: String
    public var rsvp_status: String
    public var organizer: ServerAttendee
    public var attendees: [ServerAttendee]
    public var body_preview: String
    public var is_recurring: Bool
    public var web_link: String

    public var id: String { graph_event_id }

    /// Best-effort ISO-8601 → Date. Returns `nil` for malformed input.
    public var startDate: Date? { Self.parseISO(start) }
    public var endDate: Date? { Self.parseISO(end) }

    public var durationMinutes: Int {
        guard let s = startDate, let e = endDate else { return 0 }
        return Int(max(0, e.timeIntervalSince(s)) / 60.0)
    }

    public var attendeeCount: Int { attendees.count }

    /// External attendees are ones whose email domain differs from the
    /// organizer's. Cheap heuristic — good enough for the opener rule.
    public var hasExternalAttendee: Bool {
        let host = organizer.email.split(separator: "@").last.map(String.init) ?? ""
        guard !host.isEmpty else { return false }
        return attendees.contains { att in
            let dom = att.email.split(separator: "@").last.map(String.init) ?? ""
            return !dom.isEmpty && dom != host
        }
    }

    public var primaryAttendeeName: String {
        attendees.first { $0.email != organizer.email }?.name
        ?? attendees.first?.name
        ?? organizer.name
    }

    private static func parseISO(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}

public struct TodayCalendarResponse: Codable, Sendable {
    public var date: String
    public var rsvp_filter: [String]
    public var events: [ServerCalendarEvent]
}
