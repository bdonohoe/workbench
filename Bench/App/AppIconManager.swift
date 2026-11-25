import AppKit
import BenchKit

/// The app icon picked in Settings. macOS has no alternate app icons, so a
/// pick other than the default is drawn onto Workbench.app as a custom Finder
/// icon (which the Dock and Finder show while it's quit) and set as the running
/// app's Dock icon. A Sparkle update replaces the whole app, custom icon and
/// all, so the pick is put back at launch.
///
/// The icon images come from the alternate `.icon` files compiled into the
/// app's asset catalog. Sparkle only reads the installed app's signing
/// identity, which a custom icon leaves alone, so updates still go through.
@MainActor @Observable
final class AppIconManager {
    static let shared = AppIconManager()
    static let key = "appIcon"

    private(set) var choice: AppIconChoice
    /// Set when the app couldn't be changed on disk (for example, it sits in
    /// a folder you can't write to), so only the Dock shows the pick.
    private(set) var dockOnly = false

    private init() {
        choice = AppIconChoice(rawValue: UserDefaults.standard.string(forKey: Self.key) ?? "") ?? .default
    }

    func select(_ new: AppIconChoice) {
        guard new != choice else { return }
        choice = new
        UserDefaults.standard.set(new.rawValue, forKey: Self.key)
        apply(stampBundle: true)
    }

    /// Shows the picked icon in the Dock, and puts it back on the app if an
    /// update took it away.
    func applyAtLaunch() {
        guard choice != .default else { return }
        apply(stampBundle: !hasCustomIcon)
    }

    private func apply(stampBundle: Bool) {
        let image = choice == .default ? nil : Bundle.main.image(forResource: choice.assetName)
        NSApp.applicationIconImage = image
        guard stampBundle, Self.mayStampBundle else { return }
        let path = Bundle.main.bundlePath
        dockOnly = !NSWorkspace.shared.setIcon(image, forFile: path, options: [])
        NSWorkspace.shared.noteFileSystemChanged(path)
    }

    /// codesign refuses to sign an app that has a custom icon ("detritus not
    /// allowed"), so a Debug build leaves its own app alone and the next build
    /// still signs. BENCH_STAMP_APP_ICON=1 turns it on, for testing on a copy.
    private static var mayStampBundle: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment["BENCH_STAMP_APP_ICON"] != nil
        #else
        true
        #endif
    }

    /// Finder keeps a custom folder icon in a file named "Icon\r" inside it.
    private var hasCustomIcon: Bool {
        FileManager.default.fileExists(atPath: (Bundle.main.bundlePath as NSString).appendingPathComponent("Icon\r"))
    }
}
