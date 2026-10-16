import Foundation
import Testing
@testable import VoiceDiary

// Race rules for the walkthrough start notice (UFH-08): a late `/health`
// answer or an older six-second timer must not alter a cancelled or newer
// start. Pure — no network, no timers.

@Suite("UpstreamStartNotice")
struct UpstreamStartNoticeTests {
    private let notice = "Analysis is delayed; your texts are saved."

    @Test("the current start publishes and clears its notice")
    func currentStartPublishesAndClears() {
        var slot = UpstreamStartNotice()
        let token = slot.begin()
        let shown = slot.publish(notice, for: token)
        #expect(shown)
        #expect(slot.message == notice)
        slot.clear(for: token)
        #expect(slot.message == nil)
    }

    @Test("a /health answer that arrives after cancel shows nothing")
    func lateAnswerAfterCancelIsDropped() {
        var slot = UpstreamStartNotice()
        let token = slot.begin()
        slot.reset()
        let shown = slot.publish(notice, for: token)
        #expect(!shown)
        #expect(slot.message == nil)
    }

    @Test("a /health answer from an older start does not show on a newer one")
    func lateAnswerFromOlderStartIsDropped() {
        var slot = UpstreamStartNotice()
        let older = slot.begin()
        let newer = slot.begin()
        let shown = slot.publish(notice, for: older)
        #expect(!shown)
        #expect(slot.message == nil)
        #expect(slot.isCurrent(newer))
    }

    @Test("cancel clears a notice that is already showing")
    func cancelClearsShowingNotice() {
        var slot = UpstreamStartNotice()
        let token = slot.begin()
        slot.publish(notice, for: token)
        slot.reset()
        #expect(slot.message == nil)
    }

    @Test("a new start clears the previous start's notice")
    func beginClearsPreviousNotice() {
        var slot = UpstreamStartNotice()
        let older = slot.begin()
        slot.publish(notice, for: older)
        _ = slot.begin()
        #expect(slot.message == nil)
    }

    @Test("an older timer does not clear a newer start's identical notice")
    func olderTimerKeepsNewerNotice() {
        var slot = UpstreamStartNotice()
        let older = slot.begin()
        slot.publish(notice, for: older)
        let newer = slot.begin()
        slot.publish(notice, for: newer)
        // The older start's six seconds are up.
        slot.clear(for: older)
        #expect(slot.message == notice)
        slot.clear(for: newer)
        #expect(slot.message == nil)
    }

    @Test("a timer from a cancelled start does not clear the next start's notice")
    func cancelledTimerKeepsNextNotice() {
        var slot = UpstreamStartNotice()
        let cancelled = slot.begin()
        slot.publish(notice, for: cancelled)
        slot.reset()
        let next = slot.begin()
        slot.publish(notice, for: next)
        slot.clear(for: cancelled)
        #expect(slot.message == notice)
    }
}
