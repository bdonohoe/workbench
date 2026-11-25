import Foundation

/// What a terminal types when files are dropped on it: each path with the
/// shell's special characters backslash-escaped, separated by spaces, the
/// way Terminal and Ghostty do it. Claude Code reads a dropped image path
/// as an attachment, so this is how a screenshot dragged onto a Claude tab
/// reaches Claude.
public enum TerminalDrop {
    /// The characters a shell would otherwise read as something else.
    /// The same set Ghostty's macOS app escapes.
    static let special: Set<Character> = [
        "\\", " ", "(", ")", "[", "]", "{", "}", "<", ">", "\"", "'", "`",
        "!", "#", "$", "&", ";", "|", "*", "?", "\t",
    ]

    public static func escape(_ path: String) -> String {
        var out = ""
        out.reserveCapacity(path.count)
        for character in path {
            if special.contains(character) { out.append("\\") }
            out.append(character)
        }
        return out
    }

    /// The text for dropped file paths, or nil when there are none.
    public static func text(forPaths paths: [String]) -> String? {
        let escaped = paths.filter { !$0.isEmpty }.map(escape)
        return escaped.isEmpty ? nil : escaped.joined(separator: " ")
    }
}
