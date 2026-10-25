import Foundation

/// Pure day grouping + day labels for the Verlauf list. Every input the
/// old in-view code read from globals (`Calendar.current`, the real clock,
/// `AppLanguage.shared`) is an explicit parameter here, so the grouping is
/// deterministic and testable without a view.
enum HistoryGrouping {

    struct Section<Item> {
        /// Start of the local day — also the section's identity.
        let dayKey: Date
        let label: String
        let items: [Item]
    }

    /// Groups `items` by the local day of `sortDate` (per `calendar`),
    /// newest day first. Items keep their input order within a day.
    /// `locale` picks the Today/Yesterday strings and the date format;
    /// `now` decides what counts as today and yesterday.
    static func group<Item>(
        _ items: [Item],
        sortDate: (Item) -> Date,
        calendar: Calendar,
        now: Date,
        locale: Locale,
        bundle: Bundle = .main
    ) -> [Section<Item>] {
        let groups = Dictionary(grouping: items) { item in
            calendar.startOfDay(for: sortDate(item))
        }
        return groups.keys.sorted(by: >).map { day in
            Section(
                dayKey: day,
                label: dayLabel(day, calendar: calendar, now: now, locale: locale, bundle: bundle),
                items: groups[day] ?? []
            )
        }
    }

    private static func dayLabel(
        _ day: Date,
        calendar: Calendar,
        now: Date,
        locale: Locale,
        bundle: Bundle = .main
    ) -> String {
        if calendar.isDate(day, inSameDayAs: now) {
            return localized("Today", locale: locale, bundle: bundle)
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(day, inSameDayAs: yesterday) {
            return localized("Yesterday", locale: locale, bundle: bundle)
        }
        return dayFormatter(calendar: calendar, locale: locale).string(from: day)
    }

    // The pattern works for both German ("Montag, 12. Mai") and English
    // ("Monday, May 12"): DateFormatter localises `EEEE / MMMM` per locale.
    private static func dayFormatter(calendar: Calendar, locale: Locale) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = locale
        formatter.dateFormat = isGerman(locale) ? "EEEE, d. MMMM" : "EEEE, MMMM d"
        return formatter
    }

    private static func isGerman(_ locale: Locale) -> Bool {
        locale.language.languageCode?.identifier == "de"
    }

    /// Looks the string up in the locale's own `.lproj` so the label follows
    /// the injected locale, not whatever language the bundle currently
    /// resolves to. Falls back to the key, which is the English text.
    private static func localized(_ key: String, locale: Locale, bundle: Bundle) -> String {
        let code = isGerman(locale) ? "de" : "en"
        guard let path = bundle.path(forResource: code, ofType: "lproj"),
              let lproj = Bundle(path: path) else {
            return key
        }
        return lproj.localizedString(forKey: key, value: key, table: nil)
    }
}
