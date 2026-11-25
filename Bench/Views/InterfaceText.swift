import SwiftUI

/// How big the app's own text is: the sidebar, tabs, panels, Settings and
/// everything else outside a conversation. Chosen in Settings › Appearance.
/// The chat has a size of its own (`ChatTypography`), and the terminal uses
/// the Ghostty config.
@MainActor
@Observable
final class InterfaceText {
    static let shared = InterfaceText()
    static let scaleKey = "interfaceTextScale"

    enum Size: Double, CaseIterable, Identifiable {
        case smaller = 0.9
        case standard = 1
        case larger = 1.15
        case largest = 1.3

        var id: Double { rawValue }
        var title: String {
            switch self {
            case .smaller: "Smaller"
            case .standard: "Default"
            case .larger: "Larger"
            case .largest: "Largest"
            }
        }
    }

    var size: Size {
        didSet { UserDefaults.standard.set(size.rawValue, forKey: Self.scaleKey) }
    }

    /// 1 is the usual size.
    var scale: CGFloat { size.rawValue }

    private init() {
        size = Size(rawValue: UserDefaults.standard.double(forKey: Self.scaleKey)) ?? .standard
    }
}

extension Font {
    /// The system font at a size given for the default text size, scaled to
    /// the size chosen in Settings › Appearance. Used in a view's body, the
    /// view redraws when that choice changes.
    static func ui(size: CGFloat, weight: Font.Weight? = nil, design: Font.Design? = nil) -> Font {
        .system(size: (size * InterfaceText.shared.scale).rounded(.toNearestOrEven), weight: weight, design: design)
    }
}
