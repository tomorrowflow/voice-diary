import Foundation
import Testing
@testable import VoiceDiary

// Classification of the raw dialog-model download failure string. The view
// owns the localized copy; this pins which raw reasons map to which case and
// in which order the checks win.

@Suite("DialogDownloadFailure")
struct DialogDownloadFailureTests {
    @Test("connection-lost aliases", arguments: [
        "Error Domain=NSURLErrorDomain Code=-1005",
        "The network connection was lost.",
        "-1005",
    ])
    func connectionLost(reason: String) {
        #expect(DialogDownloadFailure.classify(reason: reason) == .connectionLost)
    }

    @Test("offline aliases", arguments: [
        "Error Domain=NSURLErrorDomain Code=-1009",
        "The Internet connection: you are not connected to the Internet.",
        "-1009",
    ])
    func offline(reason: String) {
        #expect(DialogDownloadFailure.classify(reason: reason) == .offline)
    }

    @Test("timeout aliases", arguments: [
        "Error Domain=NSURLErrorDomain Code=-1001",
        "The request timed out.",
        "-1001",
    ])
    func timeout(reason: String) {
        #expect(DialogDownloadFailure.classify(reason: reason) == .timeout)
    }

    @Test("empty and unmatched reasons fall through to other, keeping the raw text", arguments: [
        "",
        "disk full",
        "Code=-1000",
        "network connection lost",
    ])
    func other(reason: String) {
        #expect(DialogDownloadFailure.classify(reason: reason) == .other(reason))
    }

    @Test("matching is case-sensitive")
    func caseSensitive() {
        for reason in [
            "The Network Connection Was Lost.",
            "NOT CONNECTED TO THE INTERNET",
            "Timed Out",
        ] {
            #expect(DialogDownloadFailure.classify(reason: reason) == .other(reason))
        }
    }

    @Test("connection-lost wins over offline and timeout")
    func connectionLostPriority() {
        #expect(DialogDownloadFailure.classify(reason: "-1009 -1005 -1001") == .connectionLost)
        #expect(DialogDownloadFailure.classify(reason: "timed out; network connection was lost") == .connectionLost)
        #expect(DialogDownloadFailure.classify(reason: "not connected to the Internet, -1005") == .connectionLost)
    }

    @Test("offline wins over timeout")
    func offlinePriority() {
        #expect(DialogDownloadFailure.classify(reason: "-1001 -1009") == .offline)
        #expect(DialogDownloadFailure.classify(reason: "timed out: not connected to the Internet") == .offline)
    }

    @Test("other preserves the raw reason verbatim")
    func otherPreservesReason() {
        let reason = "  Weird failure: 42 \n second line "
        #expect(DialogDownloadFailure.classify(reason: reason) == .other(reason))
    }
}
