import AppKit
import SwiftUI

extension View {
    /// Tab and Shift-Tab move to the next or previous field instead of typing
    /// a tab, the way they do in a text field. For multi-line prompt boxes in
    /// forms, where a tab character is never what you want.
    func tabMovesFocus() -> some View {
        // Shift-Tab can arrive as its own backtab character rather than Tab
        // with Shift held, so both count.
        onKeyPress(keys: [.tab, KeyEquivalent("\u{19}")], phases: .down) { press in
            guard let window = NSApp.keyWindow,
                  let current = window.firstResponder as? NSView else { return .ignored }
            if press.modifiers.contains(.shift) || press.key == KeyEquivalent("\u{19}") {
                window.selectKeyView(preceding: current)
            } else {
                window.selectKeyView(following: current)
            }
            return .handled
        }
    }
}
