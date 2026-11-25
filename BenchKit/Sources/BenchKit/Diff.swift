import Foundation

/// One parsed line of a unified diff.
public struct DiffLine: Identifiable, Hashable, Codable, Sendable {
    public enum Kind: String, Codable, Sendable { case context, added, removed, hunk, meta }
    public let id: Int
    public let kind: Kind
    public let text: String
    public let oldNumber: Int?
    public let newNumber: Int?
    /// Word-level breakdown for a changed line; empty means show it plain.
    public var segments: [Segment] = []
    /// What to color in the line's text, from a Mac with the codeReview
    /// feature. nil means show it plain.
    public var code: [CodeRun]?

    public struct Segment: Hashable, Codable, Sendable {
        public var text: String
        public var changed: Bool
        public init(text: String, changed: Bool) {
            self.text = text
            self.changed = changed
        }
    }

    public init(id: Int, kind: Kind, text: String, oldNumber: Int?, newNumber: Int?, segments: [Segment] = [], code: [CodeRun]? = nil) {
        self.code = code
        self.id = id
        self.kind = kind
        self.text = text
        self.oldNumber = oldNumber
        self.newNumber = newNumber
        self.segments = segments
    }
}

public enum DiffParser {
    public static func parse(_ diff: String) -> [DiffLine] {
        var lines: [DiffLine] = []
        var oldLine = 0
        var newLine = 0
        var inHunk = false
        for (index, raw) in diff.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let text = String(raw)
            if text.hasPrefix("@@") {
                inHunk = true
                // @@ -a,b +c,d @@ optional context
                let parts = text.split(separator: " ")
                if parts.count >= 3 {
                    oldLine = Int(parts[1].dropFirst().split(separator: ",").first ?? "") ?? 0
                    newLine = Int(parts[2].dropFirst().split(separator: ",").first ?? "") ?? 0
                }
                let context = text.components(separatedBy: "@@").dropFirst(2).joined(separator: "@@").trimmingCharacters(in: .whitespaces)
                lines.append(DiffLine(id: index, kind: .hunk, text: context, oldNumber: nil, newNumber: nil))
            } else if !inHunk {
                // File headers (diff --git, index, ---, +++). Only keep notable ones.
                if text.hasPrefix("Binary files") || text.hasPrefix("new file") || text.hasPrefix("deleted file")
                    || text.hasPrefix("rename from") || text.hasPrefix("rename to") {
                    lines.append(DiffLine(id: index, kind: .meta, text: text, oldNumber: nil, newNumber: nil))
                }
            } else if text.hasPrefix("+") {
                lines.append(DiffLine(id: index, kind: .added, text: String(text.dropFirst()), oldNumber: nil, newNumber: newLine))
                newLine += 1
            } else if text.hasPrefix("-") {
                lines.append(DiffLine(id: index, kind: .removed, text: String(text.dropFirst()), oldNumber: oldLine, newNumber: nil))
                oldLine += 1
            } else if text.hasPrefix("\\") {
                lines.append(DiffLine(id: index, kind: .meta, text: text, oldNumber: nil, newNumber: nil))
            } else if text.hasPrefix(" ") {
                lines.append(DiffLine(id: index, kind: .context, text: String(text.dropFirst()), oldNumber: oldLine, newNumber: newLine))
                oldLine += 1
                newLine += 1
            }
        }
        WordDiff.annotate(&lines)
        return lines
    }
}

/// Finds which words changed between a removed line and the added line that
/// replaced it, so the edit stands out inside the red and green rows.
public enum WordDiff {
    /// Pairs each run of removed lines with the run of added lines right after it.
    public static func annotate(_ lines: inout [DiffLine]) {
        var i = 0
        while i < lines.count {
            guard lines[i].kind == .removed else { i += 1; continue }
            let removedStart = i
            while i < lines.count, lines[i].kind == .removed { i += 1 }
            let addedStart = i
            while i < lines.count, lines[i].kind == .added { i += 1 }
            let pairs = min(addedStart - removedStart, i - addedStart)
            for k in 0..<pairs {
                let (old, new) = segments(lines[removedStart + k].text, lines[addedStart + k].text)
                lines[removedStart + k].segments = old
                lines[addedStart + k].segments = new
            }
        }
    }

    /// Splits text into words, runs of spaces, and single punctuation marks.
    public static func tokens(_ text: String) -> [String] {
        var result: [String] = []
        var current = ""
        var currentKind = 0
        for ch in text {
            let kind = ch.isLetter || ch.isNumber || ch == "_" ? 1 : (ch.isWhitespace ? 2 : 3)
            if kind == currentKind && kind != 3 {
                current.append(ch)
            } else {
                if !current.isEmpty { result.append(current) }
                current = String(ch)
                currentKind = kind
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    public static func segments(_ old: String, _ new: String) -> ([DiffLine.Segment], [DiffLine.Segment]) {
        let a = tokens(old)
        let b = tokens(new)
        guard !a.isEmpty, !b.isEmpty, a.count * b.count <= 250_000 else { return ([], []) }

        // Longest common subsequence over tokens.
        var table = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for x in stride(from: a.count - 1, through: 0, by: -1) {
            for y in stride(from: b.count - 1, through: 0, by: -1) {
                table[x][y] = a[x] == b[y] ? table[x + 1][y + 1] + 1 : max(table[x + 1][y], table[x][y + 1])
            }
        }
        var keepA = Array(repeating: false, count: a.count)
        var keepB = Array(repeating: false, count: b.count)
        var x = 0, y = 0
        while x < a.count, y < b.count {
            if a[x] == b[y] {
                keepA[x] = true; keepB[y] = true; x += 1; y += 1
            } else if table[x + 1][y] >= table[x][y + 1] {
                x += 1
            } else {
                y += 1
            }
        }

        // Mostly-rewritten lines read better without highlights.
        let sharedChars = zip(a, keepA).filter { $0.1 && !$0.0.allSatisfy(\.isWhitespace) }.reduce(0) { $0 + $1.0.count }
        let totalChars = max(old.filter { !$0.isWhitespace }.count, new.filter { !$0.isWhitespace }.count, 1)
        guard Double(sharedChars) / Double(totalChars) >= 0.2 else { return ([], []) }

        return (merge(a, keepA), merge(b, keepB))
    }

    /// Joins tokens into runs. A space between two changed words counts as
    /// changed so the highlight reads as one block.
    private static func merge(_ tokens: [String], _ keep: [Bool]) -> [DiffLine.Segment] {
        var changed = keep.map { !$0 }
        for i in tokens.indices where !changed[i] && tokens[i].allSatisfy(\.isWhitespace)
            && i > 0 && i < tokens.count - 1 && changed[i - 1] && changed[i + 1] {
            changed[i] = true
        }
        var result: [DiffLine.Segment] = []
        for (token, isChanged) in zip(tokens, changed) {
            if let last = result.last, last.changed == isChanged {
                result[result.count - 1].text += token
            } else {
                result.append(.init(text: token, changed: isChanged))
            }
        }
        return result
    }
}
