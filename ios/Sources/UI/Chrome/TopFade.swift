import SwiftUI

/// A 16pt soft surface-coloured fade, drawn as a top overlay so a scroll
/// list dissolves into whatever floats below it (a CTA stack or a pinned
/// counter) instead of cutting hard against it. 16pt reads as "this
/// floats" without burying content.
///
/// Drop it in via `.overlay(alignment: .top) { TopFade() }`. The built-in
/// `-16` offset lifts it just above the anchored content.
public struct TopFade: View {
    public init() {}

    public var body: some View {
        LinearGradient(
            colors: [Theme.color.bg.surface.opacity(0), Theme.color.bg.surface],
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(height: 16)
        .offset(y: -16)
        .allowsHitTesting(false)
    }
}
