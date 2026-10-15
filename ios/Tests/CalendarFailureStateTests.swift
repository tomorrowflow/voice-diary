import Foundation
import Testing
@testable import VoiceDiary

// UFH-06: a calendar failure at walkthrough start is a decision screen
// (retry or start without calendar), not a dead end. The coordinator is a
// singleton over live services, so these cover the pure parts: how the
// diagnosis ranks the two actions and how the new state behaves.

@Suite("Calendar failure at start")
struct CalendarFailureStateTests {
    private func diagnosis(_ code: String?, retryable: Bool?, status: Int = 503) -> ConnectionDiagnosis {
        ConnectionDiagnosis.classify(
            ServerClientError.http(
                status: status, detail: "boom",
                failure: UpstreamFailure(code: code, upstream: "msgraph", retryable: retryable)
            ),
            language: .en
        )
    }

    @Test("a retryable Graph failure keeps Retry as the primary action")
    func retryableGraphFailure() {
        for code in ["msgraph_unavailable", "msgraph_rate_limited", "msgraph_engine_error"] {
            #expect(diagnosis(code, retryable: true).isRetryable, "\(code)")
        }
    }

    @Test("Graph not bootstrapped is not retryable and says the server has to fix it")
    func notBootstrapped() {
        let d = diagnosis("msgraph_not_bootstrapped", retryable: false)
        #expect(!d.isRetryable)
        #expect(d.hint.contains("This has to be fixed on the server."))
    }

    @Test("failures without the contract fields stay retryable")
    func uncodedFailuresAreRetryable() {
        #expect(ConnectionDiagnosis.classify(ServerClientError.http(status: 502, detail: "x")).isRetryable)
        #expect(ConnectionDiagnosis.classify(URLError(.cannotConnectToHost)).isRetryable)
    }

    @Test("calendarUnavailable is a waiting state: no event-loop chrome, no pause")
    func waitingState() {
        let state = WalkthroughState.calendarUnavailable(diagnosis("msgraph_unavailable", retryable: true))
        #expect(!state.isInEventLoop)
        #expect(!state.isPausable)
        #expect(!state.isListening)
        #expect(!state.isSpeaking)
        #expect(!state.label.isEmpty)
    }
}
