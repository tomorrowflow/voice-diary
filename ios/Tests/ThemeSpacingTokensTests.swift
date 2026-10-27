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

    @Test("progressGap aliases the 6-point design-system step")
    func progressGapIsSixPoints() {
        #expect(Theme.spacing.progressGap == DSSpacing.spacing_r1_5)
        #expect(Theme.spacing.progressGap == 6)
    }

    @Test("recordingLegendGap aliases the 6-point design-system step")
    func recordingLegendGapIsSixPoints() {
        #expect(Theme.spacing.recordingLegendGap == DSSpacing.spacing_r1_5)
        #expect(Theme.spacing.recordingLegendGap == 6)
    }
}
