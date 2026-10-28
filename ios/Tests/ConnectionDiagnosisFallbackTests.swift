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

@Suite("Transport failure diagnosis")
struct TransportFailureDiagnosisTests {
    private let unreachableImage = "antenna.radiowaves.left.and.right.slash"

    private func diagnosis(_ code: URLError.Code) -> ConnectionDiagnosis {
        ConnectionDiagnosis.classify(URLError(code))
    }

    /// Pins everything that is not copy: kind, icon, retryability and the
    /// `URLError <code>: ` detail prefix.
    private func expectDiagnosis(
        _ codes: [URLError.Code], kind: ConnectionDiagnosis.Kind, systemImage: String
    ) {
        for code in codes {
            let d = diagnosis(code)
            #expect(d.kind == kind, "\(code.rawValue)")
            #expect(d.systemImage == systemImage, "\(code.rawValue)")
            #expect(d.isRetryable, "\(code.rawValue)")
            #expect(d.detail?.hasPrefix("URLError \(code.rawValue): ") == true, "\(code.rawValue) detail \(d.detail ?? "nil")")
        }
    }

    @Test("no internet connection is offline, not an unreachable server")
    func offline() {
        expectDiagnosis([.notConnectedToInternet], kind: .offline, systemImage: "wifi.slash")
    }

    @Test("both DNS failures share one explanation")
    func dnsFailures() {
        expectDiagnosis([.cannotFindHost, .dnsLookupFailed], kind: .unreachable, systemImage: unreachableImage)
        #expect(diagnosis(.cannotFindHost).title == diagnosis(.dnsLookupFailed).title)
        #expect(diagnosis(.cannotFindHost).hint == diagnosis(.dnsLookupFailed).hint)
    }

    @Test("all four connection failures share one explanation")
    func connectionFailures() {
        let codes: [URLError.Code] = [
            .cannotConnectToHost, .networkConnectionLost, .secureConnectionFailed, .resourceUnavailable,
        ]
        expectDiagnosis(codes, kind: .unreachable, systemImage: unreachableImage)
        for code in codes {
            #expect(diagnosis(code).title == diagnosis(.cannotConnectToHost).title, "\(code.rawValue)")
            #expect(diagnosis(code).hint == diagnosis(.cannotConnectToHost).hint, "\(code.rawValue)")
        }
    }

    @Test("a timeout is its own kind with a clock icon")
    func timeout() {
        expectDiagnosis([.timedOut], kind: .timeout, systemImage: "clock.badge.exclamationmark.fill")
    }

    @Test("bad and unsupported URLs send the user to Settings with one explanation")
    func invalidURL() {
        expectDiagnosis([.badURL, .unsupportedURL], kind: .notConfigured, systemImage: "link.badge.plus")
        #expect(diagnosis(.badURL).title == diagnosis(.unsupportedURL).title)
        #expect(diagnosis(.badURL).hint == diagnosis(.unsupportedURL).hint)
    }

    @Test("authentication required reads like a rejected bearer token")
    func authenticationRequired() {
        expectDiagnosis(
            [.userAuthenticationRequired], kind: .unauthorised,
            systemImage: "lock.trianglebadge.exclamationmark.fill"
        )
        let http = ConnectionDiagnosis.classify(ServerClientError.http(status: 401, detail: "nope"))
        #expect(diagnosis(.userAuthenticationRequired).title == http.title)
        #expect(diagnosis(.userAuthenticationRequired).hint == http.hint)
    }

    @Test("an unlisted URL error falls back to one generic unreachable explanation")
    func unlistedURLError() {
        let unlisted: [URLError.Code] = [.cancelled, .fileDoesNotExist, .cannotParseResponse]
        expectDiagnosis(unlisted, kind: .unreachable, systemImage: unreachableImage)
        for code in unlisted {
            #expect(diagnosis(code).title == diagnosis(.cancelled).title, "\(code.rawValue)")
            #expect(diagnosis(code).hint == diagnosis(.cancelled).hint, "\(code.rawValue)")
        }
    }

    @Test("each failure group keeps its own copy: titles differ except for the shared unreachable title")
    func copyDistinctions() {
        // One representative per group: offline, DNS, connection, timeout,
        // invalid URL, authentication, unlisted fallback.
        let groups = [
            diagnosis(.notConnectedToInternet), diagnosis(.dnsLookupFailed), diagnosis(.cannotConnectToHost),
            diagnosis(.timedOut), diagnosis(.badURL), diagnosis(.userAuthenticationRequired),
            diagnosis(.cancelled),
        ]
        #expect(Set(groups.map(\.hint)).count == groups.count, "every group has its own hint")
        // DNS and connection failures are both "Server nicht erreichbar".
        #expect(Set(groups.map(\.title)).count == groups.count - 1)
        #expect(groups[1].title == groups[2].title)
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

    @Test("a missing upload file reports its path")
    func missingFile() {
        let url = URL(fileURLWithPath: "/tmp/voice-diary/cache/take-1.m4a")
        let d = ConnectionDiagnosis.classify(ServerClientError.missingFile(url))
        #expect(d.kind == .unknown)
        #expect(d.systemImage == "doc.questionmark")
        #expect(d.detail == url.path)
        #expect(d.isRetryable)
    }

    @Test("a direct DecodingError reads like a wrapped decoding failure and keeps its detail")
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
        #expect(d.detail?.contains("bad shape") == true)
    }

    @Test("an arbitrary NSError falls back to the unexpected-error copy with its domain and code")
    func arbitraryNSError() {
        let d = ConnectionDiagnosis.classify(NSError(domain: "VoiceDiaryTests.Arbitrary", code: 42))
        #expect(d.kind == .unknown)
        #expect(d.systemImage == "exclamationmark.triangle.fill")
        #expect(d.isRetryable)
        #expect(d.detail?.contains("VoiceDiaryTests.Arbitrary") == true)
        #expect(d.detail?.contains("42") == true)
    }

    @Test("not-configured, decoding, missing-file and unexpected errors each keep their own copy")
    func localCopyDistinctions() {
        let diagnoses = [
            ConnectionDiagnosis.classify(ServerClientError.notConfigured),
            ConnectionDiagnosis.classify(ServerClientError.decodingFailed("x")),
            ConnectionDiagnosis.classify(ServerClientError.missingFile(URL(fileURLWithPath: "/x"))),
            ConnectionDiagnosis.classify(NSError(domain: "VoiceDiaryTests.Arbitrary", code: 1)),
        ]
        #expect(Set(diagnoses.map(\.title)).count == diagnoses.count)
        #expect(Set(diagnoses.map(\.hint)).count == diagnoses.count)
    }
}
