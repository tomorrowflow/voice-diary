import SwiftUI

/// The standard card chrome: a `bg.container` rounded rectangle at
/// `radius.lg` with a 1pt `border.subdued` stroke. Repeated across the
/// Settings screens; factor it through this modifier so the card look has
/// a single definition.
///
/// Cards with a different fill (destructive error cards, `containerInset`,
/// success-tinted confirmations) keep their bespoke styling — only the
/// exact `bg.container` + `border.subdued` + `radius.lg` combination is
/// covered here.
public struct DSCardModifier: ViewModifier {
    public init() {}

    public func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: Theme.radius.lg, style: .continuous)
                    .fill(Theme.color.bg.container)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.radius.lg, style: .continuous)
                    .strokeBorder(Theme.color.border.subdued, lineWidth: 1)
            )
    }
}

public extension View {
    /// Applies the standard card background + subdued border.
    /// See `DSCardModifier`.
    func dsCard() -> some View {
        modifier(DSCardModifier())
    }
}
