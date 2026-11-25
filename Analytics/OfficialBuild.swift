import Foundation
#if os(macOS)
import Security
#endif

/// Whether this copy of Workbench was built and signed by its developer,
/// as opposed to built by someone else from the source code.
///
/// Only official builds follow the update feed and send analytics. A copy
/// built from source would otherwise be replaced by the next official
/// release (Sparkle sees the same feed and key in its Info.plist), and its
/// usage would land in the developer's PostHog project.
///
/// On the Mac, the app has to be signed by the developer's team, which
/// covers the published releases and the developer's own `make install`
/// copies. On the iPhone, the bundle id has to be the developer's: anyone
/// else installing on a device has to register a bundle id of their own.
enum OfficialBuild {
    /// The developer team that signs Workbench's releases.
    nonisolated static let teamIdentifier = "ZPU7B69KH3"
    /// The iPhone app's bundle id in the App Store.
    nonisolated static let phoneBundleIdentifier = "me.birchtree.BenchPhone"

    nonisolated static let isOfficial: Bool = {
        #if os(macOS)
        return signingTeam == teamIdentifier
        #else
        return Bundle.main.bundleIdentifier == phoneBundleIdentifier
        #endif
    }()

    #if os(macOS)
    /// The team in the running app's code signature. Nil when it's signed
    /// ad hoc or not at all.
    nonisolated static var signingTeam: String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let info = info as? [String: Any] else { return nil }
        return info[kSecCodeInfoTeamIdentifier as String] as? String
    }
    #endif
}
