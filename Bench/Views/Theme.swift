import AppKit
import BenchKit
import SwiftUI

/// Bench's own colors, sizes and timings, so the app stays neutral no matter
/// which accent color is chosen in System Settings and so every view draws
/// from the same small set of values.
enum Theme {
    /// Corner radii, smallest to largest.
    enum Radius {
        /// Tags, badges and keycaps.
        static let chip: CGFloat = 4
        /// Buttons, fields and tabs.
        static let control: CGFloat = 6
        /// Selected or hovered rows.
        static let row: CGFloat = 9
        /// Cards, banners and popovers.
        static let card: CGFloat = 10
        /// The floating dock and sheets.
        static let dock: CGFloat = 14
    }

    /// The six text sizes the app uses. `font(_:weight:)` builds one.
    enum TypeScale {
        /// Badges and counts.
        static let micro: CGFloat = 10
        /// Captions, timestamps and secondary labels.
        static let meta: CGFloat = 11
        /// Dense lists, tabs and chips.
        static let bodySmall: CGFloat = 12
        /// Standard controls and body text.
        static let ui: CGFloat = 13
        /// Section and sheet titles.
        static let title: CGFloat = 15
        /// Page headings.
        static let page: CGFloat = 22

        static func font(_ size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> Font {
            .ui(size: size, weight: weight, design: design)
        }
    }

    /// Translucent fills over whatever is behind, for hover and selection.
    enum Fill {
        static let hover = Color.primary.opacity(0.05)
        static let pressed = Color.primary.opacity(0.09)
        static let selected = Color.primary.opacity(0.10)
        /// A barely-there background for grouped content.
        static let subtle = Color.primary.opacity(0.045)
        /// Dividers and outlines.
        static let hairline = Color.primary.opacity(0.08)
    }

    /// Animation timings by what is changing.
    enum Motion {
        /// Hover highlights: quick enough to feel like a response, not a transition.
        static let hover = Animation.easeOut(duration: 0.12)
        /// A control changing state (a toggle, a selection).
        static let state = Animation.snappy(duration: 0.2)
        /// Layout moving around (panels, rows appearing).
        static let layout = Animation.smooth(duration: 0.3)
        /// Tabs opening and closing, and the others making room: quick,
        /// with a touch of give at the end.
        static let tab = Animation.snappy(duration: 0.28, extraBounce: 0.06)
    }

    /// Status colors for text and badges. Each reads at 4.5:1 on a light or
    /// a dark background, which the plain `.green`/`.yellow` system colors
    /// don't. Backgrounds behind sidebar rows keep their own fills in
    /// `ActivityBackground`.
    enum Status {
        static let waiting = StatusColors.waiting.color
        static let working = StatusColors.working.color
        static let done = StatusColors.done.color
        static let failed = StatusColors.failed.color
        static let modified = StatusColors.modified.color
        static let remote = StatusColors.remote.color
        /// A bell or notification: a status, not the app accent.
        static let attention = Color.blue

        /// A soft background in a status color, for pills and banners.
        static func fill(_ color: Color) -> Color { color.opacity(0.12) }
    }

    /// Fixed heights that bars and rows share across panels.
    enum Layout {
        /// Tab bars and the title row.
        static let barHeight: CGFloat = 38
        /// A pane's header row.
        static let paneHeader: CGFloat = 34
        /// A dense list row.
        static let listRow: CGFloat = 22
    }

    /// A graphite accent: dark gray in light mode, light gray in dark mode.
    /// Used for selection and prominent buttons.
    static let accent = Color(nsColor: NSColor(name: "BenchAccent") { appearance in
        appearance.isDark
            ? NSColor(srgbRed: 0.82, green: 0.82, blue: 0.84, alpha: 1)
            : NSColor(srgbRed: 0.24, green: 0.24, blue: 0.26, alpha: 1)
    })

    /// Text and icons drawn on top of `accent`.
    static let onAccent = Color(nsColor: NSColor(name: "BenchOnAccent") { appearance in
        appearance.isDark ? .black : .white
    })
}

/// A filled button in the neutral accent, for the main action in a spot
/// (like "Send to Claude"). Replaces `.borderedProminent`, which is blue.
struct ProminentButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.ui(size: 12, weight: .medium))
            .foregroundStyle(Theme.onAccent)
            .lineLimit(1)
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Theme.accent.opacity(configuration.isPressed ? 0.75 : 1))
            )
            .opacity(isEnabled ? 1 : 0.4)
    }
}

extension ButtonStyle where Self == ProminentButtonStyle {
    static var prominent: ProminentButtonStyle { ProminentButtonStyle() }
}

/// A switch in Bench's colors. The system switch always draws a white knob,
/// which disappears against the light graphite accent in dark mode, and its
/// tint can resolve for the system's appearance instead of the window's when
/// the terminal theme makes them differ. This one picks its colors from the
/// view's own light or dark setting.
struct BenchSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        BenchSwitch(configuration: configuration)
    }
}

/// The switch itself. A view of its own, rather than the style's body, so
/// it can watch keyboard focus and draw the ring.
private struct BenchSwitch: View {
    let configuration: ToggleStyleConfiguration
    @Environment(\.colorScheme) private var scheme
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.labelsVisibility) private var labelsVisibility
    @FocusState private var isFocused: Bool

    var body: some View {
        let isOn = configuration.isOn
        let dark = scheme == .dark
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(spacing: 8) {
                // A custom style gets the label even under `labelsHidden()`,
                // so leave it out here. The toggle still speaks it.
                if labelsVisibility != .hidden {
                    configuration.label
                }
                ZStack(alignment: isOn ? .trailing : .leading) {
                    Capsule()
                        .fill(isOn ? Color(white: dark ? 0.86 : 0.22) : Color.primary.opacity(dark ? 0.18 : 0.12))
                    Capsule()
                        .fill(isOn ? Color(white: dark ? 0.12 : 1) : Color(white: dark ? 0.78 : 1))
                        .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
                        .frame(width: 20, height: 14)
                        .padding(2)
                }
                .frame(width: 36, height: 18)
                .overlay {
                    // The keyboard focus ring, in the system's color so it
                    // matches the one on the pickers and buttons nearby. The
                    // plain button's own ring is a rectangle around the whole
                    // label, so it's turned off below and drawn here instead.
                    if isFocused {
                        Capsule()
                            .strokeBorder(Color(nsColor: .keyboardFocusIndicatorColor), lineWidth: 2.5)
                            .padding(-3.5)
                    }
                }
                .animation(.snappy(duration: 0.2), value: isOn)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // The button already takes keyboard focus with Full Keyboard Access
        // on, and Space presses it. This only watches that focus.
        .focused($isFocused)
        .focusEffectDisabled()
        .opacity(isEnabled ? 1 : 0.45)
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityAddTraits(.isToggle)
    }
}

extension ToggleStyle where Self == BenchSwitchStyle {
    /// A switch in Bench's own colors, legible in light and dark.
    static var benchSwitch: BenchSwitchStyle { BenchSwitchStyle() }
}

extension ChangeKind {
    /// The color a file's change kind is drawn in, everywhere a file is listed.
    var color: Color {
        switch self {
        case .added, .untracked: Theme.Status.done
        case .deleted: Theme.Status.failed
        case .conflicted: Theme.Status.working
        case .renamed, .copied: Theme.Status.remote
        case .modified, .typeChanged: Theme.Status.modified
        }
    }
}
