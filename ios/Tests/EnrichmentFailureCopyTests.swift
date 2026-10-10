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

    @Test("German copy distinguishes both branches")
    func german() {
        let a = EnrichmentService.failureMessage(for: URLError(.cannotConnectToHost), language: .de)
        let b = EnrichmentService.failureMessage(for: ServerClientError.http(status: 500, detail: ""), language: .de)
        #expect(a == "Server nicht erreichbar. Die Anreicherung wird übersprungen.")
        #expect(b == "Ich konnte die Frage gerade nicht beantworten.")
    }
}
