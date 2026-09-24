@preconcurrency import ActivityKit
import Foundation

// Single-owner arbiter for `CaptureActivityAttributes` Live Activities.
//
// Both `CaptureCoordinator` (drive-by) and `WalkthroughCoordinator`
// (evening flow) want to surface state in the Dynamic Island / lock-
// screen banner using the same activity type. Letting them each call
// `Activity.request` independently produced two failure modes the user
// reports as "stalls and disconnects":
//
//   1. Orphan activities. If the app is killed mid-session (Gemma jetsam,
//      manual swipe-up), the system banner remains but the coordinator
//      cold-starts with `liveActivity = nil`. Subsequent `end(...)` calls
//      silently no-op against the orphan, and the next `request(...)`
//      stacks a second activity on top of it.
//   2. Cross-coordinator collisions. A drive-by capture fired while a
//      walkthrough is paused can create a second activity of the same
//      type with no relationship to the first.
//
// The hub centralises ownership: `sync` always ends any extra activities
// before requesting a new one, `rehydrate` adopts a single survivor at
// app launch, and `end` ignores stale calls from a non-owner.

@MainActor
public final class LiveActivityHub {
    public static let shared = LiveActivityHub()

    public enum Owner: Sendable, Equatable {
        case capture       // drive-by note recording
        case walkthrough   // evening flow
    }

    private var activity: Activity<CaptureActivityAttributes>?
    private var owner: Owner?

    private init() {}

    /// Walk every system-tracked activity of our type. Keep the most
    /// recent one (we can't tell which coordinator created it — the next
    /// `sync` will take ownership and overwrite its content), end the
    /// rest. Called from app launch + scene-active so cold-starts after a
    /// kill don't leave the lock screen showing a stale banner.
    public func rehydrate() async {
        let all = Activity<CaptureActivityAttributes>.activities
        guard !all.isEmpty else { return }
        // Order isn't guaranteed by the API; keep the first and end the
        // rest. The next `sync` will rewrite content + ownership before
        // the user is likely to look at the lock screen again.
        if let keeper = all.first {
            self.activity = keeper
            self.owner = nil  // unowned until next sync
        }
        for a in all.dropFirst() {
            await a.end(nil, dismissalPolicy: .immediate)
        }
    }

    /// Push the latest state for `owner`. If `owner` already holds the
    /// activity, update in place. Otherwise end any existing activities
    /// (ours or orphaned) and request a fresh one. `elapsedSeconds` is
    /// folded into `startedAt` so the widget's self-counting
    /// `Text(timerInterval:)` view starts at the right offset even after
    /// a pause + resume cycle, without needing a per-second push.
    public func sync(
        owner: Owner,
        kind: CaptureActivityAttributes.Kind,
        elapsedSeconds: Int,
        isPaused: Bool
    ) async {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        // Bias `startedAt` so the widget's `Text(timerInterval:)` reads
        // exactly `elapsedSeconds` *now* — that lets pause/resume cycles
        // pick up where they left off without the widget needing to know
        // about them.
        let startedAt = Date().addingTimeInterval(-Double(elapsedSeconds))
        let state = CaptureActivityAttributes.ContentState(
            startedAt: startedAt,
            elapsedSeconds: elapsedSeconds,
            kind: kind,
            isPaused: isPaused
        )
        // `staleDate` lets the system mark the banner as aged if updates
        // dry up (background suspension, jetsam). Without it iOS keeps
        // showing the last-pushed content forever, which is the second
        // face of "the lock screen stalled" the user reports.
        let content = ActivityContent(
            state: state,
            staleDate: Date().addingTimeInterval(120),
            relevanceScore: Self.relevanceScore(for: kind)
        )

        if let existing = activity, self.owner == owner {
            await existing.update(content)
            return
        }
        // Different (or no) owner — wipe the slate so we never stack two
        // activities of the same type.
        await endAllInternal()
        do {
            self.activity = try Activity.request(
                attributes: CaptureActivityAttributes(),
                content: content
            )
            self.owner = owner
        } catch {
            Log.app.warning(
                "LiveActivityHub.sync request failed: \(String(describing: error), privacy: .public)"
            )
        }
    }

    /// End the current activity only if `owner` still holds it. A
    /// coordinator whose ownership was taken over by the other one should
    /// not be able to tear down the active banner with a stale `end`.
    public func end(owner: Owner) async {
        guard self.owner == owner else { return }
        if let a = activity {
            await a.end(nil, dismissalPolicy: .immediate)
        }
        activity = nil
        self.owner = nil
    }

    private func endAllInternal() async {
        for a in Activity<CaptureActivityAttributes>.activities {
            await a.end(nil, dismissalPolicy: .immediate)
        }
        activity = nil
        owner = nil
    }

    /// Higher = more prominent in the Dynamic Island when multiple Live
    /// Activities (from other apps too) compete for the compact / minimal
    /// regions. Recording outranks listening outranks the AI speaking.
    private static func relevanceScore(for kind: CaptureActivityAttributes.Kind) -> Double {
        switch kind {
        case .recording: return 1.0
        case .listening: return 0.9
        case .speaking:  return 0.8
        }
    }
}
