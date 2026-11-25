import BenchKit
import SwiftUI

/// A soft accent-tinted note with a symbol, a sentence, and room for one
/// button and a close mark: "Workbench found another account". It fills
/// the width it's given; the caller adds any margin around it.
struct InfoBanner: View {
    let symbol: String
    let text: String
    /// One button at the trailing edge, like "Choose Projects…".
    var action: (label: String, run: () -> Void)? = nil
    /// Shows a close mark that calls this.
    var dismiss: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.ui(size: 14))
                .foregroundStyle(Theme.accent)
            Text(text)
                .font(Theme.TypeScale.font(Theme.TypeScale.bodySmall))
                .fixedSize(horizontal: false, vertical: true)
            if action != nil || dismiss != nil {
                Spacer(minLength: 8)
            }
            if let action {
                Button(action.label, action: action.run)
                    .controlSize(.small)
            }
            if let dismiss {
                Button(action: dismiss) {
                    Image(systemName: "xmark")
                        .font(.ui(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.pressable)
                .help("Dismiss")
                .accessibilityLabel("Dismiss")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).fill(Theme.accent.opacity(0.08)))
        // When the window works out how small it can get, it measures this
        // at almost no width, where the wrapping text reports a height of
        // thousands of points. Above a chat, that pushed the whole pane,
        // message box and all, below the bottom of the window. A floor on
        // the width keeps the measurement sane, and the outer frame asks
        // the window for no minimum width at all (see ChatBody's dock).
        .frame(minWidth: 260)
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
    }
}
