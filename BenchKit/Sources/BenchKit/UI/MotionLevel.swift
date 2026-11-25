import SwiftUI

/// How much the app moves on its own: the sparkles on a working row, the
/// spinning glyph, a waiting row's breath. Picked in Settings › Appearance,
/// and the system's Reduce Motion always means `.still`.
///
/// Anything that loops on screen keeps the window server redrawing the
/// window every frame. A working row's sparkles or the start page's glow
/// cost about a third of a core of WindowServer on their own; small marks
/// like the spinner cost little.
public enum MotionLevel: String, CaseIterable, Identifiable, Sendable {
    /// Everything: sparkles, sweeps, pulses and spinners.
    case full
    /// Big areas hold still (a row's sparkles, a waiting row's breath, the
    /// start page's glow) and small marks keep moving, so a working agent
    /// still shows it's alive.
    case calm
    /// Nothing moves on its own. States show as still tints and marks.
    case still

    public static let key = "motionLevel"
    /// What the Mac app uses until a level is picked. Full motion keeps the
    /// window server busy for as long as an agent works, which is too much
    /// to do to everyone who never opened the setting.
    public static let standard = MotionLevel.calm
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .full: "Full"
        case .calm: "Calm"
        case .still: "Still"
        }
    }
}

extension EnvironmentValues {
    /// The motion level in effect, set at each window's root by
    /// `followsMotionSetting()`.
    @Entry public var motionLevel: MotionLevel = .full
}

extension View {
    /// Applies the Motion setting, or `.still` when the system's Reduce
    /// Motion is on, to everything inside.
    public func followsMotionSetting() -> some View { modifier(MotionSetting()) }
}

private struct MotionSetting: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @AppStorage(MotionLevel.key) private var level = MotionLevel.standard

    func body(content: Content) -> some View {
        content.environment(\.motionLevel, systemReduceMotion ? .still : level)
    }
}
