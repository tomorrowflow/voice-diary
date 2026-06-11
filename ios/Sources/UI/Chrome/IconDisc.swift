import SwiftUI

/// 36×36 tinted circle holding a play / pause SF Symbol. The play glyph is
/// nudged 1pt right so it reads as optically centred inside the disc; the
/// pause glyph (already symmetric) sits dead centre.
///
/// This is the *visual* only — call sites wrap it in their own `Button`
/// and attach the accessibility label, since the action and label differ
/// per surface (segment row, note row, walkthrough note).
public struct PlayPauseDisc: View {
    public let isPlaying: Bool
    /// SF-symbol / glyph colour.
    public let tint: Color
    /// Disc fill colour (typically a 10%-tint of `tint`).
    public let fill: Color

    public init(isPlaying: Bool, tint: Color, fill: Color) {
        self.isPlaying = isPlaying
        self.tint = tint
        self.fill = fill
    }

    public var body: some View {
        ZStack {
            Circle()
                .fill(fill)
                .frame(width: 36, height: 36)
            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(tint)
                // Optically centre the play glyph inside the disc.
                .offset(x: isPlaying ? 0 : 1)
        }
    }
}
