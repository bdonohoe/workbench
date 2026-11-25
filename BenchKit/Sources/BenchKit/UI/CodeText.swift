import SwiftUI

extension CodeKind {
    /// Colors for code, close to the Mac's terminal-theme colors and
    /// readable in light and dark.
    public var color: Color {
        switch self {
        case .keyword: Color(light: Color(red: 0.61, green: 0.14, blue: 0.58), dark: Color(red: 0.99, green: 0.47, blue: 0.75))
        case .string: Color(light: Color(red: 0.11, green: 0.47, blue: 0.20), dark: Color(red: 0.56, green: 0.85, blue: 0.51))
        case .comment: .secondary
        case .number: Color(light: Color(red: 0.60, green: 0.40, blue: 0.0), dark: Color(red: 0.95, green: 0.80, blue: 0.42))
        case .function: Color(light: Color(red: 0.16, green: 0.36, blue: 0.80), dark: Color(red: 0.52, green: 0.71, blue: 1.0))
        case .type: Color(light: Color(red: 0.0, green: 0.46, blue: 0.54), dark: Color(red: 0.46, green: 0.85, blue: 0.90))
        case .tag, .builtin: Color(light: Color(red: 0.74, green: 0.20, blue: 0.20), dark: Color(red: 1.0, green: 0.52, blue: 0.50))
        }
    }
}

/// Text with code colored by `runs`, which count in UTF-16 units from the
/// start of `text`. Built in one pass, so a long file stays quick. Runs
/// that overlap an earlier one or fall outside the text are skipped.
public func codeText(_ text: String, runs: [CodeRun]) -> AttributedString {
    guard !runs.isEmpty else { return AttributedString(text) }
    let units = text.utf16
    let length = units.count
    var result = AttributedString()
    var cursor = units.startIndex
    var position = 0
    for run in runs.sorted(by: { $0.start < $1.start })
    where run.start >= position && run.length > 0 && run.start + run.length <= length {
        let start = units.index(cursor, offsetBy: run.start - position)
        let end = units.index(start, offsetBy: run.length)
        if cursor < start { result += AttributedString(String(text[cursor..<start])) }
        var piece = AttributedString(String(text[start..<end]))
        piece.foregroundColor = run.kind.color
        result += piece
        cursor = end
        position = run.start + run.length
    }
    if cursor < units.endIndex { result += AttributedString(String(text[cursor...])) }
    return result
}
