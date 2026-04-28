// AUTO-GENERATED. Do not edit by hand.
// Resolves semantic light/dark colour pairs to Color values that
// switch automatically with the system colour scheme.

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

#if canImport(UIKit)
private func dsDynamic(light: Color, dark: Color) -> Color {
    Color(UIColor { traits in
        switch traits.userInterfaceStyle {
        case .dark:  return UIColor(dark)
        default:     return UIColor(light)
        }
    })
}
#else
private func dsDynamic(light: Color, dark: Color) -> Color { light }
#endif

public enum DSSemantic {
    public enum Text {
        public static let primary: Color = dsDynamic(light: Color(red: 0.0902, green: 0.0902, blue: 0.0902, opacity: 1.0000), dark: Color(red: 1.0000, green: 1.0000, blue: 1.0000, opacity: 1.0000))
        public static let secondary: Color = dsDynamic(light: Color(red: 0.4510, green: 0.4510, blue: 0.4510, opacity: 1.0000), dark: Color(red: 0.6196, green: 0.6196, blue: 0.6196, opacity: 1.0000))
        public static let subdued: Color = dsDynamic(light: Color(red: 0.6196, green: 0.6196, blue: 0.6196, opacity: 1.0000), dark: Color(red: 0.3608, green: 0.3608, blue: 0.3608, opacity: 1.0000))
        public static let inverse: Color = dsDynamic(light: Color(red: 1.0000, green: 1.0000, blue: 1.0000, opacity: 1.0000), dark: Color(red: 0.0902, green: 0.0902, blue: 0.0902, opacity: 1.0000))
        public static let link: Color = dsDynamic(light: Color(red: 0.0824, green: 0.4392, blue: 0.9373, opacity: 1.0000), dark: Color(red: 0.1804, green: 0.5647, blue: 0.9804, opacity: 1.0000))
    }
    public enum Fg {
        public static let primary: Color = dsDynamic(light: Color(red: 0.0902, green: 0.0902, blue: 0.0902, opacity: 1.0000), dark: Color(red: 1.0000, green: 1.0000, blue: 1.0000, opacity: 1.0000))
        public static let primary_variant: Color = dsDynamic(light: Color(red: 0.1412, green: 0.1412, blue: 0.1412, opacity: 1.0000), dark: Color(red: 0.9686, green: 0.9686, blue: 0.9686, opacity: 1.0000))
        public static let secondary: Color = dsDynamic(light: Color(red: 0.9686, green: 0.9686, blue: 0.9686, opacity: 1.0000), dark: Color(red: 0.2118, green: 0.2118, blue: 0.2118, opacity: 1.0000))
        public static let secondary_variant: Color = dsDynamic(light: Color(red: 0.9412, green: 0.9412, blue: 0.9412, opacity: 1.0000), dark: Color(red: 0.3608, green: 0.3608, blue: 0.3608, opacity: 1.0000))
        public static let subdued: Color = dsDynamic(light: Color(red: 0.6196, green: 0.6196, blue: 0.6196, opacity: 1.0000), dark: Color(red: 0.4510, green: 0.4510, blue: 0.4510, opacity: 1.0000))
        public static let gray: Color = dsDynamic(light: Color(red: 0.4510, green: 0.4510, blue: 0.4510, opacity: 1.0000), dark: Color(red: 0.6196, green: 0.6196, blue: 0.6196, opacity: 1.0000))
        public static let contrast: Color = dsDynamic(light: Color(red: 0.6196, green: 0.6196, blue: 0.6196, opacity: 1.0000), dark: Color(red: 0.4510, green: 0.4510, blue: 0.4510, opacity: 1.0000))
        public static let inverse: Color = dsDynamic(light: Color(red: 1.0000, green: 1.0000, blue: 1.0000, opacity: 1.0000), dark: Color(red: 0.0902, green: 0.0902, blue: 0.0902, opacity: 1.0000))
    }
    public enum Bg {
        public static let surface: Color = dsDynamic(light: Color(red: 0.9686, green: 0.9686, blue: 0.9686, opacity: 1.0000), dark: Color(red: 0.0431, green: 0.0431, blue: 0.0431, opacity: 1.0000))
        public static let surface_hover: Color = dsDynamic(light: Color(red: 0.9412, green: 0.9412, blue: 0.9412, opacity: 1.0000), dark: Color(red: 0.0902, green: 0.0902, blue: 0.0902, opacity: 1.0000))
        public static let surface_inset: Color = dsDynamic(light: Color(red: 0.9412, green: 0.9412, blue: 0.9412, opacity: 1.0000), dark: Color(red: 0.1412, green: 0.1412, blue: 0.1412, opacity: 1.0000))
        public static let surface_inset_hover: Color = dsDynamic(light: Color(red: 0.9059, green: 0.9059, blue: 0.9059, opacity: 1.0000), dark: Color(red: 0.1412, green: 0.1412, blue: 0.1412, opacity: 1.0000))
        public static let container: Color = dsDynamic(light: Color(red: 1.0000, green: 1.0000, blue: 1.0000, opacity: 1.0000), dark: Color(red: 0.0902, green: 0.0902, blue: 0.0902, opacity: 1.0000))
        public static let container_hover: Color = dsDynamic(light: Color(red: 0.9686, green: 0.9686, blue: 0.9686, opacity: 1.0000), dark: Color(red: 0.1412, green: 0.1412, blue: 0.1412, opacity: 1.0000))
        public static let container_inset: Color = dsDynamic(light: Color(red: 0.9686, green: 0.9686, blue: 0.9686, opacity: 1.0000), dark: Color(red: 0.1412, green: 0.1412, blue: 0.1412, opacity: 1.0000))
        public static let container_inset_hover: Color = dsDynamic(light: Color(red: 0.9412, green: 0.9412, blue: 0.9412, opacity: 1.0000), dark: Color(red: 0.2118, green: 0.2118, blue: 0.2118, opacity: 1.0000))
        public static let inverse: Color = dsDynamic(light: Color(red: 0.1412, green: 0.1412, blue: 0.1412, opacity: 1.0000), dark: Color(red: 1.0000, green: 1.0000, blue: 1.0000, opacity: 1.0000))
        public static let inverse_hover: Color = dsDynamic(light: Color(red: 0.2118, green: 0.2118, blue: 0.2118, opacity: 1.0000), dark: Color(red: 0.9412, green: 0.9412, blue: 0.9412, opacity: 1.0000))
        public static let overlay: Color = dsDynamic(light: Color(red: 0.9412, green: 0.9412, blue: 0.9412, opacity: 0.5000), dark: Color(red: 0.0431, green: 0.0431, blue: 0.0431, opacity: 0.8500))
    }
    public enum Border {
        public static let primary: Color = dsDynamic(light: Color(red: 0.0431, green: 0.0431, blue: 0.0431, opacity: 0.1500), dark: Color(red: 1.0000, green: 1.0000, blue: 1.0000, opacity: 0.2000))
        public static let secondary: Color = dsDynamic(light: Color(red: 0.0431, green: 0.0431, blue: 0.0431, opacity: 0.1000), dark: Color(red: 1.0000, green: 1.0000, blue: 1.0000, opacity: 0.1500))
        public static let tertiary: Color = dsDynamic(light: Color(red: 0.0431, green: 0.0431, blue: 0.0431, opacity: 0.0800), dark: Color(red: 1.0000, green: 1.0000, blue: 1.0000, opacity: 0.1000))
        public static let subdued: Color = dsDynamic(light: Color(red: 0.0431, green: 0.0431, blue: 0.0431, opacity: 0.0500), dark: Color(red: 1.0000, green: 1.0000, blue: 1.0000, opacity: 0.0800))
        public static let destructive: Color = dsDynamic(light: Color(red: 0.9451, green: 0.2118, blue: 0.2118, opacity: 1.0000), dark: Color(red: 0.9294, green: 0.3059, blue: 0.3059, opacity: 1.0000))
        public static let solid: Color = dsDynamic(light: Color(red: 0.0431, green: 0.0431, blue: 0.0431, opacity: 1.0000), dark: Color(red: 1.0000, green: 1.0000, blue: 1.0000, opacity: 1.0000))
    }
    public enum Status {
        public static let success: Color = dsDynamic(light: Color(red: 0.0627, green: 0.6588, blue: 0.3804, opacity: 1.0000), dark: Color(red: 0.0706, green: 0.7176, blue: 0.4157, opacity: 1.0000))
        public static let warning: Color = dsDynamic(light: Color(red: 0.8627, green: 0.4078, blue: 0.0118, opacity: 1.0000), dark: Color(red: 0.9922, green: 0.6902, blue: 0.1333, opacity: 1.0000))
        public static let destructive: Color = dsDynamic(light: Color(red: 0.9255, green: 0.1333, blue: 0.1333, opacity: 1.0000), dark: Color(red: 0.9294, green: 0.3059, blue: 0.3059, opacity: 1.0000))
    }
}
