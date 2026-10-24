import Foundation
import Testing
@testable import VoiceDiary

// SPEC §15.1: an unreachable server during enrichment gets its own
// message; every other failure keeps the generic one.

@Suite("EnrichmentFailureCopy")
struct EnrichmentFailureCopyTests {
    private let unreachableEN = "Can't reach server. Enrichment skipped."
    private let genericEN = "I couldn't answer that just now."

    @Test("connectivity failures use the server-unreachable message",
          arguments: [
            URLError.Code.cannotConnectToHost,
            .cannotFindHost,
            .dnsLookupFailed,
            .networkConnectionLost,
            .notConnectedToInternet,
            .timedOut,
          ])
    func connectivity(code: URLError.Code) {
        let msg = EnrichmentService.failureMessage(for: URLError(code), language: .en)
        #expect(msg == unreachableEN)
    }

    @Test("other failures use the generic message")
    func other() {
        let errors: [any Error] = [
            ServerClientError.http(status: 500, detail: ""),
            ServerClientError.decodingFailed("x"),
            EnrichmentService.EnrichmentError.empty,
            EnrichmentService.EnrichmentError.classificationFailed("x"),
        ]
        for e in errors {
            #expect(EnrichmentService.failureMessage(for: e, language: .en) == genericEN)
        }
    }

    private func coded(_ status: Int, _ code: String, _ upstream: String) -> ServerClientError {
        .http(status: status, detail: "\(code): x",
              failure: UpstreamFailure(code: code, upstream: upstream, retryable: true))
    }

    @Test("coded failures get a per-upstream spoken line ending in the skip notice in English")
    func codedEnglish() {
        let cases: [(ServerClientError, String)] = [
            (coded(503, "ollama_unavailable", "ollama"),
             "The summary isn’t available right now. Enrichment skipped."),
            (coded(502, "ollama_engine_error", "ollama"),
             "The summary isn’t available right now. Enrichment skipped."),
            (coded(503, "lightrag_timeout", "lightrag"),
             "The diary memory isn’t reachable right now. Enrichment skipped."),
            (coded(503, "msgraph_unavailable", "msgraph"),
             "Calendar and mail aren’t reachable right now. Enrichment skipped."),
            (coded(429, "msgraph_rate_limited", "msgraph"),
             "Calendar and mail aren’t reachable right now. Enrichment skipped."),
            (coded(503, "msgraph_not_bootstrapped", "msgraph"),
             "Calendar and mail aren’t set up on the server. Enrichment skipped."),
        ]
        for (error, expected) in cases {
            #expect(EnrichmentService.failureMessage(for: error, language: .en) == expected)
        }
    }

    @Test("coded failures get the documented German lines")
    func codedGerman() {
        let ollama = EnrichmentService.failureMessage(for: coded(503, "ollama_unavailable", "ollama"), language: .de)
        let lightrag = EnrichmentService.failureMessage(for: coded(503, "lightrag_unavailable", "lightrag"), language: .de)
        let graph = EnrichmentService.failureMessage(for: coded(503, "msgraph_unavailable", "msgraph"), language: .de)
        #expect(ollama == "Die Zusammenfassung ist gerade nicht verfügbar. Anreicherung übersprungen.")
        #expect(lightrag == "Das Tagebuch-Gedächtnis ist gerade nicht erreichbar. Anreicherung übersprungen.")
        #expect(graph == "Kalender und Mail sind gerade nicht erreichbar. Anreicherung übersprungen.")
    }

    @Test("an upstream enrichment does not call falls back to the generic message")
    func codedOtherUpstream() {
        let error = coded(503, "whisper_unavailable", "whisper")
        #expect(EnrichmentService.failureMessage(for: error, language: .en) == genericEN)
        #expect(EnrichmentService.failureMessage(for: error, language: .de)
                == "Ich konnte die Frage gerade nicht beantworten.")
    }

    @Test("Blindfold codes keep the generic message: enrichment never calls Blindfold")
    func blindfoldIsGeneric() {
        for code in ["blindfold_unavailable", "blindfold_timeout", "blindfold_engine_error", "blindfold_new"] {
            let error = coded(503, code, "blindfold")
            #expect(EnrichmentService.failureMessage(for: error, language: .en) == genericEN)
            #expect(EnrichmentService.failureMessage(for: error, language: .de)
                    == "Ich konnte die Frage gerade nicht beantworten.")
        }
    }

    @Test("connectivity failures stay on the unreachable message even with the catalog present")
    func connectivityUnchanged() {
        #expect(EnrichmentService.failureMessage(for: URLError(.cannotConnectToHost), language: .de)
                == "Server nicht erreichbar. Die Anreicherung wird übersprungen.")
    }

    @Test("German copy distinguishes both branches")
    func german() {
        let a = EnrichmentService.failureMessage(for: URLError(.cannotConnectToHost), language: .de)
        let b = EnrichmentService.failureMessage(for: ServerClientError.http(status: 500, detail: ""), language: .de)
        #expect(a == "Server nicht erreichbar. Die Anreicherung wird übersprungen.")
        #expect(b == "Ich konnte die Frage gerade nicht beantworten.")
    }
}
