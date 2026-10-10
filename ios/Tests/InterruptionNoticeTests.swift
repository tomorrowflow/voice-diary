import Foundation
import Testing
@testable import VoiceDiary

// UX-1 / #26: after a call/Siri/alarm interruption `AudioEngine` has already
// closed the writer, so `stop()` throws `notRunning`. That must not be
// treated as a failure that discards the captured audio.

@Suite("InterruptionNotice")
struct InterruptionNoticeTests {
    @Test("notRunning after an interruption is tolerated")
    func tolerateNotRunningWhenInterrupted() {
        #expect(InterruptionNotice.shouldTolerateStopError(
            AudioEngine.EngineError.notRunning, wasInterrupted: true))
    }

    @Test("notRunning without an interruption is still an error")
    func notRunningWithoutInterruptionPropagates() {
        #expect(!InterruptionNotice.shouldTolerateStopError(
            AudioEngine.EngineError.notRunning, wasInterrupted: false))
    }

    @Test("other errors are never tolerated, even when interrupted")
    func otherErrorsPropagate() {
        #expect(!InterruptionNotice.shouldTolerateStopError(
            AudioEngine.EngineError.sessionConfigFailed("x"), wasInterrupted: true))
        #expect(!InterruptionNotice.shouldTolerateStopError(
            NSError(domain: "x", code: 1), wasInterrupted: true))
    }

    @Test("message is the promised notice")
    func messageText() {
        #expect(InterruptionNotice.message.contains("interrupted")
            || InterruptionNotice.message.contains("unterbrochen"))
    }
}
