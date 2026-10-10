import SwiftUI

/// Large `MM:SS` display counter shared by the drive-by Aufnahme screen
/// (`CaptureView.recordingBody`) and the walkthrough listening counter.
/// Both screens read as the same component at the same vertical position,
/// so they share one definition instead of two manually-synced copies.
///
/// The 64pt size is a deliberate display dimension (not part of the text
/// ramp); it and the 80pt slot height are base values that scale with
/// Dynamic Type (relative to `.largeTitle`). The slot height keeps the
/// counter from jumping the surrounding layout as the digits change, and
/// scales in step with the font so enlarged digits are never clipped. At
/// the largest accessibility sizes the digits shrink to fit the width
/// instead of overflowing. Both live here, once.
public struct DisplayTimer: View {
    public let seconds: Int

    @ScaledMetric(relativeTo: .largeTitle) private var fontSize: CGFloat = 64
    @ScaledMetric(relativeTo: .largeTitle) private var slotHeight: CGFloat = 80

    public init(seconds: Int) {
        self.seconds = seconds
    }

    public var body: some View {
        Text(String(format: "%02d:%02d", seconds / 60, seconds % 60))
            .font(.system(size: fontSize, weight: .regular, design: .monospaced))
            .foregroundStyle(Theme.color.text.primary)
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .frame(maxWidth: .infinity)
            .frame(height: slotHeight)
    }
}
