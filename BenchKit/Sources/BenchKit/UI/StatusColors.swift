import SwiftUI

/// A color as sRGB parts, so contrast can be worked out without a screen.
public struct RGB: Sendable, Equatable {
    public var red: Double
    public var green: Double
    public var blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// `RGB(hex: 0x1A7F37)`.
    public init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }

    public static let white = RGB(red: 1, green: 1, blue: 1)
    public static let black = RGB(red: 0, green: 0, blue: 0)
    public static func gray(_ white: Double) -> RGB { RGB(red: white, green: white, blue: white) }

    public var color: Color { Color(.sRGB, red: red, green: green, blue: blue) }

    /// Relative luminance, as WCAG defines it.
    public var luminance: Double {
        func linear(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }
}

/// The status colors both apps draw text and badges in: one value for a
/// light background and one for a dark one, each readable at 4.5:1 on
/// white or on near-black. Fills behind rows use the same hues at a low
/// opacity, so they aren't here.
public enum StatusColors {
    public struct Pair: Sendable {
        public let light: RGB
        public let dark: RGB

        public init(light: UInt32, dark: UInt32) {
            self.light = RGB(hex: light)
            self.dark = RGB(hex: dark)
        }

        /// Picks the light or dark value for the current appearance.
        public var color: Color { Color(light: light.color, dark: dark.color) }
    }

    /// Claude needs you.
    public static let waiting = Pair(light: 0x9A6400, dark: 0xF2B54A)
    /// Claude is working here.
    public static let working = Pair(light: 0xB9542F, dark: 0xF08A64)
    /// Finished, or a line that was added.
    public static let done = Pair(light: 0x1A7F37, dark: 0x4CC774)
    /// Failed, or a line that was removed.
    public static let failed = Pair(light: 0xCF222E, dark: 0xFF7B6E)
    /// A file that changed.
    public static let modified = Pair(light: 0xA06A00, dark: 0xE5B740)
    /// Work on another Mac, or a renamed file.
    public static let remote = Pair(light: 0x2F6FB5, dark: 0x7DB4F0)

    public static let all: [(name: String, pair: Pair)] = [
        ("waiting", waiting), ("working", working), ("done", done), ("failed", failed), ("modified", modified), ("remote", remote),
    ]

    /// The WCAG contrast ratio between two colors, from 1 to 21.
    public static func contrast(_ a: RGB, on b: RGB) -> Double {
        let (lighter, darker) = a.luminance > b.luminance ? (a.luminance, b.luminance) : (b.luminance, a.luminance)
        return (lighter + 0.05) / (darker + 0.05)
    }
}
