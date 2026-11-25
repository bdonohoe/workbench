import SwiftUI

extension View {
    /// The one look for a text box in a sheet: a hairline edge and no
    /// shadow, darker while typing. The view passes its own padding.
    func flatField(focused: Bool) -> some View {
        background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .strokeBorder(Color.primary.opacity(focused ? 0.3 : 0.12)))
    }
}
