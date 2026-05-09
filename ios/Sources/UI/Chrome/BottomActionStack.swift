import SwiftUI

/// Sticky bottom-anchored action stack. Lays out child buttons in the
/// canonical order — secondary pair on top, primary CTA at the bottom —
/// over a faint surface gradient that lets content scroll behind it
/// without colliding with the buttons.
///
/// Used by Walkthrough, TodoConfirm, Capture, and the start screen.
@MainActor
public struct BottomActionStack<Content: View>: View {
    @ViewBuilder public let content: () -> Content

    public init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    public var body: some View {
        VStack(spacing: Theme.spacing.xs) {
            content()
        }
        .padding(.horizontal, Theme.spacing.md)
        .padding(.top, Theme.spacing.sm)
        .padding(.bottom, Theme.spacing.sm)
        .frame(maxWidth: .infinity)
        // Solid backdrop sits BEHIND the buttons and extends into the
        // bottom safe area so iOS 26's floating tab bar can't reveal
        // scroll content peeking through between the CTA and the tabs.
        // `allowsHitTesting(false)` keeps the surrounding area scrollable
        // — only the buttons themselves intercept taps.
        .background(alignment: .bottom) {
            Theme.color.bg.surface
                .ignoresSafeArea(edges: .bottom)
                .allowsHitTesting(false)
        }
        // Small soft fade ABOVE the stack so the list dissolves into
        // the floating CTA instead of cutting hard against it. 16 pt
        // is enough to read as "this floats" without burying content.
        .overlay(alignment: .top) {
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
}
