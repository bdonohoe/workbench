import SwiftUI

/// The colors the shared companion views draw with. The phone and the Mac
/// each supply their own through the environment.
public struct CompanionPalette: Sendable {
    public var accent: Color
    /// Text and icons drawn on top of `accent`, like a filled button's label.
    public var onAccent: Color
    public var working: Color
    public var remote: Color
    public var waiting: Color
    public var done: Color
    public var attention: Color
    /// The screen behind everything.
    public var canvas: Color
    /// Cards and panels.
    public var surface: Color
    /// A step up from a surface: code, tool steps, the compose field.
    public var raised: Color
    public var ink: Color
    public var inkMuted: Color
    public var hairline: Color
    /// `Inline code` in the chat, so names and commands stand out from the
    /// words around them even when both use the same font.
    public var code: Color
    /// Darker takes on `working`, `remote` and `waiting`, readable as small
    /// text (a timer) over a row tinted with the lighter ones.
    public var workingInk: Color = Color(light: Color(red: 0.60, green: 0.27, blue: 0.09), dark: Color(red: 0.94, green: 0.63, blue: 0.48))
    public var remoteInk: Color = Color(light: Color(red: 0.16, green: 0.38, blue: 0.66), dark: Color(red: 0.58, green: 0.76, blue: 0.97))
    public var waitingInk: Color = Color(light: Color(red: 0.48, green: 0.34, blue: 0.0), dark: Color(red: 0.95, green: 0.76, blue: 0.31))

    /// Claude Code's own color for inline code, for when there's no
    /// terminal theme to take one from.
    public static let defaultCode = Color(light: Color(red: 0.34, green: 0.41, blue: 0.97),
                                          dark: Color(red: 0.69, green: 0.73, blue: 0.98))

    public init(accent: Color, onAccent: Color = .white, working: Color, remote: Color, waiting: Color, done: Color,
                attention: Color, canvas: Color, surface: Color, raised: Color, ink: Color, inkMuted: Color,
                hairline: Color, code: Color = CompanionPalette.defaultCode) {
        self.code = code
        self.accent = accent
        self.onAccent = onAccent
        self.working = working
        self.remote = remote
        self.waiting = waiting
        self.done = done
        self.attention = attention
        self.canvas = canvas
        self.surface = surface
        self.raised = raised
        self.ink = ink
        self.inkMuted = inkMuted
        self.hairline = hairline
    }

    /// Plain system colors, until a platform supplies its own.
    /// Workbench's own accent, for when no theme gives one: the accent
    /// of its default light theme in light mode, and of its default dark
    /// theme in dark mode. So the plain look matches the themes it ships.
    public static let ownAccent = Color(light: (BuiltInTheme.defaultLight.terminalColors.accent ?? .init(hex: "2563EB")).color,
                                        dark: (BuiltInTheme.defaultDark.terminalColors.accent ?? .init(hex: "7CF0C0")).color)
    /// Text on `ownAccent`: white on the light theme's, the dark theme's
    /// own background on its bright one.
    public static let onOwnAccent = Color(light: .white, dark: BuiltInTheme.defaultDark.background.color)

    public static let system = CompanionPalette(
        accent: ownAccent, onAccent: onOwnAccent,
        working: Color(red: 0.85, green: 0.47, blue: 0.34),
        remote: Color(red: 0.34, green: 0.55, blue: 0.82),
        waiting: Color(red: 0.95, green: 0.68, blue: 0.15),
        done: Color(red: 0.2, green: 0.75, blue: 0.4),
        attention: .blue,
        canvas: .clear,
        surface: Color.primary.opacity(0.04),
        raised: Color.primary.opacity(0.06),
        ink: .primary,
        inkMuted: .secondary,
        hairline: Color.primary.opacity(0.1))

    public func color(for activity: ActivityKind) -> Color? {
        switch activity {
        case .idle: nil
        case .working: working
        case .remoteWorking: remote
        case .waiting: waiting
        case .done: done
        case .attention: attention
        }
    }

    /// The color for a timer or a short label in an activity's color.
    public func ink(for activity: ActivityKind) -> Color {
        switch activity {
        case .working: workingInk
        case .remoteWorking: remoteInk
        case .waiting: waitingInk
        default: .secondary
        }
    }

    public static func label(for activity: ActivityKind) -> String {
        switch activity {
        case .idle: "Idle"
        case .working: "Working"
        case .remoteWorking: "Working on another machine"
        case .waiting: "Needs you"
        case .done: "Done"
        case .attention: "Needs attention"
        }
    }
}

extension TerminalColors.RGB {
    public var color: Color { Color(red: r, green: g, blue: b) }
}

extension CompanionPalette {
    /// This palette's status colors on a terminal theme's background and
    /// text: surfaces a step toward the text color, muted text part way
    /// back toward the background. The Mac's chat and the phone share it.
    public func themed(with colors: TerminalColors) -> CompanionPalette {
        let bg = colors.background, fg = colors.foreground, dark = colors.isDark
        var palette = self
        palette.canvas = bg.color
        palette.surface = bg.mixed(dark ? 0.05 : 0.035, with: fg).color
        palette.raised = bg.mixed(dark ? 0.09 : 0.065, with: fg).color
        palette.ink = fg.color
        palette.inkMuted = bg.mixed(dark ? 0.6 : 0.62, with: fg).color
        palette.hairline = fg.color.opacity(dark ? 0.1 : 0.12)
        if let code = colors.code { palette.code = code.color }
        if let accent = colors.accent {
            palette.accent = accent.color
            palette.onAccent = accent.prefersWhiteText ? .white : bg.mixed(0.15, with: .init(r: 0, g: 0, b: 0)).color
        }
        // The theme's own green and working color, already readable as
        // text on its background, so the timer draws in the same color.
        if let done = colors.done { palette.done = done.color }
        if let working = colors.working {
            palette.working = working.color
            palette.workingInk = working.color
        }
        return palette
    }
}

extension CompanionPalette {
    /// One palette for light mode and another for dark, switching with the
    /// appearance.
    public static func appearance(light: CompanionPalette, dark: CompanionPalette) -> CompanionPalette {
        func pick(_ key: KeyPath<CompanionPalette, Color>) -> Color { Color(light: light[keyPath: key], dark: dark[keyPath: key]) }
        var palette = CompanionPalette(
            accent: pick(\.accent), onAccent: pick(\.onAccent), working: pick(\.working), remote: pick(\.remote),
            waiting: pick(\.waiting), done: pick(\.done), attention: pick(\.attention), canvas: pick(\.canvas),
            surface: pick(\.surface), raised: pick(\.raised), ink: pick(\.ink), inkMuted: pick(\.inkMuted),
            hairline: pick(\.hairline), code: pick(\.code))
        palette.workingInk = pick(\.workingInk)
        palette.remoteInk = pick(\.remoteInk)
        palette.waitingInk = pick(\.waitingInk)
        return palette
    }
}

extension EnvironmentValues {
    @Entry public var companionPalette = CompanionPalette.system
}

/// A filled button in the palette's accent, for the one main action in a
/// card (like "Send Answers"). The system's prominent style takes the
/// platform's accent, which is blue on the Mac, so the shared views use
/// this one and draw in whatever palette they're given.
public struct CompanionProminentButtonStyle: ButtonStyle {
    @Environment(\.companionPalette) private var palette
    @Environment(\.isEnabled) private var isEnabled
    /// True for the Mac's size, to sit beside its Allow and Deny buttons.
    let compact: Bool

    public init(compact: Bool = false) {
        self.compact = compact
    }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(palette.onAccent)
            .padding(.horizontal, compact ? 12 : 14)
            .padding(.vertical, compact ? 6 : 10)
            .background(palette.accent.opacity(configuration.isPressed ? 0.8 : 1),
                        in: RoundedRectangle(cornerRadius: compact ? 7 : 12, style: .continuous))
            .opacity(isEnabled ? 1 : 0.4)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == CompanionProminentButtonStyle {
    /// A filled button in the companion palette's accent.
    public static var companionProminent: CompanionProminentButtonStyle { CompanionProminentButtonStyle() }
}

extension Color {
    /// One color for each appearance.
    public init(light: Color, dark: Color) {
        #if canImport(UIKit)
        // UIKit resolves dynamic colors on whatever thread is rendering, so
        // the provider must not assume the main actor.
        let lightColor = UIColor(light), darkColor = UIColor(dark)
        self.init(uiColor: UIColor { @Sendable traits in
            traits.userInterfaceStyle == .dark ? darkColor : lightColor
        })
        #else
        let lightColor = NSColor(light), darkColor = NSColor(dark)
        self.init(nsColor: NSColor(name: nil) { @Sendable appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? darkColor : lightColor
        })
        #endif
    }
}

/// "84k" or "1.2M".
public func shortTokens(_ tokens: Int) -> String {
    switch tokens {
    case ..<1000: "\(tokens)"
    case ..<1_000_000: "\(Int((Double(tokens) / 1000).rounded()))k"
    default: String(format: "%.1fM", Double(tokens) / 1_000_000)
    }
}

extension String {
    /// Swift's hashValue changes between launches, so use a simple fixed
    /// hash. The same on every platform, so project colors match.
    public var hashValueStable: Int {
        var hash = 5381
        for byte in utf8 { hash = (hash &* 33) &+ Int(byte) }
        return hash
    }
}
