import Foundation

/// The app icons people can pick from in Settings, on the Mac and the phone.
/// Each one's `assetName` matches a `.icon` file: `bench-icon.icon` for the
/// default, and `AppIcons/<assetName>.icon` for the others. Keep this list in
/// step with ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES in project.yml.
public enum AppIconChoice: String, CaseIterable, Identifiable, Sendable {
    case northernLights = "bench-icon"
    case classic = "icon-classic"
    case ultraviolet = "icon-ultraviolet"
    case emberRidge = "icon-ember-ridge"
    case lagoon = "icon-lagoon"
    case coralPop = "icon-coral-pop"

    public static let `default` = AppIconChoice.northernLights

    public var id: String { rawValue }

    public var assetName: String { rawValue }

    /// What iOS calls the icon: nil means the primary icon.
    public var alternateIconName: String? { self == .default ? nil : rawValue }

    public init(alternateIconName: String?) {
        self = alternateIconName.flatMap(AppIconChoice.init(rawValue:)) ?? .default
    }

    public var name: String {
        switch self {
        case .northernLights: "Northern Lights"
        case .classic: "Classic"
        case .ultraviolet: "Ultraviolet"
        case .emberRidge: "Ember Ridge"
        case .lagoon: "Lagoon"
        case .coralPop: "Coral Pop"
        }
    }

    /// A small rendered preview for the picker (made by
    /// scripts/render-icon-previews.sh).
    public var previewURL: URL? {
        Bundle.module.url(forResource: rawValue, withExtension: "png", subdirectory: "IconPreviews")
    }
}
