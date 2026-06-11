import SwiftUI

/// Compact dot + text status pill used across Settings screens for state
/// badges (permissions, debug status, wake-word availability). The colour
/// is supplied by the call site (typically `Theme.color.status.*`) and
/// drives the dot, the text, and the 10%-tinted capsule fill — so the pill
/// follows the same dark/light mode rules as the rest of the system.
///
/// `VerlaufView`'s `statusPill(for:)` is a different shape (no dot, tinted
/// background) and is intentionally NOT replaced by this.
public struct DSStatusPill: View {
    public let text: String
    public let color: Color

    public init(text: String, color: Color) {
        self.text = text
        self.color = color
    }

    public var body: some View {
        HStack(spacing: Theme.spacing.xs) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(text)
                .font(Theme.font.caption2.weight(.medium))
                .foregroundStyle(color)
        }
        .padding(.horizontal, Theme.spacing.xs)
        .padding(.vertical, Theme.spacing.xxs)
        .background(
            Capsule().fill(color.opacity(0.10))
        )
    }
}
