import SwiftUI

/// The look of one row in the right sidebar's lists (changes, files,
/// artifacts): inset from the panel's edges with rounded corners, a faint
/// fill while the pointer is over it, and the accent behind the one that's
/// selected. The row passes its own content padding; this adds the inset
/// outside the fill so the fill never touches the panel's edge.
struct InspectorRow: ViewModifier {
    let isSelected: Bool
    let isHovering: Bool

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, minHeight: Theme.Layout.listRow, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous).fill(fill))
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
    }

    private var fill: Color {
        if isSelected { return Theme.accent.opacity(0.14) }
        return isHovering ? Theme.Fill.hover : .clear
    }
}

extension View {
    /// Draws this as a row in an inspector list. See `InspectorRow`.
    func inspectorRow(isSelected: Bool, isHovering: Bool) -> some View {
        modifier(InspectorRow(isSelected: isSelected, isHovering: isHovering))
    }
}
