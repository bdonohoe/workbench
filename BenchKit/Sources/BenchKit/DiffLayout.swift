import Foundation

/// A diff flattened into one string for a text view, one line per
/// `DiffLine` with no +/− markers, and the map back from a position in
/// that string to the line it's on. Hunk and meta lines are kept, so the
/// line indexes here match the indexes into the `lines` it was made from.
public struct DiffLayout: Hashable, Sendable {
    /// Every line's text joined with newlines, and no newline at the end.
    public let text: String
    /// Where each line's text sits in `text`, in UTF-16 units, without its newline.
    public let ranges: [NSRange]
    /// Each line's kind, in the same order as `ranges`.
    public let kinds: [DiffLine.Kind]

    public init(lines: [DiffLine]) {
        var text = ""
        var ranges: [NSRange] = []
        ranges.reserveCapacity(lines.count)
        var offset = 0
        for (index, line) in lines.enumerated() {
            if index > 0 {
                text.append("\n")
                offset += 1
            }
            text.append(line.text)
            let length = line.text.utf16.count
            ranges.append(NSRange(location: offset, length: length))
            offset += length
        }
        self.text = text
        self.ranges = ranges
        kinds = lines.map(\.kind)
    }

    /// The index of the line containing the character at `utf16Offset`.
    /// A line's trailing newline counts as part of it, and so does the
    /// position right after the last character, where a caret sits at the
    /// end of the text.
    public func line(at utf16Offset: Int) -> Int? {
        guard utf16Offset >= 0, !ranges.isEmpty else { return nil }
        guard utf16Offset <= NSMaxRange(ranges[ranges.count - 1]) else { return nil }
        // The last line that starts at or before the offset.
        var low = 0, high = ranges.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if ranges[mid].location <= utf16Offset { low = mid } else { high = mid - 1 }
        }
        return low
    }
}
