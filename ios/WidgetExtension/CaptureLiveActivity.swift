import ActivityKit
import SwiftUI
import WidgetKit

// Live Activity for in-progress drive-by capture. Surfaces on the lock
// screen and inside the Dynamic Island while a recording is running.

struct CaptureLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: CaptureActivityAttributes.self) { context in
            // Lock-screen banner. The counter is intentionally hidden
            // during `.speaking` because the assistant talking isn't a
            // metered activity — it's just feedback that the AI has the
            // floor. Hiding it keeps the banner from showing a frozen
            // "00:00" while the user is meant to be listening.
            HStack(spacing: 12) {
                Image(systemName: stateSymbol(context.state.kind))
                    .font(.title2)
                    .foregroundStyle(stateColor(context.state.kind))
                VStack(alignment: .leading, spacing: 2) {
                    Text(stateLabel(context.state.kind))
                        .font(.headline)
                    if context.state.kind != .speaking {
                        Text(timeString(context.state.elapsedSeconds))
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .activityBackgroundTint(.black.opacity(0.85))
            .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            // Per Apple HIG: keep compact + minimal regions to *icons only*
            // (~24pt tap target, no labels). Text/label belongs to the
            // expanded layout, which only appears on long-press. We avoid
            // SymbolEffect / .pulse here — Live Activities run in a
            // restricted SwiftUI subset that drops most animation
            // modifiers, which leaves the icon invisible.
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: stateSymbol(context.state.kind))
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(stateColor(context.state.kind))
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if context.state.kind != .speaking {
                        Text(timeString(context.state.elapsedSeconds))
                            .font(.callout.monospacedDigit())
                    }
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(stateLabel(context.state.kind))
                        .font(.callout.weight(.medium))
                        .foregroundStyle(stateColor(context.state.kind))
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if context.state.kind == .recording {
                        Text("Voice Diary nimmt auf — Action Button erneut drücken zum Beenden.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } compactLeading: {
                Image(systemName: stateSymbol(context.state.kind))
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(stateColor(context.state.kind))
            } compactTrailing: {
                // Compact trailing keeps space for *something* per HIG —
                // when the assistant is speaking we drop in a small
                // waveform glyph instead of a frozen "00:00", and when
                // the user is being recorded we show the elapsed-time
                // counter for the active segment.
                if context.state.kind == .speaking {
                    Image(systemName: "waveform")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(stateColor(context.state.kind))
                } else {
                    Text(timeString(context.state.elapsedSeconds))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(stateColor(context.state.kind))
                }
            } minimal: {
                Image(systemName: stateSymbol(context.state.kind))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(stateColor(context.state.kind))
            }
        }
    }

    /// SF Symbol mapping per state. All names verified against the SF
    /// Symbols catalog (iOS 14+). HIG calls out symbols (not custom dots)
    /// in compact island regions so the system can render them at the
    /// correct stroke weight + accessibility size.
    private func stateSymbol(_ kind: CaptureActivityAttributes.Kind) -> String {
        switch kind {
        case .recording: return "record.circle.fill"
        case .listening: return "waveform.circle.fill"
        case .speaking:  return "speaker.wave.2.fill"
        }
    }

    private func stateColor(_ kind: CaptureActivityAttributes.Kind) -> Color {
        switch kind {
        case .recording, .listening: return .red
        case .speaking:              return .orange
        }
    }

    private func stateLabel(_ kind: CaptureActivityAttributes.Kind) -> String {
        switch kind {
        case .recording: return "Aufnahme läuft"
        case .listening: return "höre zu"
        case .speaking:  return "Editor spricht"
        }
    }

    private func timeString(_ s: Int) -> String {
        String(format: "%02d:%02d", s / 60, s % 60)
    }
}
