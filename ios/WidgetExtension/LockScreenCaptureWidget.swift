import SwiftUI
import WidgetKit

// Lock-screen widget: tap to start a drive-by capture. Reads the shared
// "is recording" state from the App Group so the icon flips red while a
// capture is in flight.

struct LockScreenCaptureWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: "com.tomorrowflow.voice-diary.lockscreen",
            provider: CaptureWidgetTimelineProvider()
        ) { entry in
            CaptureWidgetView(entry: entry)
        }
        .configurationDisplayName("Voice Diary")
        .description("Tippen, um einen Drive-by-Gedanken aufzunehmen.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

struct CaptureWidgetEntry: TimelineEntry {
    let date: Date
    let isRecording: Bool
    let recordingStartedAt: Date?
}

struct CaptureWidgetTimelineProvider: TimelineProvider {
    typealias Entry = CaptureWidgetEntry

    func placeholder(in _: Context) -> Entry {
        Entry(date: Date(), isRecording: false, recordingStartedAt: nil)
    }

    func getSnapshot(in _: Context, completion: @escaping (Entry) -> Void) {
        completion(makeEntry())
    }

    func getTimeline(in _: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        // Widget refreshes are budget-limited by iOS. We schedule one
        // snapshot now plus periodic refreshes; the Live Activity carries
        // any real-time updates while a capture is in progress.
        let now = Date()
        let entries: [Entry] = [
            makeEntry(date: now),
            makeEntry(date: now.addingTimeInterval(5 * 60)),
            makeEntry(date: now.addingTimeInterval(15 * 60)),
        ]
        completion(Timeline(entries: entries, policy: .atEnd))
    }

    private func makeEntry(date: Date = Date()) -> Entry {
        let defaults = UserDefaults(suiteName: AppGroup.identifier)
        let active = defaults?.bool(forKey: AppGroup.recordingActiveKey) ?? false
        let startedAtSeconds = defaults?.double(forKey: AppGroup.recordingStartedAtKey) ?? 0
        let startedAt = startedAtSeconds > 0 ? Date(timeIntervalSince1970: startedAtSeconds) : nil
        return Entry(date: date, isRecording: active, recordingStartedAt: startedAt)
    }
}

struct CaptureWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: CaptureWidgetEntry

    var body: some View {
        // App Intent button so a lock-screen tap triggers the system
        // press animation + haptic before the intent runs (matches the
        // flashlight / camera shortcuts). The intent's
        // `openAppWhenRun = true` surfaces the app in the foreground;
        // the consumer in `IntentRouter.processPending` switches the
        // root TabView to the Aufnahme tab and starts recording.
        //
        // Two earlier mistakes reverted here:
        //   • `Color.clear` was being passed to `.containerBackground`,
        //     which suppressed the lock-screen accent material and made
        //     the icon stay at full opacity against dark wallpapers.
        //     Now we hand the system `AccessoryWidgetBackground()` as
        //     the container background so it can apply its standard
        //     accent + vibrancy treatment.
        //   • `.buttonStyle(.plain)` stripped the press animation +
        //     haptic from the App Intent button. Default style keeps
        //     them.
        Button(intent: CaptureThoughtIntent()) {
            switch family {
            case .accessoryCircular: circular
            case .accessoryRectangular: rectangular
            case .accessoryInline: inline
            default: circular
            }
        }
        .containerBackground(for: .widget) {
            AccessoryWidgetBackground()
        }
    }

    private var circular: some View {
        // No ZStack — `AccessoryWidgetBackground()` is now the
        // container background, not a sibling view. The icon is the
        // only thing inside the button label, which is what the system
        // expects on `.accessoryCircular`.
        Image(systemName: entry.isRecording ? "record.circle.fill" : "mic.circle.fill")
            .font(.system(size: 28, weight: .semibold))
            .widgetAccentable()
    }

    private var rectangular: some View {
        HStack(spacing: 8) {
            Image(systemName: entry.isRecording ? "record.circle.fill" : "mic.circle.fill")
                .font(.title2)
                .widgetAccentable()
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.isRecording ? "Aufnahme läuft" : "Voice Diary")
                    .font(.headline)
                    .widgetAccentable()
                Text(entry.isRecording ? "Tippen zum Stoppen" : "Tippen zum Aufnehmen")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    private var inline: some View {
        Label(
            entry.isRecording ? "Aufnahme läuft" : "Voice Diary tippen",
            systemImage: entry.isRecording ? "record.circle.fill" : "mic.circle.fill"
        )
    }
}
