import SwiftUI

// Single entry point for design-system tokens in views.
//
//   Theme.color.bg.surface
//   Theme.color.text.primary
//   Theme.spacing.md            // 16
//   Theme.radius.lg             // 10
//   Theme.font.body
//
// Behind the scenes everything resolves to the auto-generated `DSColor`,
// `DSSemantic`, `DSSpacing`, `DSRadius`, `DSFontSize` enums. Don't reach
// into those directly from feature code — this Theme is the seam.

public enum Theme {
    public static let color   = ColorTokens()
    public static let spacing = SpacingTokens()
    public static let radius  = RadiusTokens()
    public static let font    = FontTokens()
    public static let motion  = MotionTokens()

    // ---------- Colour --------------------------------------------------

    public struct ColorTokens {
        public let text   = TextColors()
        public let fg     = FgColors()
        public let bg     = BgColors()
        public let border = BorderColors()
        public let status = StatusColors()
        public let raw    = RawColors()
    }

    public struct TextColors {
        public let primary   = DSSemantic.Text.primary
        public let secondary = DSSemantic.Text.secondary
        public let subdued   = DSSemantic.Text.subdued
        public let inverse   = DSSemantic.Text.inverse
        public let link      = DSSemantic.Text.link
    }

    public struct FgColors {
        public let primary         = DSSemantic.Fg.primary
        public let primaryVariant  = DSSemantic.Fg.primary_variant
        public let secondary       = DSSemantic.Fg.secondary
        public let secondaryVariant = DSSemantic.Fg.secondary_variant
        public let subdued         = DSSemantic.Fg.subdued
        public let gray            = DSSemantic.Fg.gray
        public let contrast        = DSSemantic.Fg.contrast
        public let inverse         = DSSemantic.Fg.inverse
    }

    public struct BgColors {
        public let surface             = DSSemantic.Bg.surface
        public let surfaceHover        = DSSemantic.Bg.surface_hover
        public let surfaceInset        = DSSemantic.Bg.surface_inset
        public let surfaceInsetHover   = DSSemantic.Bg.surface_inset_hover
        public let container           = DSSemantic.Bg.container
        public let containerHover      = DSSemantic.Bg.container_hover
        public let containerInset      = DSSemantic.Bg.container_inset
        public let containerInsetHover = DSSemantic.Bg.container_inset_hover
        public let inverse             = DSSemantic.Bg.inverse
        public let inverseHover        = DSSemantic.Bg.inverse_hover
        public let overlay             = DSSemantic.Bg.overlay
    }

    public struct BorderColors {
        public let primary     = DSSemantic.Border.primary
        public let secondary   = DSSemantic.Border.secondary
        public let tertiary    = DSSemantic.Border.tertiary
        public let subdued     = DSSemantic.Border.subdued
        public let destructive = DSSemantic.Border.destructive
        public let solid       = DSSemantic.Border.solid
    }

    public struct StatusColors {
        public let success     = DSSemantic.Status.success
        public let warning     = DSSemantic.Status.warning
        public let destructive = DSSemantic.Status.destructive
    }

    /// Raw colour ramps — escape hatch when you need an exact shade.
    public struct RawColors {
        public let white = DSColor.color_white
        public let black = DSColor.color_black
    }

    // ---------- Spacing -------------------------------------------------

    public struct SpacingTokens {
        public let xxs:  CGFloat = DSSpacing.spacing_r1   // 4
        public let xs:   CGFloat = DSSpacing.spacing_r2   // 8
        public let sm:   CGFloat = DSSpacing.spacing_r3   // 12
        public let md:   CGFloat = DSSpacing.spacing_r4   // 16
        public let lg:   CGFloat = DSSpacing.spacing_r5   // 20
        public let xl:   CGFloat = DSSpacing.spacing_r6   // 24
        public let xxl:  CGFloat = DSSpacing.spacing_r8   // 32
        public let xxxl: CGFloat = DSSpacing.spacing_r10  // 40
    }

    public struct RadiusTokens {
        public let none: CGFloat = DSRadius.none
        public let sm:   CGFloat = DSRadius.sm
        public let md:   CGFloat = DSRadius.md
        public let lg:   CGFloat = DSRadius.lg
        public let xl:   CGFloat = DSRadius.xl
        public let xxl:  CGFloat = DSRadius.r2xl
        public let xxxl: CGFloat = DSRadius.r3xl
        public let full: CGFloat = DSRadius.full
    }

    // ---------- Typography ---------------------------------------------

    public struct FontTokens {
        // The bundled variable Geist family. Falls back to system rounded
        // if Geist isn't registered (in tests, previews, etc.).
        public static let sansFamily = "Geist"
        public static let monoFamily = "Geist Mono"

        public var largeTitle: Font { .custom(Self.sansFamily, size: DSFontSize.ios_largeTitle, relativeTo: .largeTitle).weight(.semibold) }
        public var title1:     Font { .custom(Self.sansFamily, size: DSFontSize.ios_title1, relativeTo: .title).weight(.semibold) }
        public var title2:     Font { .custom(Self.sansFamily, size: DSFontSize.ios_title2, relativeTo: .title2).weight(.semibold) }
        public var title3:     Font { .custom(Self.sansFamily, size: DSFontSize.ios_title3, relativeTo: .title3).weight(.medium) }
        public var headline:   Font { .custom(Self.sansFamily, size: DSFontSize.ios_headline, relativeTo: .headline).weight(.semibold) }
        public var body:       Font { .custom(Self.sansFamily, size: DSFontSize.ios_body, relativeTo: .body) }
        public var callout:    Font { .custom(Self.sansFamily, size: DSFontSize.ios_callout, relativeTo: .callout) }
        public var subheadline: Font { .custom(Self.sansFamily, size: DSFontSize.ios_subheadline, relativeTo: .subheadline) }
        public var footnote:   Font { .custom(Self.sansFamily, size: DSFontSize.ios_footnote, relativeTo: .footnote) }
        public var caption:    Font { .custom(Self.sansFamily, size: DSFontSize.ios_caption1, relativeTo: .caption) }
        public var caption2:   Font { .custom(Self.sansFamily, size: DSFontSize.ios_caption2, relativeTo: .caption2) }

        public var monoBody:    Font { .custom(Self.monoFamily, size: DSFontSize.ios_body, relativeTo: .body) }
        public var monoCallout: Font { .custom(Self.monoFamily, size: DSFontSize.ios_callout, relativeTo: .callout) }
        public var monoCaption: Font { .custom(Self.monoFamily, size: DSFontSize.ios_caption1, relativeTo: .caption) }
    }

    // ---------- Motion -------------------------------------------------

    public struct MotionTokens {
        public let fast:    Animation = .easeInOut(duration: 0.15)
        public let `default`: Animation = .easeInOut(duration: 0.30)
        public let slow:    Animation = .easeInOut(duration: 0.50)
        public let snappy:  Animation = .spring(response: 0.30, dampingFraction: 0.78)
        public let soft:    Animation = .spring(response: 0.45, dampingFraction: 0.85)
        public let bouncy:  Animation = .spring(response: 0.55, dampingFraction: 0.65)
    }
}
