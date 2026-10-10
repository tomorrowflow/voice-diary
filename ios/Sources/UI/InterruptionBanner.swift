import SwiftUI

/// Notice shown after a system interruption (call / Siri / alarm) cut a
/// recording short (UX-1 / #26). The captured audio is already saved; the
/// banner only tells the user it may end early. `onContinue` is optional —
/// the walkthrough keeps running by itself, so only the quick-capture screen
/// offers a "Continue recording" action (which starts a fresh recording).
struct InterruptionBanner: View {
    var onContinue: (() -> Void)?
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spacing.sm) {
            HStack(alignment: .top, spacing: Theme.spacing.sm) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.color.status.warning)
                    .padding(.top, 2)
                Text(InterruptionNotice.message)
                    .font(Theme.font.caption)
                    .foregroundStyle(Theme.color.text.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            HStack(spacing: Theme.spacing.sm) {
                if let onContinue {
                    Button("Continue recording", action: onContinue)
                        .buttonStyle(.dsPrimary(size: .sm))
                }
                Button("Dismiss", action: onDismiss)
                    .buttonStyle(.dsSecondary(size: .sm))
            }
        }
        .padding(Theme.spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: Theme.radius.md, style: .continuous)
                .fill(Theme.color.status.warning.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radius.md, style: .continuous)
                .strokeBorder(Theme.color.status.warning.opacity(0.30), lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
    }
}
