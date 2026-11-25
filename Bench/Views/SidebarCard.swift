import BenchKit
import SwiftUI

/// A small note at the bottom of the sidebar: an icon, two lines of text,
/// and a close button. Clicking the card does `action`.
struct SidebarCard: View {
    let symbol: String
    let title: String
    let subtitle: String
    var help: String?
    let action: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Button(action: action) {
                HStack(spacing: 6) {
                    Image(systemName: symbol)
                        .foregroundStyle(Theme.accent)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title)
                            .font(.ui(size: 12, weight: .semibold))
                        Text(subtitle)
                            .font(.ui(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.pressable)
            .help(help ?? "")

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.ui(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.pressable)
            .help("Hide")
            .accessibilityLabel("Hide")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
        .transition(.opacity)
    }
}

/// Right after an update, says so and opens What's New when clicked.
/// Lasts only for this launch.
struct UpdatedCard: View {
    @Environment(WhatsNew.self) private var whatsNew
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if whatsNew.showsUpdatedCard {
            SidebarCard(symbol: "sparkles",
                        title: "Updated to Workbench \(Self.version)",
                        subtitle: "See what's new",
                        help: "See what changed in this update",
                        action: { openWindow(id: "whats-new") },
                        onClose: hide)
        }
    }

    private func hide() {
        withAnimation(.easeOut(duration: 0.15)) { whatsNew.showsUpdatedCard = false }
    }

    private static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
}
