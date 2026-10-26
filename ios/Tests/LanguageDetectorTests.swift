import Foundation
import NaturalLanguage
import Testing
@testable import VoiceDiary

/// `LanguageDetector.acceptedCode` is the pure acceptance rule behind `detect`. The tests feed it
/// synthetic hypotheses; they never ask the OS recognizer for a verdict.
@Suite("LanguageDetector acceptance policy")
struct LanguageDetectorTests {

    private typealias Hypotheses = [NLLanguage: Double]

    /// The expression `detect` used inline before the extraction, with `supported` and
    /// `code(for:)` inlined, as the oracle the seam must keep matching.
    private func original(_ hypotheses: Hypotheses, minConfidence: Double) -> String? {
        guard let best = hypotheses.max(by: { $0.value < $1.value }),
              [NLLanguage.german, .english].contains(best.key),
              best.value >= minConfidence
        else { return nil }
        switch best.key {
        case .german:  return "de"
        case .english: return "en"
        default:       return nil
        }
    }

    @Test("no hypotheses: nil")
    func empty() {
        #expect(LanguageDetector.acceptedCode(from: [:], minConfidence: 0.55) == nil)
        #expect(LanguageDetector.acceptedCode(from: [:], minConfidence: 0) == nil)
    }

    @Test("German winner maps to de")
    func germanWinner() {
        #expect(LanguageDetector.acceptedCode(from: [.german: 0.9], minConfidence: 0.55) == "de")
        #expect(LanguageDetector.acceptedCode(from: [.german: 0.8, .english: 0.2], minConfidence: 0.55) == "de")
    }

    @Test("English winner maps to en")
    func englishWinner() {
        #expect(LanguageDetector.acceptedCode(from: [.english: 0.9], minConfidence: 0.55) == "en")
        #expect(LanguageDetector.acceptedCode(from: [.english: 0.7, .german: 0.3], minConfidence: 0.55) == "en")
    }

    @Test("below the threshold: nil")
    func belowThreshold() {
        #expect(LanguageDetector.acceptedCode(from: [.german: 0.54], minConfidence: 0.55) == nil)
        #expect(LanguageDetector.acceptedCode(from: [.english: 0.5, .german: 0.5], minConfidence: 0.55) == nil)
    }

    @Test("equal to the threshold is accepted")
    func atThreshold() {
        #expect(LanguageDetector.acceptedCode(from: [.german: 0.55], minConfidence: 0.55) == "de")
        #expect(LanguageDetector.acceptedCode(from: [.english: 0.55], minConfidence: 0.55) == "en")
    }

    @Test("above the threshold is accepted")
    func aboveThreshold() {
        #expect(LanguageDetector.acceptedCode(from: [.english: 0.56], minConfidence: 0.55) == "en")
        #expect(LanguageDetector.acceptedCode(from: [.german: 1.0], minConfidence: 0.55) == "de")
    }

    @Test("an unsupported maximum rejects the input even with a supported runner-up")
    func unsupportedMaximum() {
        #expect(LanguageDetector.acceptedCode(from: [.dutch: 0.8, .german: 0.7], minConfidence: 0.55) == nil)
        #expect(LanguageDetector.acceptedCode(from: [.french: 0.9, .english: 0.1], minConfidence: 0.05) == nil)
        #expect(LanguageDetector.acceptedCode(from: [.dutch: 0.9], minConfidence: 0.55) == nil)
    }

    @Test("the maximum is chosen before the threshold: a supported runner-up above it does not rescue")
    func maximumBeforeThreshold() {
        // The unsupported maximum (0.6) clears the threshold, the supported runner-up (0.58) too;
        // the verdict still follows the maximum.
        #expect(LanguageDetector.acceptedCode(from: [.dutch: 0.6, .english: 0.58], minConfidence: 0.55) == nil)
    }

    @Test("the minimum confidence is a parameter")
    func customThreshold() {
        #expect(LanguageDetector.acceptedCode(from: [.german: 0.3], minConfidence: 0.3) == "de")
        #expect(LanguageDetector.acceptedCode(from: [.german: 0.3], minConfidence: 0.31) == nil)
        #expect(LanguageDetector.acceptedCode(from: [.german: 0.0], minConfidence: 0.0) == "de")
    }

    @Test("nonfinite confidences behave like the original expression")
    func nonfinite() {
        #expect(LanguageDetector.acceptedCode(from: [.german: .nan], minConfidence: 0.55) == nil)
        #expect(LanguageDetector.acceptedCode(from: [.german: .infinity], minConfidence: 0.55) == "de")
        #expect(LanguageDetector.acceptedCode(from: [.english: -.infinity], minConfidence: 0.55) == nil)
        #expect(LanguageDetector.acceptedCode(from: [.english: 0.9], minConfidence: .nan) == nil)
        #expect(LanguageDetector.acceptedCode(from: [.english: 0.9], minConfidence: -.infinity) == "en")
        #expect(LanguageDetector.acceptedCode(from: [.english: 0.9], minConfidence: .infinity) == nil)

        // Multi-entry cases with NaN depend on dictionary iteration order, which is the original
        // behavior; the same dictionary must give the same verdict through the seam and the oracle.
        let cases: [Hypotheses] = [
            [.german: .nan, .english: 0.9],
            [.english: .nan, .dutch: 0.9],
            [.german: .infinity, .english: .infinity],
            [.dutch: .infinity, .german: 0.9],
            [.german: -.infinity, .english: -.infinity],
        ]
        for hypotheses in cases {
            #expect(LanguageDetector.acceptedCode(from: hypotheses, minConfidence: 0.55)
                    == original(hypotheses, minConfidence: 0.55))
        }
    }

    @Test("exact ties follow the original dictionary max behavior, with no tie-breaker")
    func ties() {
        let tied: [Hypotheses] = [
            [.german: 0.6, .english: 0.6],
            [.english: 0.6, .german: 0.6],
            [.dutch: 0.6, .german: 0.6],
            [.german: 0.6, .dutch: 0.6],
        ]
        for hypotheses in tied {
            #expect(LanguageDetector.acceptedCode(from: hypotheses, minConfidence: 0.55)
                    == original(hypotheses, minConfidence: 0.55))
        }
    }

    @Test("matches the original expression across a grid of synthetic hypotheses")
    func grid() {
        let languages: [NLLanguage] = [.german, .english, .dutch, .french]
        let values: [Double] = [0, 0.3, 0.55, 0.56, 0.9, 1]
        let thresholds: [Double] = [0, 0.55, 0.9, 1]
        for first in languages {
            for second in languages where second != first {
                for a in values {
                    for b in values {
                        for threshold in thresholds {
                            let hypotheses: Hypotheses = [first: a, second: b]
                            #expect(LanguageDetector.acceptedCode(from: hypotheses, minConfidence: threshold)
                                    == original(hypotheses, minConfidence: threshold))
                        }
                    }
                }
            }
        }
    }
}
