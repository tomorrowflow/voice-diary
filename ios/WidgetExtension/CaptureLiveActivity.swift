import ActivityKit
import SwiftUI
import WidgetKit

// Live Activity for in-progress drive-by capture. Surfaces on the lock
// screen and inside the Dynamic Island while a recording is running.

struct CaptureLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: CaptureActivityAttributes.self) { context in
            // Lock-screen banner.
            HStack(spacing: 12) {
                Image(systemName: "record.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.red)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Aufnahme läuft")
                        .font(.headline)
                    Text(timeString(context.state.elapsedSeconds))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .activityBackgroundTint(.black.opacity(0.85))
            .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "record.circle.fill")
                        .foregroundStyle(.red)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(timeString(context.state.elapsedSeconds))
                        .font(.callout.monospacedDigit())
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text("Voice Diary nimmt auf — Action Button erneut drücken zum Beenden.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } compactLeading: {
                Image(systemName: "record.circle.fill")
                    .foregroundStyle(.red)
            } compactTrailing: {
                Text(timeString(context.state.elapsedSeconds))
                    .font(.caption.monospacedDigit())
            } minimal: {
                Image(systemName: "record.circle.fill")
                    .foregroundStyle(.red)
            }
        }
    }

    private func timeString(_ s: Int) -> String {
        String(format: "%02d:%02d", s / 60, s % 60)
    }
}
