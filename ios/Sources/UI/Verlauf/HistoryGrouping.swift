import Foundation

/// Pure day grouping + day labels for the Verlauf list. Every input the
/// old in-view code read from globals (`Calendar.current`, the real clock,
/// `AppLanguage.shared`) is an explicit parameter here, so the grouping is
/// deterministic and testable without a view.
enum HistoryGrouping {

    struct DaySection<Item> {
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
        locale: Locale
    ) -> [DaySection<Item>] {
        let groups = Dictionary(grouping: items) { item in
            calendar.startOfDay(for: sortDate(item))
        }
        return groups.keys.sorted(by: >).map { day in
            DaySection(
                dayKey: day,
                label: dayLabel(day, calendar: calendar, now: now, locale: locale),
                items: groups[day] ?? []
            )
        }
    }

    private static func dayLabel(_ day: Date, calendar: Calendar, now: Date, locale: Locale) -> String {
        let isGerman = locale.language.languageCode?.identifier == "de"
        if calendar.isDate(day, inSameDayAs: now) {
            return localized("Today", isGerman: isGerman)
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(day, inSameDayAs: yesterday) {
            return localized("Yesterday", isGerman: isGerman)
        }
        // The pattern works for both German ("Montag, 12. Mai") and English
        // ("Monday, May 12"): DateFormatter localises `EEEE / MMMM` per locale.
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = isGerman ? "EEEE, d. MMMM" : "EEEE, MMMM d"
        return formatter.string(from: day)
    }

    /// Looks the string up in the language's own `.lproj` so the label
    /// follows the injected locale, not whatever language the bundle
    /// currently resolves to. Falls back to the key, which is the English text.
    private static func localized(_ key: String, isGerman: Bool) -> String {
        guard let path = Bundle.main.path(forResource: isGerman ? "de" : "en", ofType: "lproj"),
              let lproj = Bundle(path: path) else {
            return key
        }
        return lproj.localizedString(forKey: key, value: key, table: nil)
    }
}
