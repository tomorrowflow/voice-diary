import Foundation

// Deterministic opener selection (SPEC §11.1) + DE/EN templates (§11.2 & §11.3).
// Pure logic — no AVFoundation, no network — so this whole file is unit-testable.

public enum OpenerSlot: String, Sendable {
    case firstEvent       = "first_event"
    case lastEvent        = "last_event"
    case deepWorkBlock    = "deep_work_block"
    case recurringRitual  = "recurring_ritual"
    case groupMeeting     = "group_meeting"
    case shortMeeting     = "short_meeting"
    case longMeeting      = "long_meeting"
    case external         = "external"
    case oneOnOne         = "one_on_one"
    case emptyBlock       = "empty_block"
}

public enum OpenerLanguage: String, Sendable {
    case de, en
}

public enum OpenerTemplates {

    /// SPEC §11.1 selection rule. Top-down: first match wins.
    public static func slot(
        for event: ServerCalendarEvent,
        positionInDay: PositionInDay
    ) -> OpenerSlot {
        switch positionInDay {
        case .first: return .firstEvent
        case .last:  return .lastEvent
        case .middle: break
        }
        if event.attendeeCount == 0 { return .deepWorkBlock }
        if event.is_recurring        { return .recurringRitual }
        if event.attendeeCount >= 3  { return .groupMeeting }
        if event.durationMinutes < 30 { return .shortMeeting }
        if event.durationMinutes >= 90 { return .longMeeting }
        if event.hasExternalAttendee { return .external }
        return .oneOnOne
    }

    public enum PositionInDay: Sendable {
        case first, middle, last
    }

    public static func position(of index: Int, count: Int) -> PositionInDay {
        if count <= 1 { return .first }
        if index == 0 { return .first }
        if index == count - 1 { return .last }
        return .middle
    }

    /// Render an opener for an event. Replaces `{title}`, `{time}`,
    /// `{who}`, `{time_range}`, `{duration}` placeholders.
    public static func render(
        slot: OpenerSlot,
        event: ServerCalendarEvent,
        language: OpenerLanguage = .de
    ) -> String {
        let template = templates(language)[slot] ?? fallback(language)
        var s = template
        let title = event.subject.isEmpty ? defaultTitle(language) : event.subject
        s = s.replacingOccurrences(of: "{title}", with: title)
        s = s.replacingOccurrences(of: "{time}", with: timeString(event.startDate))
        s = s.replacingOccurrences(of: "{time_range}", with: timeRange(event.startDate, event.endDate))
        s = s.replacingOccurrences(of: "{duration}", with: durationString(event.durationMinutes, language: language))
        s = s.replacingOccurrences(of: "{who}", with: event.primaryAttendeeName)
        return s
    }

    /// Special opener for empty time blocks between events.
    public static func renderEmptyBlock(
        startTime: Date,
        endTime: Date,
        language: OpenerLanguage = .de
    ) -> String {
        let tpl = templates(language)[.emptyBlock] ?? fallback(language)
        return tpl.replacingOccurrences(
            of: "{time_range}",
            with: timeRange(startTime, endTime)
        )
    }

    // MARK: - Tables

    public static let germanTemplates: [OpenerSlot: String] = [
        .firstEvent:      "Heute früh hattest du {title}. Wie ist der Tag gestartet?",
        .oneOnOne:        "Um {time} hattest du {title} mit {who}. Wie ist das gelaufen?",
        .groupMeeting:    "{title} um {time} — etwas Erwähnenswertes aus der Runde?",
        .recurringRitual: "{title} heute — was Besonderes?",
        .deepWorkBlock:   "Von {time_range} hattest du einen Block für {title}. Bist du vorangekommen?",
        .shortMeeting:    "Kurzer Termin {time} mit {who} — relevant für den Tag?",
        .longMeeting:     "{title} ging {duration} — was kam dabei raus?",
        .external:        "{title} mit {who} — wie war der Eindruck?",
        .lastEvent:       "{title} war dein letzter Termin — was nimmst du mit?",
        .emptyBlock:      "Zwischen {time_range} hattest du keinen Termin — irgendwas Wichtiges in der Zeit?",
    ]

    public static let englishTemplates: [OpenerSlot: String] = [
        .firstEvent:      "You kicked off the day with {title}. How did it get going?",
        .oneOnOne:        "At {time} you had {title} with {who}. How did it go?",
        .groupMeeting:    "{title} at {time} — anything worth noting from the room?",
        .recurringRitual: "{title} today — anything unusual?",
        .deepWorkBlock:   "You had {time_range} blocked for {title}. Did you get somewhere?",
        .shortMeeting:    "Short one at {time} with {who} — relevant to the day?",
        .longMeeting:     "{title} ran {duration} — what came out of it?",
        .external:        "{title} with {who} — what was your read?",
        .lastEvent:       "{title} was your last meeting — what are you taking away?",
        .emptyBlock:      "You had nothing scheduled between {time_range} — anything worth capturing from that?",
    ]

    private static func templates(_ lang: OpenerLanguage) -> [OpenerSlot: String] {
        lang == .de ? germanTemplates : englishTemplates
    }

    private static func fallback(_ lang: OpenerLanguage) -> String {
        lang == .de ? "{title}." : "{title}."
    }

    private static func defaultTitle(_ lang: OpenerLanguage) -> String {
        lang == .de ? "ein Termin" : "a meeting"
    }

    // MARK: - Formatting helpers

    private static func timeString(_ d: Date?) -> String {
        guard let d else { return "" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.dateFormat = "HH:mm"
        return f.string(from: d)
    }

    private static func timeRange(_ start: Date?, _ end: Date?) -> String {
        guard let start, let end else { return "" }
        return "\(timeString(start))–\(timeString(end)) Uhr"
    }

    private static func durationString(_ minutes: Int, language: OpenerLanguage) -> String {
        switch language {
        case .de:
            if minutes >= 60 { return "\(minutes / 60) Stunden" }
            return "\(minutes) Minuten"
        case .en:
            if minutes >= 60 { return "\(minutes / 60) hours" }
            return "\(minutes) minutes"
        }
    }

    /// Convenience round-trip used by the state machine.
    public static func line(
        for event: ServerCalendarEvent,
        index: Int,
        of total: Int,
        language: OpenerLanguage = .de
    ) -> String {
        let s = slot(for: event, positionInDay: position(of: index, count: total))
        return render(slot: s, event: event, language: language)
    }

    // MARK: - Follow-up rotation (SPEC §11.4)

    /// Rotation pool used when the on-device LLM isn't available or
    /// returns nothing usable. Keep these wordings deliberately broad so
    /// they fit any event.
    public static let germanFollowUps: [String] = [
        "Etwas Konkretes, das du mitnehmen willst?",
        "Irgendwas, das dich noch beschäftigt?",
        "Willst du noch einen Aspekt vertiefen?",
    ]

    public static let englishFollowUps: [String] = [
        "Anything concrete you want to keep?",
        "Anything still on your mind?",
        "Any angle you want to dig into?",
    ]

    /// Pick a follow-up template by simple rotation on a counter the
    /// caller maintains. Prevents two consecutive identical prompts.
    public static func followUp(language: OpenerLanguage, rotation: Int) -> String {
        let pool = language == .de ? germanFollowUps : englishFollowUps
        let i = ((rotation % pool.count) + pool.count) % pool.count
        return pool[i]
    }
}
