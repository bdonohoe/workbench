import SwiftUI

/// A small capsule with one word in it: "Main", "New", "Default". The word
/// and the soft fill behind it share a tint, so a chip reads as a label,
/// not a button.
struct Chip: View {
    let text: String
    var tint: Color = .secondary
    /// Draws a hairline in the tint around the fill, for a chip on a busy
    /// background where the fill alone would get lost.
    var stroked: Bool = false

    init(_ text: String, tint: Color = .secondary, stroked: Bool = false) {
        self.text = text
        self.tint = tint
        self.stroked = stroked
    }

    var body: some View {
        Text(text)
            .font(Theme.TypeScale.font(Theme.TypeScale.micro, weight: .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(tint.opacity(0.14)))
            .overlay {
                if stroked {
                    Capsule().strokeBorder(tint.opacity(0.35))
                }
            }
    }
}
