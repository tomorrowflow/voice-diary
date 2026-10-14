import Foundation
import Testing
@testable import VoiceDiary

// Pure format validation of the server URL field and the first-run gate —
// no network, no Keychain.

@Suite("ServerURLValidator")
struct ServerURLValidatorTests {
    @Test("well-formed URLs are accepted and trimmed",
          arguments: [
            ("http://my-server.tailnet.ts.net:8000", "http://my-server.tailnet.ts.net:8000"),
            ("  https://example.ts.net  \n", "https://example.ts.net"),
            ("HTTP://100.64.0.1:8000/", "HTTP://100.64.0.1:8000/"),
            ("http://localhost:8000", "http://localhost:8000"),
          ])
    func accepts(raw: String, stored: String) {
        #expect(ServerURLValidator.validate(raw) == .success(stored))
    }

    @Test("empty or blank input is reported as empty", arguments: ["", "   ", "\n"])
    func empty(raw: String) {
        #expect(ServerURLValidator.validate(raw) == .failure(.empty))
    }

    @Test("a bare scheme is reported as missing its host",
          arguments: ["http://", "https://", " http:// ", "HTTP://"])
    func bareScheme(raw: String) {
        #expect(ServerURLValidator.validate(raw) == .failure(.missingHost))
    }

    @Test("other or missing schemes are rejected",
          arguments: ["my-server.tailnet.ts.net:8000", "ftp://example.com", "ws://example.com", "localhost"])
    func unsupportedScheme(raw: String) {
        #expect(ServerURLValidator.validate(raw) == .failure(.unsupportedScheme))
    }

    @Test("spaces and empty hosts are malformed",
          arguments: ["http://my server:8000", "http:// ", "http://:8000", "http:///path"])
    func malformed(raw: String) {
        let result = ServerURLValidator.validate(raw)
        #expect(result == .failure(.malformed) || result == .failure(.missingHost))
        #expect((try? result.get()) == nil)
    }

    @Test("every issue has a user-facing message")
    func messages() {
        for issue in [ServerURLValidator.Issue.empty, .missingHost, .unsupportedScheme, .malformed] {
            #expect(!issue.message.isEmpty)
        }
    }
}

@Suite("OnboardingGate")
struct OnboardingGateTests {
    @Test("shown on a fresh install")
    func freshInstall() {
        #expect(OnboardingGate.needsServerSetup(storedURL: nil, done: false))
        #expect(OnboardingGate.needsServerSetup(storedURL: "  ", done: false))
    }

    @Test("not shown once a valid server URL exists")
    func configured() {
        #expect(!OnboardingGate.needsServerSetup(storedURL: "http://x.ts.net:8000", done: false))
    }

    @Test("shown when the stored URL is the bare default or malformed")
    func invalidStoredURL() {
        #expect(OnboardingGate.needsServerSetup(storedURL: "http://", done: false))
        #expect(OnboardingGate.needsServerSetup(storedURL: "http://my server", done: false))
    }

    @Test("not shown again after finish or skip")
    func done() {
        #expect(!OnboardingGate.needsServerSetup(storedURL: nil, done: true))
    }
}
