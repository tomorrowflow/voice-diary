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

    @Test("dateNavigatorGap aliases the 6-point design-system step")
    func dateNavigatorGapIsSixPoints() {
        #expect(Theme.spacing.dateNavigatorGap == DSSpacing.spacing_r1_5)
        #expect(Theme.spacing.dateNavigatorGap == 6)
    }

    @Test("recordedBadgeGap aliases the 6-point design-system step")
    func recordedBadgeGapIsSixPoints() {
        #expect(Theme.spacing.recordedBadgeGap == DSSpacing.spacing_r1_5)
        #expect(Theme.spacing.recordedBadgeGap == 6)
    }

    @Test("recordingLegendGap aliases the 6-point design-system step")
    func recordingLegendGapIsSixPoints() {
        #expect(Theme.spacing.recordingLegendGap == DSSpacing.spacing_r1_5)
        #expect(Theme.spacing.recordingLegendGap == 6)
    }

    @Test("captureBottomReserve keeps the 200-point quick-capture scroll reserve")
    func captureBottomReserveIsTwoHundredPoints() {
        #expect(Theme.spacing.captureBottomReserve == 200)
    }

    @Test("captureContentHeight is the 360-point quick-capture slot")
    func captureContentHeightIs360() {
        #expect(Theme.spacing.captureContentHeight == 360)
    }
}
