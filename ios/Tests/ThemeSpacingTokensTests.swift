import CoreGraphics
import Testing
@testable import VoiceDiary

@Suite("Theme.SpacingTokens")
struct ThemeSpacingTokensTests {

    @Test("xxxs is the 2-point design-system step")
    func xxxsIsTwoPoints() {
        #expect(Theme.spacing.xxxs == DSSpacing.spacing_r0_5)
        #expect(Theme.spacing.xxxs == 2)
    }

    @Test("xxs stays the 4-point design-system step")
    func xxsIsFourPoints() {
        #expect(Theme.spacing.xxs == DSSpacing.spacing_r1)
        #expect(Theme.spacing.xxs == 4)
    }
}
