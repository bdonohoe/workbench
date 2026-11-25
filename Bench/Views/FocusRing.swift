import AppKit
import BenchKit
import SwiftUI

/// The color of the ring around the side of a split you're typing in.
/// Most choices are slots in the terminal theme's palette rather than fixed
/// colors, so the ring changes with the theme, light or dark.
enum FocusRingColor: String, CaseIterable, Identifiable {
    // Blue first: it's the default, and the one theme colors most often
    // reserve for highlights.
    case blue, magenta, cyan, green, yellow, red
    /// The theme's cursor color.
    case cursor
    /// The Mac's accent color, from System Settings.
    case system

    static let key = "focusRingColor"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "Mac Accent Color"
        case .cursor: "Cursor"
        case .blue: "Blue"
        case .magenta: "Magenta"
        case .cyan: "Cyan"
        case .green: "Green"
        case .yellow: "Yellow"
        case .red: "Red"
        }
    }

    /// The color's place in the 16 ANSI colors (its normal version).
    var ansiIndex: Int? {
        switch self {
        case .red: 1
        case .green: 2
        case .yellow: 3
        case .blue: 4
        case .magenta: 5
        case .cyan: 6
        case .system, .cursor: nil
        }
    }

    /// Used when there's no theme to read, like before the first terminal
    /// starts. The system colors already adjust for light and dark.
    fileprivate var fallback: NSColor {
        switch self {
        case .system: .controlAccentColor
        case .cursor: .labelColor
        case .blue: .systemBlue
        case .magenta: .systemPurple
        case .cyan: .systemTeal
        case .green: .systemGreen
        case .yellow: .systemYellow
        case .red: .systemRed
        }
    }
}

extension TerminalTheme {
    /// The ring color for a choice, taken from the terminal theme where it
    /// can be. The terminal always uses its theme, even with "Match the
    /// terminal theme" off, so the ring follows it either way.
    func focusRing(_ choice: FocusRingColor) -> Color {
        choice == .system ? .accentColor : Color(nsColor: focusRingNSColor(choice))
    }

    /// True when a choice's color comes from the Ghostty theme.
    func focusRingIsFromTheme(_ choice: FocusRingColor) -> Bool {
        switch choice {
        case .system: false
        case .cursor: cursor != nil || foreground != nil
        default: ansi.count >= 16
        }
    }

    private func focusRingNSColor(_ choice: FocusRingColor) -> NSColor {
        readableThemeColor(choice, contrast: 3)
    }

    /// A theme color with at least `contrast` against the terminal
    /// background: 3 for lines like the ring, 4.5 for text.
    func readableThemeColor(_ choice: FocusRingColor, contrast: Double) -> NSColor {
        let color = themeColor(choice)
        guard choice != .system, let background else { return color }
        return Self.readable(color, on: background, contrast: contrast)
    }

    private func themeColor(_ choice: FocusRingColor) -> NSColor {
        switch choice {
        case .system:
            return .controlAccentColor
        case .cursor:
            // Themes without a cursor color draw it in the text color.
            return cursor ?? foreground ?? choice.fallback
        default:
            guard let index = choice.ansiIndex, ansi.count >= 16 else { return choice.fallback }
            let normal = ansi[index], bright = ansi[index + 8]
            guard let background else { return bright }
            // Bright versions stand out on dark themes and normal ones on
            // light themes. If the usual pick nearly disappears into this
            // theme's background, use whichever of the two shows up better.
            let dark = Self.luminance(background) < 0.5
            let preferred = dark ? bright : normal, other = dark ? normal : bright
            let contrast = Self.contrast(preferred, background)
            return contrast < 1.8 && Self.contrast(other, background) > contrast ? other : preferred
        }
    }

    /// A thin line needs about 3:1 contrast to be seen, and text 4.5:1.
    /// Light themes' yellows and cursors often fall short, so this deepens
    /// the color (or lightens it on a dark theme) just enough, keeping its
    /// hue.
    private static func readable(_ color: NSColor, on background: NSColor, contrast wanted: Double) -> NSColor {
        guard contrast(color, background) < wanted else { return color }
        let toward: NSColor = luminance(background) < 0.5 ? .white : .black
        var fraction: CGFloat = 0.1
        while fraction <= 0.7 {
            if let mixed = color.blended(withFraction: fraction, of: toward), contrast(mixed, background) >= wanted { return mixed }
            fraction += 0.1
        }
        return color.blended(withFraction: 0.7, of: toward) ?? color
    }

    /// Relative luminance, as WCAG defines it.
    private static func luminance(_ color: NSColor) -> Double {
        guard let c = color.usingColorSpace(.sRGB) else { return 0.5 }
        func channel(_ value: CGFloat) -> Double {
            let v = Double(value)
            return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(c.redComponent) + 0.7152 * channel(c.greenComponent) + 0.0722 * channel(c.blueComponent)
    }

    private static func contrast(_ a: NSColor, _ b: NSColor) -> Double {
        let (x, y) = (luminance(a), luminance(b))
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }
}

/// Settings: a row of swatches for the ring, drawn on the terminal's own
/// background so you can see how each one will look.
struct FocusRingPicker: View {
    @Binding var selection: FocusRingColor

    var body: some View {
        let theme = TerminalTheme.shared
        HStack(spacing: 8) {
            ForEach(FocusRingColor.allCases) { choice in
                let selected = choice == selection
                Button {
                    selection = choice
                } label: {
                    Circle()
                        .fill(theme.focusRing(choice))
                        .frame(width: 16, height: 16)
                        .overlay {
                            if choice == .system {
                                // Marks the one swatch that isn't from the theme.
                                Image(systemName: "apple.logo")
                                    .font(.ui(size: 8, weight: .bold))
                                    .foregroundStyle(.white.opacity(0.9))
                            }
                        }
                        .padding(3)
                        .overlay(Circle().strokeBorder(theme.focusRing(choice), lineWidth: selected ? 2 : 0))
                        .contentShape(Circle())
                }
                .buttonStyle(.pressable)
                .help(help(for: choice))
                .accessibilityLabel(choice.title)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: theme.background ?? .textBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.1))
        )
        .fixedSize()
    }

    private func help(for choice: FocusRingColor) -> String {
        switch choice {
        case .system: "Your Mac's accent color, from System Settings"
        case .cursor: "Your terminal theme's cursor color"
        default: TerminalTheme.shared.focusRingIsFromTheme(choice) ? "\(choice.title) from your terminal theme" : choice.title
        }
    }
}
