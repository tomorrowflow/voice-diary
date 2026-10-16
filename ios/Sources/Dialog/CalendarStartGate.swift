import Foundation

/// A walkthrough start that is waiting on the user because its calendar
/// fetch failed (UFH-06, ADR 0003).
public struct CalendarStart: Equatable, Sendable {
    public enum Mode: Equatable, Sendable {
        /// A new session. Starting without the calendar is allowed.
        case fresh
        /// Resuming the unfinished session in this directory. Its step
        /// indexes were numbered with the calendar, so it cannot continue
        /// without it (see `CalendarStartGate.takeForStartWithout`).
        case resume(URL)
    }

    let attempt: UUID
    let targetDate: Date
    let language: OpenerLanguage
    let mode: Mode
}

/// Bookkeeping for "which start does a calendar answer belong to" and
/// "what may the user do about a failed one". Kept apart from
/// `WalkthroughCoordinator` so the race rules (cancel mid-fetch, double
/// tap, resume while Graph is down) are unit-testable without audio, TTS
/// or the network.
@MainActor
@Observable
public final class CalendarStartGate {
    public enum RetryOutcome {
        /// Nothing waiting, or a retry is already running.
        case ignored
        /// The walkthrough was cancelled or restarted while the fetch ran.
        case stale
        case stillFailing(Error, CalendarStart)
        case fetched([ServerCalendarEvent], CalendarStart)
    }

    /// The start whose answers count; nil after `invalidate()`.
    public private(set) var current: UUID?
    public private(set) var waiting: CalendarStart?
    /// The start that has begun but has no plan yet (session setup and the
    /// first calendar fetch). Weiter, Fertig and Pause must not act then:
    /// the plan is empty, so they would upload an empty bundle.
    private var preparing: UUID?
    private var retrying: UUID?

    public init() {}

    public var isPreparing: Bool { preparing != nil }
    /// True while a retry is in flight. `invalidate()` clears it, so a retry
    /// left over from a cancelled start does not count.
    public var isRetrying: Bool { retrying != nil }

    /// Begin a new start; any fetch still in flight for an older one is
    /// stale from now on.
    public func newAttempt() -> UUID {
        let attempt = UUID()
        current = attempt
        preparing = attempt
        return attempt
    }

    /// The start has its plan (or has failed): the controls may act again.
    /// Only the attempt that set the flag may clear it.
    public func finishPreparing(_ attempt: UUID) {
        if preparing == attempt { preparing = nil }
    }

    /// Cancel: drop the waiting start and make every in-flight fetch stale.
    public func invalidate() {
        current = nil
        waiting = nil
        preparing = nil
        retrying = nil
    }

    public func isCurrent(_ attempt: UUID) -> Bool { current == attempt }

    /// Park a start on the user's decision.
    public func park(_ start: CalendarStart) {
        finishPreparing(start.attempt)
        waiting = start
    }

    /// Whether "Ohne Kalender starten" may be offered. A resumed session
    /// cannot continue without events: its recorded event audio can only be
    /// rebuilt from them, and the later steps would shift by one.
    public var canStartWithout: Bool {
        waiting?.mode == .fresh
    }

    /// Claim the waiting start for a calendar-free run; nil unless allowed.
    public func takeForStartWithout() -> CalendarStart? {
        guard !isRetrying, canStartWithout, let start = waiting else { return nil }
        waiting = nil
        return start
    }

    /// Re-run the fetch for the waiting start. Only the attempt that is
    /// still current acts on the answer, so a fetch that outlives a cancel
    /// (or a newer start) changes nothing.
    public func retry(
        fetch: (Date) async throws -> [ServerCalendarEvent]
    ) async -> RetryOutcome {
        guard let start = waiting, retrying != start.attempt else { return .ignored }
        retrying = start.attempt
        defer { if retrying == start.attempt { retrying = nil } }
        let events: [ServerCalendarEvent]
        do {
            events = try await fetch(start.targetDate)
        } catch {
            guard isCurrent(start.attempt), waiting == start else { return .stale }
            return .stillFailing(error, start)
        }
        guard isCurrent(start.attempt), waiting == start else { return .stale }
        waiting = nil
        return .fetched(events, start)
    }
}

/// Persisted "this session was started without the calendar" flag. A resume
/// reads it and rebuilds the same calendar-free plan without fetching (a
/// fetch that now succeeds would add a calendar step and shift every step
/// index the recorded segments were named with).
enum CalendarFreeMarker {
    static let filename = "calendar_free"

    /// False when the marker could not be written; the caller must not go
    /// on without the calendar then, or a later resume would fetch it and
    /// shift every step index.
    static func mark(in dir: URL) -> Bool {
        do {
            try Data().write(
                to: dir.appending(path: filename),
                options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
            )
            return true
        } catch {
            return false
        }
    }

    static func isMarked(in dir: URL) -> Bool {
        FileManager.default.fileExists(atPath: dir.appending(path: filename).path)
    }
}
