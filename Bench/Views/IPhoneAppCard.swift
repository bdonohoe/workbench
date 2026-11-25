import SwiftUI

/// Points to the iPhone app on the App Store from the bottom of the
/// sidebar. It goes away for good once you open the link, close it, or
/// pair a phone. A new key, so it shows once more for anyone who closed
/// the old TestFlight card.
struct IPhoneAppCard: View {
    static let dismissedKey = "iPhoneAppCard.dismissed"

    @AppStorage(Self.dismissedKey) private var dismissed = false
    /// Set by the companion server the first time any phone pairs.
    @AppStorage("analyticsPhonePaired") private var phonePaired = false
    @Environment(\.openURL) private var openURL

    var body: some View {
        if !dismissed, !phonePaired {
            SidebarCard(symbol: "iphone",
                        title: "Workbench for iPhone",
                        subtitle: "Get it on the App Store",
                        help: "Open the iPhone app on the App Store. The link is also in Settings > Remote Access.",
                        action: {
                            openURL(Companion.appStoreURL)
                            dismiss()
                        },
                        onClose: dismiss)
        }
    }

    private func dismiss() {
        withAnimation(.easeOut(duration: 0.15)) { dismissed = true }
    }
}
