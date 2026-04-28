import SwiftUI

// SwiftUI implementation of `docs/design-system/specs/components/button.json`.
// Five variants × three sizes, with the contractual states baked in
// (default, pressed, disabled). Use via `.buttonStyle(.dsPrimary())` or
// the lower-level `DSButtonStyle(variant:size:)`.

public struct DSButtonStyle: ButtonStyle {
    public enum Variant: Sendable {
        case primary, secondary, outline, ghost, destructive
    }

    public enum Size: Sendable {
        case sm, md, lg
    }

    public let variant: Variant
    public let size: Size
    public let fullWidth: Bool

    public init(variant: Variant = .primary, size: Size = .md, fullWidth: Bool = false) {
        self.variant = variant
        self.size = size
        self.fullWidth = fullWidth
    }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(font)
            .fontWeight(.medium)
            .frame(height: height)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .padding(.horizontal, paddingX)
            .background(background(pressed: configuration.isPressed))
            .foregroundStyle(foreground)
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(borderColor, lineWidth: borderWidth)
            )
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .opacity(configuration.isPressed ? 0.92 : 1.0)
            .animation(Theme.motion.snappy, value: configuration.isPressed)
            .sensoryFeedback(.selection, trigger: configuration.isPressed)
    }

    // ---------- visual mapping per spec ----------

    private var height: CGFloat {
        switch size { case .sm: return 32; case .md: return 40; case .lg: return 48 }
    }

    private var paddingX: CGFloat {
        switch size {
        case .sm: return Theme.spacing.sm    // 12
        case .md: return Theme.spacing.md    // 16
        case .lg: return Theme.spacing.lg    // 20
        }
    }

    private var radius: CGFloat {
        switch size { case .sm, .md: return Theme.radius.md; case .lg: return Theme.radius.lg }
    }

    private var font: Font {
        switch size {
        case .sm, .md: return .system(size: DSFontSize.size_sm, weight: .medium)
        case .lg:      return .system(size: DSFontSize.size_base, weight: .medium)
        }
    }

    @ViewBuilder
    private func background(pressed: Bool) -> some View {
        switch variant {
        case .primary:     pressed ? Theme.color.bg.inverseHover : Theme.color.bg.inverse
        case .secondary:   pressed ? Theme.color.bg.containerHover : Theme.color.bg.container
        case .outline:     pressed ? Theme.color.bg.surfaceHover : Color.clear
        case .ghost:       pressed ? Theme.color.bg.surfaceHover : Color.clear
        case .destructive: pressed ? Theme.color.status.destructive.opacity(0.85) : Theme.color.status.destructive
        }
    }

    private var foreground: Color {
        switch variant {
        case .primary:     return Theme.color.text.inverse
        case .secondary:   return Theme.color.text.primary
        case .outline:     return Theme.color.text.primary
        case .ghost:       return Theme.color.text.primary
        case .destructive: return Theme.color.text.inverse
        }
    }

    private var borderColor: Color {
        switch variant {
        case .secondary: return Theme.color.border.secondary
        case .outline:   return Theme.color.border.primary
        default:         return .clear
        }
    }

    private var borderWidth: CGFloat {
        switch variant {
        case .secondary, .outline: return 1
        default: return 0
        }
    }
}

// Convenience static builders so call sites read like
// `.buttonStyle(.dsPrimary())`.
public extension ButtonStyle where Self == DSButtonStyle {
    static func dsPrimary(size: DSButtonStyle.Size = .md, fullWidth: Bool = false) -> DSButtonStyle {
        DSButtonStyle(variant: .primary, size: size, fullWidth: fullWidth)
    }
    static func dsSecondary(size: DSButtonStyle.Size = .md, fullWidth: Bool = false) -> DSButtonStyle {
        DSButtonStyle(variant: .secondary, size: size, fullWidth: fullWidth)
    }
    static func dsOutline(size: DSButtonStyle.Size = .md, fullWidth: Bool = false) -> DSButtonStyle {
        DSButtonStyle(variant: .outline, size: size, fullWidth: fullWidth)
    }
    static func dsGhost(size: DSButtonStyle.Size = .md, fullWidth: Bool = false) -> DSButtonStyle {
        DSButtonStyle(variant: .ghost, size: size, fullWidth: fullWidth)
    }
    static func dsDestructive(size: DSButtonStyle.Size = .md, fullWidth: Bool = false) -> DSButtonStyle {
        DSButtonStyle(variant: .destructive, size: size, fullWidth: fullWidth)
    }
}
