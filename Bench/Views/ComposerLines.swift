import AppKit

/// Which line of the message box the cursor is on, counting the lines a
/// long paragraph wraps onto, not just the ones a Return starts. Up on the
/// first line and down on the last step through the messages you've sent;
/// anywhere else the arrows move the cursor.
enum ComposerLines {
    /// Whether the cursor, with nothing selected, is on the box's top line.
    static func caretIsOnFirstLine(of editor: NSTextView) -> Bool {
        caret(in: editor, sharesLineWith: 0)
    }

    /// Whether the cursor, with nothing selected, is on the box's bottom line.
    static func caretIsOnLastLine(of editor: NSTextView) -> Bool {
        caret(in: editor, sharesLineWith: (editor.string as NSString).length)
    }

    private static func caret(in editor: NSTextView, sharesLineWith end: Int) -> Bool {
        let selection = editor.selectedRange()
        guard selection.length == 0 else { return false }
        let text = editor.string as NSString
        let caret = min(selection.location, text.length)
        // A line break between them settles it without asking the layout.
        let between = NSRange(location: min(caret, end), length: abs(caret - end))
        if text.range(of: "\n", options: [], range: between).location != NSNotFound { return false }
        guard caret != end else { return true }
        // Same paragraph: they're on one line if they sit at the same height.
        let caretRect = editor.firstRect(forCharacterRange: NSRange(location: caret, length: 0), actualRange: nil)
        let endRect = editor.firstRect(forCharacterRange: NSRange(location: end, length: 0), actualRange: nil)
        guard caretRect != .zero, endRect != .zero else { return true }
        return abs(caretRect.midY - endRect.midY) < max(1, min(caretRect.height, endRect.height) / 2)
    }
}
