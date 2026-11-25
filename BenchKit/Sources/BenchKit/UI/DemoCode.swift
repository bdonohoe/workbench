import Foundation

/// A rough Swift colorer for the demo, which has no Mac to do it properly.
enum DemoCode {
    private static let keywords: Set<String> = [
        "import", "struct", "class", "enum", "func", "var", "let", "private", "public", "static", "final",
        "return", "if", "else", "guard", "for", "in", "where", "while", "switch", "case", "default",
        "mutating", "some", "true", "false", "nil", "self", "try", "await", "async", "extension",
    ]

    private static let patterns: [(NSRegularExpression, CodeKind?)] = [
        (#"//.*"#, .comment),
        (#""(?:[^"\\]|\\.)*""#, .string),
        (#"\b\d+(?:\.\d+)?\b"#, .number),
        (#"\b[A-Z][A-Za-z0-9]*\b"#, .type),
        (#"\b[a-z][A-Za-z0-9]*(?=\()"#, .function),
        (#"\b[a-z]+\b"#, nil),
    ].compactMap { pattern, kind in (try? NSRegularExpression(pattern: pattern)).map { ($0, kind) } }

    static func runs(_ text: String) -> [CodeRun] {
        let source = text as NSString
        var taken = IndexSet()
        var runs: [CodeRun] = []
        for (regex, kind) in patterns {
            for match in regex.matches(in: text, range: NSRange(location: 0, length: source.length)) {
                let range = match.range
                guard !taken.intersects(integersIn: range.location..<NSMaxRange(range)) else { continue }
                let found: CodeKind?
                if let kind { found = kind } else { found = keywords.contains(source.substring(with: range)) ? .keyword : nil }
                guard let found else { continue }
                taken.insert(integersIn: range.location..<NSMaxRange(range))
                runs.append(CodeRun(start: range.location, length: range.length, kind: found))
            }
        }
        return runs.sorted { $0.start < $1.start }
    }
}
