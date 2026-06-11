import SwiftUI

/// Large `MM:SS` display counter shared by the drive-by Aufnahme screen
/// (`CaptureView.recordingBody`) and the walkthrough listening counter.
/// Both screens read as the same component at the same vertical position,
/// so they share one definition instead of two manually-synced copies.
///
/// The 64pt size is a deliberate display dimension (not part of the text
/// ramp) and the 80pt slot height keeps the counter from jumping the
/// surrounding layout as the digits change. Both live here, once.
public struct DisplayTimer: View {
    public let seconds: Int

    public init(seconds: Int) {
        self.seconds = seconds
    }

    public var body: some View {
        Text(String(format: "%02d:%02d", seconds / 60, seconds % 60))
            .font(.system(size: 64, weight: .regular, design: .monospaced))
            .foregroundStyle(Theme.color.text.primary)
            .monospacedDigit()
            .frame(maxWidth: .infinity)
            .frame(height: 80)
    }
}
