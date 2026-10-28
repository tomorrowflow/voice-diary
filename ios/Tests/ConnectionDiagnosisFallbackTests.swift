import Foundation
import Testing
@testable import VoiceDiary

// IOS-A60: `ConnectionDiagnosis.classify` explains transport (`URLError`) and
// local (not configured, decoding, missing file, arbitrary) failures through
// its public `Error` entry point. HTTP and coded upstream failures are covered
// in FailureCatalogTests and CalendarFailureDiagnosisTests.
//
// `URLError.localizedDescription` depends on the device locale, so URLError
// detail is checked by its stable "URLError <code>: " prefix only.

private let unreachableImage = "antenna.radiowaves.left.and.right.slash"

private struct LocalFailure: Error {}

@Suite("Transport failure diagnosis")
struct TransportFailureDiagnosisTests {
    private func diagnosis(_ code: URLError.Code) -> ConnectionDiagnosis {
        ConnectionDiagnosis.classify(URLError(code))
    }

    private func expectDetail(_ d: ConnectionDiagnosis, code: URLError.Code) {
        let prefix = "URLError \(code.rawValue): "
        #expect(d.detail?.hasPrefix(prefix) == true, "\(code.rawValue) detail \(d.detail ?? "nil")")
    }

    @Test("no internet connection is offline, not an unreachable server")
    func offline() {
        let d = diagnosis(.notConnectedToInternet)
        #expect(d.kind == .offline)
        #expect(d.systemImage == "wifi.slash")
        #expect(d.isRetryable)
        expectDetail(d, code: .notConnectedToInternet)
    }

    @Test("both DNS failures point at Tailscale name resolution")
    func dnsFailures() {
        let dns: [URLError.Code] = [.cannotFindHost, .dnsLookupFailed]
        for code in dns {
            let d = diagnosis(code)
            #expect(d.kind == .unreachable, "\(code.rawValue)")
            #expect(d.systemImage == unreachableImage, "\(code.rawValue)")
            #expect(d.isRetryable, "\(code.rawValue)")
            expectDetail(d, code: code)
        }
        let first = diagnosis(.cannotFindHost)
        let second = diagnosis(.dnsLookupFailed)
        #expect(first.title == second.title)
        #expect(first.hint == second.hint)
        #expect(first.hint.contains("aufgelöst"))
    }

    @Test("all four connection failures say the server is silent, not the hostname")
    func connectionFailures() {
        let connection: [URLError.Code] = [
            .cannotConnectToHost, .networkConnectionLost, .secureConnectionFailed, .resourceUnavailable,
        ]
        let dns = diagnosis(.dnsLookupFailed)
        for code in connection {
            let d = diagnosis(code)
            #expect(d.kind == .unreachable, "\(code.rawValue)")
            #expect(d.systemImage == unreachableImage, "\(code.rawValue)")
            #expect(d.isRetryable, "\(code.rawValue)")
            expectDetail(d, code: code)
            #expect(d.title == dns.title, "\(code.rawValue) shares the unreachable title")
            #expect(d.hint == diagnosis(.cannotConnectToHost).hint, "\(code.rawValue)")
            #expect(d.hint != dns.hint, "\(code.rawValue) must not read like a DNS failure")
        }
    }

    @Test("a timeout is its own kind with a clock icon")
    func timeout() {
        let d = diagnosis(.timedOut)
        #expect(d.kind == .timeout)
        #expect(d.systemImage == "clock.badge.exclamationmark.fill")
        #expect(d.isRetryable)
        expectDetail(d, code: .timedOut)
    }

    @Test("bad and unsupported URLs send the user to Settings")
    func invalidURL() {
        let invalid: [URLError.Code] = [.badURL, .unsupportedURL]
        for code in invalid {
            let d = diagnosis(code)
            #expect(d.kind == .notConfigured, "\(code.rawValue)")
            #expect(d.systemImage == "link.badge.plus", "\(code.rawValue)")
            #expect(d.isRetryable, "\(code.rawValue)")
            expectDetail(d, code: code)
        }
        #expect(diagnosis(.badURL).title == diagnosis(.unsupportedURL).title)
        #expect(diagnosis(.badURL).hint == diagnosis(.unsupportedURL).hint)
    }

    @Test("authentication required reads like a rejected bearer token")
    func authenticationRequired() {
        let d = diagnosis(.userAuthenticationRequired)
        let http = ConnectionDiagnosis.classify(ServerClientError.http(status: 401, detail: "nope"))
        #expect(d.kind == .unauthorised)
        #expect(d.systemImage == "lock.trianglebadge.exclamationmark.fill")
        #expect(d.isRetryable)
        #expect(d.title == http.title)
        #expect(d.hint == http.hint)
        expectDetail(d, code: .userAuthenticationRequired)
    }

    @Test("an unlisted URL error falls back to the generic unreachable copy")
    func unlistedURLError() {
        let unlisted: [URLError.Code] = [.cancelled, .fileDoesNotExist, .cannotParseResponse]
        let known: [URLError.Code] = [.cannotFindHost, .cannotConnectToHost, .timedOut]
        for code in unlisted {
            let d = diagnosis(code)
            #expect(d.kind == .unreachable, "\(code.rawValue)")
            #expect(d.systemImage == unreachableImage, "\(code.rawValue)")
            #expect(d.isRetryable, "\(code.rawValue)")
            expectDetail(d, code: code)
            for other in known {
                #expect(d.hint != diagnosis(other).hint, "\(code.rawValue) vs \(other.rawValue)")
            }
        }
        #expect(diagnosis(.cancelled).title != diagnosis(.cannotFindHost).title)
    }
}

@Suite("Local failure diagnosis")
struct LocalFailureDiagnosisTests {
    @Test("a missing server config sends the user to Settings with no detail")
    func notConfigured() {
        let d = ConnectionDiagnosis.classify(ServerClientError.notConfigured)
        #expect(d.kind == .notConfigured)
        #expect(d.systemImage == "gearshape.fill")
        #expect(d.detail == nil)
        #expect(d.isRetryable)
    }

    @Test("a wrapped decoding failure keeps the supplied detail verbatim")
    func wrappedDecodingFailed() {
        let d = ConnectionDiagnosis.classify(ServerClientError.decodingFailed("key 'events' missing"))
        #expect(d.kind == .malformedResponse)
        #expect(d.systemImage == "questionmark.circle.fill")
        #expect(d.detail == "key 'events' missing")
        #expect(d.isRetryable)
    }

    @Test("a missing upload file reports its path and is not a server problem")
    func missingFile() {
        let url = URL(fileURLWithPath: "/tmp/voice-diary/cache/take-1.m4a")
        let d = ConnectionDiagnosis.classify(ServerClientError.missingFile(url))
        #expect(d.kind == .unknown)
        #expect(d.systemImage == "doc.questionmark")
        #expect(d.detail == url.path)
        #expect(d.isRetryable)
    }

    @Test("a direct DecodingError reads like a wrapped decoding failure")
    func directDecodingError() {
        let error = DecodingError.dataCorrupted(
            .init(codingPath: [], debugDescription: "bad shape")
        )
        let d = ConnectionDiagnosis.classify(error)
        let wrapped = ConnectionDiagnosis.classify(ServerClientError.decodingFailed("x"))
        #expect(d.kind == .malformedResponse)
        #expect(d.systemImage == "questionmark.circle.fill")
        #expect(d.isRetryable)
        #expect(d.title == wrapped.title)
        #expect(d.hint == wrapped.hint)
        #expect(d.detail == String(describing: error))
        #expect(d.detail?.contains("bad shape") == true)
    }

    @Test("an arbitrary NSError falls back to the unexpected-error copy")
    func arbitraryNSError() {
        let error = NSError(domain: "VoiceDiaryTests.Arbitrary", code: 42)
        let d = ConnectionDiagnosis.classify(error)
        #expect(d.kind == .unknown)
        #expect(d.systemImage == "exclamationmark.triangle.fill")
        #expect(d.isRetryable)
        #expect(d.detail == String(describing: error))
        #expect(d.detail?.contains("VoiceDiaryTests.Arbitrary") == true)
        #expect(d.detail?.contains("42") == true)
    }

    @Test("an arbitrary Swift error also lands in the unexpected-error fallback")
    func arbitrarySwiftError() {
        let d = ConnectionDiagnosis.classify(LocalFailure())
        #expect(d.kind == .unknown)
        #expect(d.detail == String(describing: LocalFailure()))
        #expect(d.title != ConnectionDiagnosis.classify(ServerClientError.missingFile(URL(fileURLWithPath: "/x"))).title)
    }
}
