import AppKit
import BenchKit
import SwiftUI

/// Makes the empty space behind a row at the top of the window act like the
/// title bar: drag it to move the window, and double-click it for whatever
/// the Mac's title bar setting says. Controls in front keep their clicks.
struct WindowTitleArea: NSViewRepresentable {
    func makeNSView(context: Context) -> AreaView { AreaView() }
    func updateNSView(_ view: AreaView, context: Context) {}

    final class AreaView: NSView {
        // This view moves the window itself, so AppKit shouldn't too.
        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            guard event.clickCount == 2 else {
                window.performDrag(with: event)
                return
            }
            guard !window.styleMask.contains(.fullScreen) else { return }
            let defaults = UserDefaults.standard
            switch TitleBarDoubleClick.resolve(action: defaults.string(forKey: "AppleActionOnDoubleClick"),
                                               minimizes: defaults.bool(forKey: "AppleMiniaturizeOnDoubleClick")) {
            case .zoom: window.zoom(nil)
            case .minimize: window.miniaturize(nil)
            case .nothing: break
            }
        }
    }
}

/// A sideways scroll view for a row at the top of the window. Its empty
/// space acts like the title bar too, which takes content at least as wide
/// as the row, since the scroll view would otherwise keep those clicks.
struct TitleAreaScrollView<Content: View>: View {
    @ViewBuilder let content: Content
    @State private var width: CGFloat = 0

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            content
                .frame(minWidth: width, alignment: .leading)
                .background(WindowTitleArea())
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }
}

/// A tab row only as wide as its tabs, so a button placed after it follows
/// the last tab. Once the tabs outgrow the room they scroll, and that button
/// stays at the edge. The row's priority lets it take all the room it needs
/// before a Spacer beside it gets any.
struct HuggingTabScrollView<Content: View>: View {
    @ViewBuilder let content: Content
    @State private var contentWidth: CGFloat = 0

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            content
                .background(WindowTitleArea())
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { contentWidth = $0.rounded(.up) }
        }
        .frame(maxWidth: contentWidth)
        .layoutPriority(1)
    }
}
