import SwiftUI

/// Unified in-flow header used by Walkthrough, TodoConfirm, and the
/// Onboarding steps. Reserves a fixed 32 pt progress row whether or not a
/// progress bar is shown, so titles always sit at the same Y across screens.
///
/// Mirror of the React `FlowHeader` in `docs/claude design/shared.jsx`.
@MainActor
public struct FlowHeader: View {
    public let title: String
    public let total: Int
    public let current: Int
    public let onClose: (() -> Void)?

    public init(title: String,
                total: Int = 0,
                current: Int = 0,
                onClose: (() -> Void)? = nil) {
        self.title = title
        self.total = total
        self.current = current
        self.onClose = onClose
    }

    private var hasProgress: Bool { total > 0 }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: Theme.spacing.sm) {
                if hasProgress {
                    HStack(spacing: 6) {
                        ForEach(0 ..< total, id: \.self) { i in
                            Capsule(style: .continuous)
                                .fill(i < current
                                      ? Theme.color.text.primary
                                      : Theme.color.border.subdued)
                                .frame(height: 3)
                        }
                    }
                } else {
                    Spacer()
                }

                if let onClose, hasProgress {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Theme.color.text.subdued)
                    }
                    .accessibilityLabel("Schließen")
                }
            }
            .frame(height: 32)
            .padding(.horizontal, Theme.spacing.md)
            .padding(.top, Theme.spacing.sm)

            Text(title)
                .font(Theme.font.largeTitle)
                .foregroundStyle(Theme.color.text.primary)
                .lineLimit(2)            // cap at 2 lines — TTS speaks
                .truncationMode(.tail)   // the full title anyway
                .minimumScaleFactor(0.85)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Theme.spacing.md)
                .padding(.top, Theme.spacing.lg)
                .padding(.bottom, Theme.spacing.md)
        }
    }
}
