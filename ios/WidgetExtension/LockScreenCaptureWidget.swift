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
        Link(destination: URL(string: "voicediary://capture/start")!) {
            switch family {
            case .accessoryCircular: circular
            case .accessoryRectangular: rectangular
            case .accessoryInline: inline
            default: circular
            }
        }
        .containerBackground(for: .widget) { Color.clear }
    }

    private var circular: some View {
        ZStack {
            AccessoryWidgetBackground()
            Image(systemName: entry.isRecording ? "record.circle.fill" : "mic.circle.fill")
                .font(.system(size: 28, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
        }
    }

    private var rectangular: some View {
        HStack(spacing: 8) {
            Image(systemName: entry.isRecording ? "record.circle.fill" : "mic.circle.fill")
                .font(.title2)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.isRecording ? "Aufnahme läuft" : "Voice Diary")
                    .font(.headline)
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
