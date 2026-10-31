import Foundation
import Testing
@testable import VoiceDiary

// IOS-A77: a walkthrough that was cancelled and started again while an older
// calendar retry was still fetching. The older answer may land while the
// newer retry is still in flight; it must change nothing, and the newer
// retry must keep owning `isRetrying` until it finishes itself.
//
// Each fetch parks on a latch the test opens, so the order of the answers is
// fixed by the test. Every wait on an event is capped at 1 s.

private struct OldFetchFailed: Error {}

private func calendarEvent(_ id: String) -> ServerCalendarEvent {
    ServerCalendarEvent(
        graph_event_id: id, subject: "Sync", start: "2026-10-15T10:00:00+02:00",
        end: "2026-10-15T10:30:00+02:00", is_all_day: false, show_as: "busy",
        rsvp_status: "accepted", organizer: ServerAttendee(name: "A", email: "a@example.com"),
        attendees: [], body_preview: "", is_recurring: false, web_link: ""
    )
}

/// A one-shot event. `wait()` returns false when the 1 s cap passes first.
@MainActor
private final class Latch {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func open() {
        isOpen = true
        resumeWaiters()
    }

    func wait() async -> Bool {
        if isOpen { return true }
        let cap = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            self?.resumeWaiters()
        }
        defer { cap.cancel() }
        await withCheckedContinuation { waiters.append($0) }
        return isOpen
    }

    private func resumeWaiters() {
        let parked = waiters
        waiters = []
        parked.forEach { $0.resume() }
    }
}

/// One fetch that reports when it has started and then waits to be released.
@MainActor
private final class ParkedFetch {
    let entered = Latch()
    let release = Latch()
    private(set) var calls = 0

    func park() async {
        calls += 1
        entered.open()
        _ = await release.wait()
    }
}

/// What a retry returned, reduced to values a task may hand back.
private enum Observed: Equatable, Sendable {
    case ignored
    case stale
    case stillFailing(CalendarStart)
    case fetched([String], CalendarStart)

    init(_ outcome: CalendarStartGate.RetryOutcome) {
        switch outcome {
        case .ignored: self = .ignored
        case .stale: self = .stale
        case .stillFailing(_, let start): self = .stillFailing(start)
        case .fetched(let events, let start): self = .fetched(events.map(\.graph_event_id), start)
        }
    }
}

@MainActor
@Suite("Overlapping calendar retry ownership")
struct CalendarRetryOwnershipTests {
    enum OldFetch: CaseIterable, Sendable {
        case succeeds
        case throwsError
    }

    private let day = Date(timeIntervalSince1970: 1_760_000_000)

    private func parkedStart(_ gate: CalendarStartGate) -> CalendarStart {
        let start = CalendarStart(attempt: gate.newAttempt(), targetDate: day, language: .en, mode: .fresh)
        gate.park(start)
        return start
    }

    @Test("an older retry finishing while a newer one is in flight leaves the newer one in charge",
          arguments: OldFetch.allCases)
    func olderRetryLandsDuringNewerRetry(_ oldResult: OldFetch) async {
        let gate = CalendarStartGate()
        let oldFetch = ParkedFetch()
        let newFetch = ParkedFetch()
        defer {
            oldFetch.release.open()
            newFetch.release.open()
        }

        // The first start fails and parks; its retry is still fetching.
        let oldStart = parkedStart(gate)
        let oldRetry = Task {
            Observed(await gate.retry { _ in
                await oldFetch.park()
                if oldResult == .throwsError { throw OldFetchFailed() }
                return [calendarEvent("old")]
            })
        }
        #expect(await oldFetch.entered.wait())
        #expect(gate.isRetrying)

        // The walkthrough is cancelled and started again; the new start
        // fails, parks and retries too.
        gate.invalidate()
        #expect(!gate.isRetrying)
        let newStart = parkedStart(gate)
        let newRetry = Task {
            Observed(await gate.retry { _ in
                await newFetch.park()
                return [calendarEvent("new")]
            })
        }
        #expect(await newFetch.entered.wait())
        #expect(gate.isRetrying)

        // The old answer lands first.
        oldFetch.release.open()
        let oldOutcome = await oldRetry.value
        #expect(oldOutcome == .stale)

        #expect(gate.waiting == newStart)
        #expect(gate.current == newStart.attempt)
        #expect(!gate.isCurrent(oldStart.attempt))
        #expect(gate.isRetrying)
        #expect(gate.takeForStartWithout() == nil)

        var extraFetches = 0
        let extra = await gate.retry { _ in
            extraFetches += 1
            return [calendarEvent("extra")]
        }
        #expect(Observed(extra) == .ignored)
        #expect(extraFetches == 0)
        #expect(gate.isRetrying)
        #expect(gate.waiting == newStart)

        // The new answer lands: only its events come back, and it clears
        // the flag itself.
        newFetch.release.open()
        let newOutcome = await newRetry.value
        #expect(newOutcome == .fetched(["new"], newStart))
        #expect(gate.waiting == nil)
        #expect(!gate.isRetrying)
        #expect(oldFetch.calls == 1)
        #expect(newFetch.calls == 1)
    }
}
