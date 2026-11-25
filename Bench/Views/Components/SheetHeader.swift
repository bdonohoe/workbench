import SwiftUI

/// The title at the top of a sheet, with a line under it saying what the
/// sheet does. Every sheet uses this so they all start the same way.
struct SheetHeader: View {
    let title: String
    var detail: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(Theme.TypeScale.font(Theme.TypeScale.title, weight: .semibold))
            if let detail {
                Text(detail)
                    .font(Theme.TypeScale.font(Theme.TypeScale.bodySmall))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
