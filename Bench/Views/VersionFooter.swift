import BenchKit
import SwiftUI

/// The build you're running, in small type at the foot of the sidebar, so
/// telling one build from another never means opening Settings. Click goes
/// to Settings › Updates, where What's New and Check for Updates live.
struct VersionFooter: View {
    @Environment(AppStore.self) private var store
    @State private var hovering = false
    private let version = AppVersion.current

    var body: some View {
        Button {
            store.settingsSection = .updates
        } label: {
            Text(version.footer)
                .font(.ui(size: 10, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(hovering ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 3)
                .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .onHover { hovering = $0 }
        .help(version.help)
        .accessibilityLabel("Workbench \(version.long)")
        .padding(.horizontal, 8)
        .padding(.bottom, 6)
    }
}
