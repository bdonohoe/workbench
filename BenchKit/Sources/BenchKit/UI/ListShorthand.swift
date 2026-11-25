import Foundation

/// Markdown list shorthand in the message box. A new line after a list
/// item continues the list: the same bullet again, or the next number,
/// with the item's indent. A new line on an item with nothing in it ends
/// the list instead, taking the marker off. Claude reads the Markdown as
/// is, so nothing else has to know about lists.
public enum ListShorthand {
    /// What to put in place of the plain newline.
    public struct Edit: Equatable {
        /// What to replace, in the text's own indices.
        public var range: Range<String.Index>
        public var replacement: String
    }

    /// The edit for a new line typed with `selection` (empty when nothing
    /// is selected) in `text`. The line is read up to the selection, so
    /// anything after the cursor moves down to the new item.
    public static func newline(in text: String, replacing selection: Range<String.Index>) -> Edit {
        let cursor = selection.lowerBound
        let lineStart = text[..<cursor].lastIndex(of: "\n").map { text.index(after: $0) } ?? text.startIndex
        guard let item = Item(text[lineStart..<cursor]) else {
            return Edit(range: selection, replacement: "\n")
        }
        if item.isEmpty, selection.isEmpty, cursor == text.endIndex || text[cursor] == "\n" {
            // Return on an empty item ends the list: the marker goes,
            // leaving the cursor on a plain line.
            return Edit(range: lineStart..<cursor, replacement: "")
        }
        return Edit(range: selection, replacement: "\n" + item.next)
    }

    /// The text after the edit, and where the cursor lands.
    public static func apply(_ edit: Edit, to text: String) -> (text: String, cursor: String.Index) {
        var result = text
        result.replaceSubrange(edit.range, with: edit.replacement)
        let offset = text.distance(from: text.startIndex, to: edit.range.lowerBound) + edit.replacement.count
        return (result, result.index(result.startIndex, offsetBy: offset))
    }

    /// A list item's marker, as typed: `- `, `* `, `+ `, `• `, a checkbox
    /// like `- [ ] `, or a number like `3. ` or `3) `.
    struct Item {
        var indent: Substring
        /// The marker for the item after this one.
        var next: String
        /// Nothing typed after the marker.
        var isEmpty: Bool

        init?(_ line: Substring) {
            let indentEnd = line.firstIndex { $0 != " " && $0 != "\t" } ?? line.endIndex
            indent = line[..<indentEnd]
            let rest = line[indentEnd...]
            guard let first = rest.first else { return nil }
            let body: Substring
            if "-*+•".contains(first), rest.dropFirst().first == " " {
                var marker = String(rest.prefix(2))
                var after = rest.dropFirst(2)
                // A checkbox continues as an unchecked one.
                if after.hasPrefix("[ ] ") || after.hasPrefix("[x] ") || after.hasPrefix("[X] ") {
                    marker += "[ ] "
                    after = after.dropFirst(4)
                }
                next = indent + marker
                body = after
            } else if first.isNumber {
                let digits = rest.prefix { $0.isNumber }
                guard digits.count <= 9, let number = Int(digits) else { return nil }
                let afterDigits = rest[digits.endIndex...]
                guard let delimiter = afterDigits.first, delimiter == "." || delimiter == ")",
                      afterDigits.dropFirst().first == " " else { return nil }
                next = indent + "\(number + 1)\(delimiter) "
                body = afterDigits.dropFirst(2)
            } else {
                return nil
            }
            isEmpty = body.allSatisfy { $0 == " " || $0 == "\t" }
        }
    }
}
