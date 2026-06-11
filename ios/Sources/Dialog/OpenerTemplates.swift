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

    /// Snapshot of the user's current language preference (the toggle in
    /// "Mehr → Sprache"). Centralising the call here means every default
    /// argument in the coordinator + opener pipeline reads from one
    /// place. `LanguageDetector` still overrides per event title.
    @MainActor
    public static var current: OpenerLanguage {
        AppLanguage.shared.isGerman ? .de : .en
    }
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
        s = s.replacingOccurrences(of: "{time}", with: spokenTime(event.startDate, language: language))
        s = s.replacingOccurrences(of: "{time_range}", with: spokenTimeRange(event.startDate, event.endDate, language: language))
        s = s.replacingOccurrences(of: "{duration}", with: spokenDuration(event.durationMinutes, language: language))
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
            with: spokenTimeRange(startTime, endTime, language: language)
        )
    }

    // MARK: - Tables

    public static let germanTemplates: [OpenerSlot: String] = [
        .firstEvent:      "Heute früh hattest du {title}. Wie ist der Tag gestartet?",
        .oneOnOne:        "Um {time} hattest du {title} mit {who}. Wie ist das gelaufen?",
        .groupMeeting:    "{title} um {time} — etwas Erwähnenswertes aus der Runde?",
        .recurringRitual: "{title} heute — war etwas Besonderes dabei?",
        .deepWorkBlock:   "Von {time_range} hattest du einen Block für {title}. Bist du vorangekommen?",
        .shortMeeting:    "Kurzer Termin um {time} mit {who} — relevant für den Tag?",
        .longMeeting:     "{title} ging {duration} — was kam dabei raus?",
        .external:        "{title} mit {who} — wie war der Eindruck?",
        .lastEvent:       "{title} war dein letzter Termin — was nimmst du mit?",
        .emptyBlock:      "Von {time_range} hattest du keinen Termin — irgendwas Wichtiges in der Zeit?",
    ]

    public static let englishTemplates: [OpenerSlot: String] = [
        .firstEvent:      "You kicked off the day with {title}. How did it get going?",
        .oneOnOne:        "At {time} you had {title} with {who}. How did it go?",
        .groupMeeting:    "{title} at {time} — anything worth noting from the room?",
        .recurringRitual: "{title} today — anything unusual about it?",
        .deepWorkBlock:   "You had {time_range} blocked for {title}. Did you get somewhere?",
        .shortMeeting:    "Short one at {time} with {who} — relevant to the day?",
        .longMeeting:     "{title} ran {duration} — what came out of it?",
        .external:        "{title} with {who} — what was your read?",
        .lastEvent:       "{title} was your last meeting — what are you taking away?",
        .emptyBlock:      "From {time_range} you had nothing scheduled — anything worth capturing from that?",
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

    // MARK: - Spoken-time formatting (Voxtral-safe)
    //
    // A digital clock time like "10:00" makes Voxtral glitch — the colon
    // and zero-padded digits read as garbage. We never emit that form.
    // Instead we speak the time the way a person would say it:
    //   DE point : "10 Uhr"        / "10 Uhr 30"
    //   DE range : "10 bis 11 Uhr" / "10 Uhr 15 bis 11 Uhr 45"
    //   EN point : "ten"           / "ten thirty" / "ten oh five"
    //   EN range : "ten to eleven"
    // The range is deliberately *bare* (no leading "von"/"from"): the
    // templates already supply the preposition ("Von {time_range}",
    // "Zwischen {time_range}"), so embedding one here would double it up.
    // These helpers are public so the dialog LLM opener prompt can be
    // seeded with the exact spoken string, guaranteeing the model has a
    // glitch-free time to reuse verbatim.

    public static func spokenTime(_ d: Date?, language: OpenerLanguage = .de) -> String {
        guard let d else { return "" }
        let (h, m) = hourMinute(d)
        switch language {
        case .de:
            return m == 0 ? "\(h) Uhr" : "\(h) Uhr \(m)"
        case .en:
            let hw = spelledOut(h, language: "en")
            if m == 0 { return hw }
            if m < 10 { return "\(hw) oh \(spelledOut(m, language: "en"))" }
            return "\(hw) \(spelledOut(m, language: "en"))"
        }
    }

    public static func spokenTimeRange(
        _ start: Date?,
        _ end: Date?,
        language: OpenerLanguage = .de
    ) -> String {
        guard let start, let end else { return "" }
        let (_, m1) = hourMinute(start)
        let (_, m2) = hourMinute(end)
        switch language {
        case .de:
            // "10 bis 11 Uhr" reads cleanly only when both ends land on
            // the hour; otherwise spell each side fully so the minutes
            // don't get orphaned ("10 Uhr 15 bis 11 Uhr 45").
            if m1 == 0 && m2 == 0 {
                let (h1, _) = hourMinute(start)
                let (h2, _) = hourMinute(end)
                return "\(h1) bis \(h2) Uhr"
            }
            return "\(spokenTime(start, language: .de)) bis \(spokenTime(end, language: .de))"
        case .en:
            return "\(spokenTime(start, language: .en)) to \(spokenTime(end, language: .en))"
        }
    }

    public static func spokenDuration(_ minutes: Int, language: OpenerLanguage) -> String {
        let h = minutes / 60
        let m = minutes % 60
        switch language {
        case .de:
            if h == 0 { return "\(m) Minuten" }
            let hours = h == 1 ? "eine Stunde" : "\(h) Stunden"
            return m == 0 ? hours : "\(hours) \(m) Minuten"
        case .en:
            if h == 0 { return "\(m) minutes" }
            let hours = h == 1 ? "one hour" : "\(h) hours"
            return m == 0 ? hours : "\(hours) \(m) minutes"
        }
    }

    // MARK: - Formatting helpers

    private static func hourMinute(_ d: Date) -> (Int, Int) {
        let c = Calendar.current.dateComponents([.hour, .minute], from: d)
        return (c.hour ?? 0, c.minute ?? 0)
    }

    private static func spelledOut(_ n: Int, language: String) -> String {
        let f = NumberFormatter()
        f.numberStyle = .spellOut
        f.locale = Locale(identifier: language == "en" ? "en_US" : "de_DE")
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
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

    // MARK: - Script-style rendering (mixed-language voice routing)

    /// Render an opener as a sequence of language-tagged spans. Each
    /// `{title}` / `{who}` placeholder whose value reads as a *different*
    /// language from the surrounding template is emitted as its own span
    /// so `WalkthroughCoordinator.speak(script:)` can route it to the
    /// matching voice.
    ///
    /// When `mixedLanguage` is false, every span gets the template's
    /// language — collapses back to the legacy single-voice path.
    public static func script(
        slot: OpenerSlot,
        event: ServerCalendarEvent,
        language: OpenerLanguage = .de,
        mixedLanguage: Bool = WalkthroughSettingsStore.mixedLanguageSpeech
    ) -> [SpokenSpan] {
        let template = templates(language)[slot] ?? fallback(language)
        let baseLang = language.rawValue

        // Substitute non-foreign-leaking placeholders (time/range/duration)
        // first — these never trigger a voice switch, so doing them up
        // front leaves only {title}/{who} as potential split points.
        var pre = template
        pre = pre.replacingOccurrences(of: "{time}", with: spokenTime(event.startDate, language: language))
        pre = pre.replacingOccurrences(of: "{time_range}", with: spokenTimeRange(event.startDate, event.endDate, language: language))
        pre = pre.replacingOccurrences(of: "{duration}", with: spokenDuration(event.durationMinutes, language: language))

        let title = event.subject.isEmpty ? defaultTitle(language) : event.subject
        let who = event.primaryAttendeeName

        let titleLang = mixedLanguage
            ? (LanguageDetector.detect(title) ?? baseLang)
            : baseLang
        let whoLang = mixedLanguage
            ? (LanguageDetector.detect(who) ?? baseLang)
            : baseLang

        // Walk the template once, emitting a span every time we cross a
        // placeholder. The span's language is the surrounding template's
        // language; the placeholder span's language is the detected one.
        var spans: [SpokenSpan] = []
        var cursor = pre.startIndex

        // Order-stable scan: find earliest placeholder occurrence each step.
        let markers: [(token: String, value: String, lang: String)] = [
            ("{title}", title, titleLang),
            ("{who}",   who,   whoLang),
        ]

        while cursor < pre.endIndex {
            // Find the next placeholder occurrence.
            let candidates = markers.compactMap { marker -> (Range<String.Index>, (String, String, String))? in
                guard let r = pre.range(of: marker.token, range: cursor..<pre.endIndex) else { return nil }
                return (r, marker)
            }
            guard let next = candidates.min(by: { $0.0.lowerBound < $1.0.lowerBound }) else {
                // No more placeholders — emit the trailing tail in baseLang.
                let tail = String(pre[cursor..<pre.endIndex])
                spans.append(SpokenSpan(text: tail, language: baseLang))
                break
            }
            let (range, marker) = next
            // Lead-in fragment in baseLang, then the placeholder value
            // in its detected language.
            let lead = String(pre[cursor..<range.lowerBound])
            spans.append(SpokenSpan(text: lead, language: baseLang))
            spans.append(SpokenSpan(text: marker.1, language: marker.2))
            cursor = range.upperBound
        }

        return spans.coalesced()
    }

    /// Convenience: pick the slot from the day position and emit spans.
    public static func scriptLine(
        for event: ServerCalendarEvent,
        index: Int,
        of total: Int,
        language: OpenerLanguage = .de,
        mixedLanguage: Bool = WalkthroughSettingsStore.mixedLanguageSpeech
    ) -> [SpokenSpan] {
        let s = slot(for: event, positionInDay: position(of: index, count: total))
        return script(slot: s, event: event, language: language, mixedLanguage: mixedLanguage)
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

    /// Spoken at the 15 s lull *when the user has stayed completely
    /// silent* since the opener (SPEC §6.7). It accompanies the
    /// still-open wake-word window: the user can say "weiter" / "fertig"
    /// ("next" / "done") to move on, or simply start talking to keep
    /// reflecting. One fixed line per language — unlike `followUp` there
    /// is no rotation because it fires at most once per silent segment.
    /// Deliberately quote-free so Piper reads it cleanly.
    public static func continuePrompt(language: OpenerLanguage) -> String {
        switch language {
        case .de: return "Soll ich weitermachen? Sag weiter, oder fang einfach an zu erzählen."
        case .en: return "Should I move on? Say next, or just start talking."
        }
    }

    /// Closing prompt for the voice-note / free-reflection section
    /// (SPEC §6 CLOSING state). Appears at three distinct call sites in
    /// `WalkthroughCoordinator` and is also pre-fetched for TTS caching.
    /// All three uses MUST produce byte-identical strings so the TTS
    /// prefetch cache key is stable — centralised here to prevent silent
    /// divergence from a copy-paste edit.
    public static func closingPrompt(language: OpenerLanguage) -> String {
        switch language {
        case .de: return "Willst du noch etwas zum ganzen Tag sagen?"
        case .en: return "Anything else you want to say about the day overall?"
        }
    }
}
