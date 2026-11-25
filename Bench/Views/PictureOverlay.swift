import SwiftUI
import BenchKit

/// Lets a picture in any chat open over the whole window, above the
/// sidebar, tabs and terminals, instead of in a small sheet.
private struct PictureOverlay: ViewModifier {
    @State private var shown: ShownPicture?

    func body(content: Content) -> some View {
        content
            .environment(\.showPicture) { picture in shown = picture }
            .overlay {
                if let shown {
                    PictureViewer(shown) { self.shown = nil }
                        .id(shown.id)
                        .ignoresSafeArea()
                }
            }
    }
}

extension View {
    func showsPicturesOverWindow() -> some View { modifier(PictureOverlay()) }
}
