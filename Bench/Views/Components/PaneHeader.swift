import SwiftUI

/// The row above a pane's content: the name of what's shown, where it
/// lives, an optional badge like "Staged", and the pane's buttons at the
/// trailing edge. Every pane header is the same height so the panes line
/// up when they sit side by side.
struct PaneHeader<Trailing: View>: View {
    let title: String
    var subtitle: String?
    var badge: String? = nil
    @ViewBuilder let trailing: () -> Trailing

    init(title: String, subtitle: String?, badge: String? = nil, @ViewBuilder trailing: @escaping () -> Trailing) {
        self.title = title
        self.subtitle = subtitle
        self.badge = badge
        self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(Theme.TypeScale.font(Theme.TypeScale.ui, weight: .semibold))
                .lineLimit(1)
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(Theme.TypeScale.font(Theme.TypeScale.bodySmall))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            if let badge {
                Text(badge)
                    .font(.caption)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.primary.opacity(0.08)))
            }
            Spacer()
            trailing()
        }
        .padding(.horizontal, 12)
        .frame(height: Theme.Layout.paneHeader)
    }
}
