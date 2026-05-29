import SwiftUI

/// Unified in-flow header used by Walkthrough, TodoConfirm, and the
/// Onboarding steps. Reserves a fixed 32 pt progress row whether or not a
/// progress bar is shown, so titles always sit at the same Y across screens.
///
/// Mirror of the React `FlowHeader` in `docs/claude design/shared.jsx`.
@MainActor
public struct FlowHeader: View {
    // `LocalizedStringKey` so call sites like `FlowHeader(title: "More")`
    // resolve through `Localizable.xcstrings`. Use the
    // `verbatim:` initializer below when the caller already has a
    // localized String (e.g. a date already formatted, or the user's
    // chosen section title from `WalkthroughSettings.generals`).
    public let title: LocalizedStringKey
    public let verbatimTitle: String?
    public let total: Int
    public let current: Int
    public let onClose: (() -> Void)?

    public init(title: LocalizedStringKey,
                total: Int = 0,
                current: Int = 0,
                onClose: (() -> Void)? = nil) {
        self.title = title
        self.verbatimTitle = nil
        self.total = total
        self.current = current
        self.onClose = onClose
    }

    /// Use for titles already in a known concrete string (user-entered
    /// section names, formatted dates) where running through the catalog
    /// would be a no-op or — worse — accidentally match a key.
    public init(verbatim: String,
                total: Int = 0,
                current: Int = 0,
                onClose: (() -> Void)? = nil) {
        self.title = ""
        self.verbatimTitle = verbatim
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
                    .accessibilityLabel(Text("Close"))
                }
            }
            .frame(height: 32)
            .padding(.horizontal, Theme.spacing.md)
            .padding(.top, Theme.spacing.sm)

            // verbatimTitle wins when present (user-entered names, dates);
            // otherwise we hand the LocalizedStringKey to SwiftUI so the
            // catalog lookup fires.
            (verbatimTitle.map { Text(verbatim: $0) } ?? Text(title))
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
