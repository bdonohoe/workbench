import Foundation

/// What double-clicking a window's title bar does, from the Mac's setting
/// in System Settings › Desktop & Dock.
public enum TitleBarDoubleClick: Equatable, Sendable {
    case zoom, minimize, nothing

    /// `action` is `AppleActionOnDoubleClick`. Older setups only have
    /// `AppleMiniaturizeOnDoubleClick`, passed as `minimizes`.
    public static func resolve(action: String?, minimizes: Bool) -> TitleBarDoubleClick {
        switch action {
        case "None": .nothing
        case "Minimize": .minimize
        // "Fill" has no public way to do it, and zooming is the closest.
        case "Maximize", "Fill": .zoom
        default: minimizes ? .minimize : .zoom
        }
    }
}
