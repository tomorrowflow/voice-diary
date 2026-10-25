import Foundation
import Testing
@testable import VoiceDiary

// Numeric rule behind the Gemma download bar in DialogModelSettingsView:
// how a `Progress.fractionCompleted` is shown and when completed bytes
// count as forward movement. The view keeps the raw byte counts, the
// timestamps and the stall handling.

@Suite("DialogDownloadProgress")
struct DialogDownloadProgressTests {
    @Test("a finite fraction is clamped to 0...1",
          arguments: [
            (-0.5, 0.0),
            (-Double.leastNonzeroMagnitude, 0.0),
            (0.0, 0.0),
            (0.25, 0.25),
            (1.0, 1.0),
            (1.5, 1.0),
            (Double.greatestFiniteMagnitude, 1.0),
            (-Double.greatestFiniteMagnitude, 0.0),
          ])
    func finiteFraction(raw: Double, expected: Double) {
        #expect(DialogDownloadProgress.normalizedFraction(raw) == expected)
    }

    @Test("NaN and both infinities become zero",
          arguments: [Double.nan, Double.infinity, -Double.infinity])
    func nonFiniteFraction(raw: Double) {
        #expect(DialogDownloadProgress.normalizedFraction(raw) == 0)
    }

    @Test("negative zero stays a zero")
    func negativeZero() {
        #expect(DialogDownloadProgress.normalizedFraction(-0.0) == 0)
    }

    @Test("only strictly more completed bytes than before is an advance",
          arguments: [
            (Int64(101), Int64(100), true),
            (Int64(100), Int64(100), false),
            (Int64(99), Int64(100), false),
            (Int64(1), Int64(0), true),
            (Int64(0), Int64(0), false),
            (Int64(0), Int64(-1), true),
            (Int64(-1), Int64(0), false),
          ])
    func advancement(completed: Int64, previous: Int64, expected: Bool) {
        #expect(DialogDownloadProgress.advanced(completed: completed, previous: previous) == expected)
    }

    @Test("Int64 boundaries are compared without subtracting")
    func int64Boundaries() {
        #expect(DialogDownloadProgress.advanced(completed: .max, previous: .min))
        #expect(!DialogDownloadProgress.advanced(completed: .min, previous: .max))
        #expect(DialogDownloadProgress.advanced(completed: .max, previous: .max - 1))
        #expect(!DialogDownloadProgress.advanced(completed: .max, previous: .max))
        #expect(!DialogDownloadProgress.advanced(completed: .min, previous: .min))
        #expect(DialogDownloadProgress.advanced(completed: .min + 1, previous: .min))
    }
}
