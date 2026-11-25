import BenchKit
import SwiftUI

/// The clickable title above a section that folds away: a chevron, the
/// name, and how much is in it. `count` is a number drawn beside the name
/// ("Staged 3"); `countText` is a phrase drawn at the far edge ("3 of 5",
/// "2 working"). Anything else that belongs at the far edge goes in
/// `trailing`. Padding is the caller's: the Changes headers run the full
/// width of the panel while the Checklist header sits inside a margin.
struct DisclosureHeader<Trailing: View>: View {
    let title: String
    var count: Int? = nil
    var countText: String? = nil
    var insets = EdgeInsets()
    let isCollapsed: Bool
    let toggle: () -> Void
    @ViewBuilder var trailing: () -> Trailing

    init(title: String, count: Int? = nil, countText: String? = nil, insets: EdgeInsets = EdgeInsets(),
         isCollapsed: Bool, toggle: @escaping () -> Void,
         @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }) {
        self.title = title
        self.count = count
        self.countText = countText
        self.insets = insets
        self.isCollapsed = isCollapsed
        self.toggle = toggle
        self.trailing = trailing
    }

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.ui(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                    .animation(Theme.Motion.state, value: isCollapsed)
                Text(title).fontWeight(.semibold).lineLimit(1)
                if let count {
                    Text("\(count)").foregroundStyle(.secondary).monospacedDigit()
                }
                Spacer(minLength: 4)
                if let countText {
                    Text(countText).foregroundStyle(.secondary).monospacedDigit()
                }
                trailing()
            }
            .font(Theme.TypeScale.font(Theme.TypeScale.meta))
            .padding(insets)
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .accessibilityValue(isCollapsed ? "Collapsed" : "Expanded")
    }
}
